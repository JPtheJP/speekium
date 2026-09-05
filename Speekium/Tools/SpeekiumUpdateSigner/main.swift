import CryptoKit
import Darwin
import Foundation
import Security

private enum SignerError: LocalizedError {
    case usage
    case keychain(OSStatus)
    case noKey
    case keyAlreadyExists
    case invalidKey
    case invalidSignature
    case exportDestinationExists
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: SpeekiumUpdateSigner generate|public-key|export <path>|import <path>|sign <archive> <signature>|verify <public-key> <archive> <signature>"
        case let .keychain(status):
            return "Keychain operation failed (\(status))."
        case .noKey:
            return "No Speekium update-signing key exists in this Keychain."
        case .keyAlreadyExists:
            return "A different update-signing key already exists; refusing to replace it."
        case .invalidKey:
            return "The update-signing key is invalid."
        case .invalidSignature:
            return "The update signature is invalid."
        case .exportDestinationExists:
            return "The private-key export destination already exists; refusing to overwrite it."
        case .exportFailed:
            return "The private update key could not be exported securely."
        }
    }
}

private enum KeyStore {
    static let service = "com.jpthejp.speekium.update-signing"
    // This account is intentionally separate from the early development key,
    // which was created by an ad-hoc-signed debug binary. Release tooling is
    // signed with the stable Speekium identity so its Keychain access
    // survives rebuilds.
    static let account = "ed25519-production-v1"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() throws -> Curve25519.Signing.PrivateKey {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw SignerError.noKey }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SignerError.keychain(status)
        }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw SignerError.invalidKey
        }
        return key
    }

    static func save(_ key: Curve25519.Signing.PrivateKey) throws {
        var request = query
        request[kSecValueData as String] = key.rawRepresentation
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw SignerError.keychain(status) }
    }

    static func generate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try? load() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return key
    }

    static func importKey(from url: URL) throws -> Curve25519.Signing.PrivateKey {
        let encoded = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw SignerError.invalidKey
        }
        if let existing = try? load() {
            guard existing.rawRepresentation == key.rawRepresentation else {
                throw SignerError.keyAlreadyExists
            }
            return existing
        }
        try save(key)
        return key
    }
}

private func archiveData(at path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
}

private func signatureData(at path: String) throws -> Data {
    let encoded = try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: encoded), signature.count == 64 else {
        throw SignerError.invalidSignature
    }
    return signature
}

private func printPublicKey(_ key: Curve25519.Signing.PrivateKey) {
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

private func exportPrivateKey(_ data: Data, to destination: URL) throws {
    errno = 0
    let descriptor = destination.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
        throw errno == EEXIST ? SignerError.exportDestinationExists : SignerError.exportFailed
    }

    var complete = false
    defer {
        Darwin.close(descriptor)
        if !complete {
            destination.path.withCString { _ = Darwin.unlink($0) }
        }
    }

    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { throw SignerError.exportFailed }
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                bytes.count - offset
            )
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw SignerError.exportFailed }
            offset += result
        }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw SignerError.exportFailed }
    complete = true
}

@main
private enum SpeekiumUpdateSigner {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { throw SignerError.usage }

        switch arguments[1] {
        case "generate" where arguments.count == 2:
            printPublicKey(try KeyStore.generate())

        case "public-key" where arguments.count == 2:
            printPublicKey(try KeyStore.load())

        case "export" where arguments.count == 3:
            let key = try KeyStore.load()
            let destination = URL(fileURLWithPath: arguments[2])
            let encoded = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
            try exportPrivateKey(encoded, to: destination)
            FileHandle.standardError.write(Data("Exported private update key to \(destination.path)\n".utf8))

        case "import" where arguments.count == 3:
            printPublicKey(try KeyStore.importKey(from: URL(fileURLWithPath: arguments[2])))

        case "sign" where arguments.count == 4:
            let signature = try KeyStore.load().signature(for: archiveData(at: arguments[2]))
            let encoded = Data((signature.base64EncodedString() + "\n").utf8)
            try encoded.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)

        case "verify" where arguments.count == 5:
            guard let publicData = Data(base64Encoded: arguments[2]),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData),
                  publicKey.isValidSignature(
                      try signatureData(at: arguments[4]),
                      for: try archiveData(at: arguments[3])
                  ) else {
                throw SignerError.invalidSignature
            }
            print("valid update signature")

        default:
            throw SignerError.usage
        }
    }
}
