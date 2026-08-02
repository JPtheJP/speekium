import SwiftUI

/// The Vocabulary block in General settings.
///
/// Deliberately two separate things: a text field that only ever holds the term
/// being typed, and the saved terms as chips underneath it.
///
/// The previous single `NSTokenField` held both at once, and that is what made
/// the list so easy to lose — the saved vocabulary *was* the field's text, so
/// ⌘A followed by any key, a held backspace, or a drag-select plus Delete wiped
/// every term in one gesture. Each of those went straight to `UserDefaults` and
/// pushed an empty context to the running sidecar, with nothing to undo it.
///
/// Now nothing typed into the entry field can reach the saved list. Removal has
/// exactly one path — clicking a chip's own ✕ — and even that is reversible
/// while the Undo row is showing.
struct VocabularySection: View {
    @ObservedObject var settings: Settings

    /// The term being typed. Never holds saved terms, by construction.
    @State private var draft = ""

    /// Backspace into an empty field arms the last chip rather than deleting it;
    /// a second backspace removes it. Two keystrokes, and the first one is
    /// visible, so the destructive one is never a surprise.
    @State private var armedTerm: String?

    /// When the last backspace landed, to tell a deliberate second press from
    /// key repeat. Without this, *holding* backspace still walks the whole list
    /// — arm, remove, arm, remove — which is the exact gesture this rewrite
    /// exists to stop. Repeats arrive ~30 ms apart, deliberate presses far
    /// slower, so one term per hold is the worst case.
    @State private var lastDeleteAt: Date?

    /// Set when a term already in the list is re-added, to pulse the existing
    /// chip. Silently swallowing the word reads as the app dropping input.
    @State private var duplicateTerm: String?

    @State private var lastRemoval: Removal?
    @FocusState private var entryFocused: Bool

    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// A removal, with the whole list as it stood before it.
    ///
    /// Snapshotting the list rather than just the term means Undo also restores
    /// the term's original position, so recovering doesn't quietly reorder the
    /// vocabulary.
    private struct Removal: Equatable {
        let id = UUID()
        let term: String
        let previous: [String]
    }

    private var terms: [String] { settings.contextTermList }

    var body: some View {
        Section {
            entryRow

            if !terms.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        TermChip(
                            term: term,
                            isArmed: armedTerm == term,
                            isDuplicate: duplicateTerm == term,
                            remove: { remove(term) }
                        )
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
            }

            if let removal = lastRemoval {
                undoRow(removal)
            }
        } header: {
            HStack {
                Text("Vocabulary")
                Spacer()
                if !terms.isEmpty {
                    Text("\(terms.count)")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                        .transition(.opacity)
                }
            }
        } footer: {
            footer
        }
        .animation(spring, value: terms)
        .animation(spring, value: lastRemoval)
        .animation(spring, value: armedTerm)
        // Auto-hide the Undo row, but only after long enough to notice it. The
        // `id:` restarts the clock on each new removal instead of letting an
        // earlier one's timer close the row on a fresh deletion.
        .task(id: lastRemoval?.id) {
            guard lastRemoval != nil else { return }
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            lastRemoval = nil
        }
        .task(id: duplicateTerm) {
            guard duplicateTerm != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            duplicateTerm = nil
        }
    }

    // MARK: - Entry

    private var entryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(draft.isEmpty ? .secondary : Color.accentColor)
                .font(.system(size: 13))

            TextField("Add a name or term", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .focused($entryFocused)
                .onSubmit { commitDraft() }
                .onChange(of: draft) { _, _ in
                    armedTerm = nil
                    consumeSeparators()
                }
                // Backspace on an empty field arms the last chip instead of
                // removing it outright. `.ignored` while there is text to
                // delete leaves normal editing completely untouched.
                .onKeyPress(.delete) {
                    guard draft.isEmpty, let last = terms.last else { return .ignored }
                    let now = Date()
                    defer { lastDeleteAt = now }
                    if let previous = lastDeleteAt, now.timeIntervalSince(previous) < 0.3 {
                        return .handled  // key repeat, not a second decision
                    }
                    if armedTerm == last {
                        remove(last)
                    } else {
                        armedTerm = last
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard armedTerm != nil else { return .ignored }
                    armedTerm = nil
                    return .handled
                }
                .onChange(of: entryFocused) { _, focused in
                    if !focused { armedTerm = nil; commitDraft() }
                }

            if !draft.isEmpty {
                Button("Add") { commitDraft() }
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .animation(spring, value: draft.isEmpty)
        // The whole row is the target: a bare plain text field is a small,
        // invisible strip to aim at.
        .contentShape(Rectangle())
        .onTapGesture { entryFocused = true }
    }

    private func undoRow(_ removal: Removal) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
            Text("Removed \(Text("“\(removal.term)”").fontWeight(.medium))")
            Spacer()
            Button("Undo") {
                settings.contextTermList = removal.previous
                lastRemoval = nil
            }
            .controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Names and jargon you say often. Type a term and press space.")

            // Measured, not guessed: lowercase `claude` was enough to beat
            // `Cloud`, but lowercase `codex` did not beat `CodeX`.
            Text("Write each term the way you want it spelled back — ")
                + Text("Codex").fontWeight(.semibold)
                + Text(" is recognised where ")
                + Text("codex").fontWeight(.semibold)
                + Text(" isn't.")

            Text("Applies immediately. Keep the list tight; every term is re-read on each pass.")
        }
        .foregroundStyle(.secondary)
        .font(.callout)
    }

    // MARK: - Mutation

    /// Commits every complete word in the draft, leaving any unterminated tail
    /// in the field.
    ///
    /// Splitting the whole string rather than just the last separator is what
    /// makes pasting a ready-made list ("Claude Codex 期末考") work in one go.
    private func consumeSeparators() {
        guard draft.contains(where: isSeparator) else { return }
        let endsOpen = !(draft.last.map(isSeparator) ?? false)
        let pieces = draft.split(whereSeparator: isSeparator).map(String.init)
        let complete = endsOpen ? Array(pieces.dropLast()) : pieces
        for piece in complete { add(piece) }
        draft = endsOpen ? (pieces.last ?? "") : ""
    }

    private func commitDraft() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        add(term)
        draft = ""
    }

    private func add(_ raw: String) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        // Case-sensitive on purpose: casing is the lever that makes biasing
        // work at all, so `Codex` and `codex` are genuinely different entries.
        guard !terms.contains(term) else {
            duplicateTerm = term
            return
        }
        // The pending snapshot predates this term, so undoing after an add would
        // silently swallow it. Retire the offer instead of restoring a stale list.
        lastRemoval = nil
        settings.contextTermList = terms + [term]
    }

    private func remove(_ term: String) {
        let previous = terms
        guard previous.contains(term) else { return }
        armedTerm = nil
        settings.contextTermList = previous.filter { $0 != term }
        lastRemoval = Removal(term: term, previous: previous)
    }

    private func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c == "," || c == "、" || c == "，"
    }
}

// MARK: - Chip

private struct TermChip: View {
    let term: String
    let isArmed: Bool
    let isDuplicate: Bool
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isArmed ? Color.red : .primary)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isArmed ? Color.red : .secondary)
                    // Never hidden outright, only dimmed: a chip that is
                    // removable only once you are already on it can't be
                    // discovered, and a ✕ that appears on hover would have to
                    // resize the chip — moving the target out from under the
                    // cursor mid-approach.
                    .opacity(hovering || isArmed ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .help("Remove “\(term)”")
            .accessibilityLabel("Remove \(term)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(fill)
                .overlay {
                    Capsule().strokeBorder(
                        isArmed ? Color.red.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
                }
        }
        .scaleEffect(isDuplicate ? 1.08 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.26, dampingFraction: 0.62), value: isDuplicate)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isArmed)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if isArmed { return .red.opacity(0.13) }
        if isDuplicate { return .accentColor.opacity(0.22) }
        return .primary.opacity(hovering ? 0.10 : 0.06)
    }
}

// MARK: - Layout

/// Left-to-right flow that wraps onto new lines.
///
/// The chips have to wrap: at 20-odd terms a single scrolling row hides most of
/// what the user has configured, which is the same reason the old token field
/// set `wraps = true`.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI probes with 0 and nil widths while sizing. Treating a 0 as a
        // real bound would wrap after every chip and report a tall column.
        let proposed = proposal.width ?? .infinity
        let maxWidth = proposed > 0 ? proposed : .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
