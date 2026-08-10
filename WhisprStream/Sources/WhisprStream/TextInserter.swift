import AppKit

/// Delivers text to whichever app has focus and/or the clipboard.
///
/// Pasteboard + Cmd-V rather than synthesised per-character key events: unicode
/// keystroke injection is unreliable for CJK, and this path handles mixed
/// scripts correctly. When clipboard retention is disabled, the previous
/// pasteboard contents are restored after the paste.
enum TextInserter {
    private struct PasteboardSnapshot {
        let items: [[(NSPasteboard.PasteboardType, Data)]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            guard !restored.isEmpty else { return }
            pasteboard.writeObjects(restored)
        }
    }

    /// Performs the requested output actions. `text` is the clean transcript
    /// retained on the clipboard; `insertionText` may include cursor-separating
    /// whitespace used only for the synthetic paste.
    static func deliver(
        _ text: String,
        insertionText: String? = nil,
        insertAtCursor: Bool,
        copyToClipboard: Bool
    ) {
        guard !text.isEmpty else { return }

        if insertAtCursor {
            insert(
                insertionText ?? text,
                clipboardAfterPaste: copyToClipboard ? text : nil
            )
        } else if copyToClipboard {
            copyOnly(text)
        } else {
            Log.write("transcript delivered nowhere (both output options off)")
        }
    }

    private static func insert(_ text: String, clipboardAfterPaste: String?) {
        guard !text.isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
        Log.write("insert: \(text.count) chars -> front=\(front?.bundleIdentifier ?? "nil") "
                  + "(\(front?.localizedName ?? "?")) trusted=\(AXIsProcessTrusted())")

        let pb = NSPasteboard.general
        let saved = clipboardAfterPaste == nil ? PasteboardSnapshot(pb) : nil

        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        Log.write("  pasteboard write=\(ok) chars=\(text.count)")
        let insertedChangeCount = pb.changeCount

        // The pasteboard write is asynchronous from the front app's point of
        // view; posting Cmd-V in the same runloop tick often pastes stale
        // contents or nothing at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pressCommandV()

            if saved != nil || clipboardAfterPaste != text {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Do not overwrite a clipboard update made by the user or
                    // the destination app while the paste was in flight.
                    guard pb.changeCount == insertedChangeCount else {
                        Log.write("  skipped clipboard restore: clipboard changed")
                        return
                    }
                    if let saved {
                        saved.restore(to: pb)
                        Log.write("  restored previous clipboard contents")
                    } else if let clipboardAfterPaste {
                        pb.clearContents()
                        pb.setString(clipboardAfterPaste, forType: .string)
                        Log.write("  retained clean transcript on clipboard")
                    }
                }
            }
        }
    }

    /// Put the transcript on the clipboard without pasting it.
    static func copyOnly(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("copied \(text.count) chars (insert at cursor off)")
    }

    /// Resolves continuation context without requiring every destination app
    /// to expose a complete Accessibility text API. Accessibility remains the
    /// fast path. If it yields nothing, a short reversible keyboard probe
    /// copies the current line prefix, restores both caret and clipboard, then
    /// returns the prefix asynchronously.
    static func resolveTextBeforeCursor(
        fallback: String?,
        completion: @escaping (String?) -> Void
    ) {
        if let text = textBeforeCursor() {
            completion(text)
            return
        }

        guard frontmostBundleID != Bundle.main.bundleIdentifier else {
            completion(fallback)
            return
        }
        copyLinePrefixBeforeCursor { text in
            completion(text ?? fallback)
        }
    }

    private static func copyLinePrefixBeforeCursor(
        completion: @escaping (String?) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)

        // First make sure the user does not already have a selection. Changing
        // an existing selection would alter the intended paste destination.
        pasteboard.clearContents()
        let selectionProbeCount = pasteboard.changeCount
        pressCommandKey(8) // C

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
            guard pasteboard.changeCount == selectionProbeCount else {
                saved.restore(to: pasteboard)
                Log.write("cursor context keyboard probe skipped: existing selection")
                completion(nil)
                return
            }

            pressCommandShiftLeft()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                pasteboard.clearContents()
                let prefixProbeCount = pasteboard.changeCount
                pressCommandKey(8) // C

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) {
                    let copied = pasteboard.changeCount != prefixProbeCount
                        ? pasteboard.string(forType: .string)
                        : nil
                    if copied != nil {
                        // The selection runs from the line start to the original
                        // caret, so Right collapses it back to that caret.
                        pressKey(124) // Right Arrow
                    }
                    saved.restore(to: pasteboard)
                    if let copied {
                        Log.write("cursor context source=keyboard-copy chars=\(copied.count)")
                    } else {
                        Log.write("cursor context keyboard probe unavailable")
                    }
                    completion(copied)
                }
            }
        }
    }

    /// Returns only the short text slice immediately before the active cursor.
    /// Some apps do not expose editable text through Accessibility; callers
    /// treat nil as unknown and preserve the model's capitalization.
    static func textBeforeCursor(maxCharacters: Int = 256) -> String? {
        guard AXIsProcessTrusted(), maxCharacters > 0 else { return nil }

        guard let focusedElement = focusedTextElement() else {
            Log.write(
                "cursor context unavailable reason=no-focused-element front="
                    + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
            )
            return nil
        }
        var element: AXUIElement? = focusedElement

        // Native text controls generally expose an integer selected range.
        // WebKit and Electron editors often expose only opaque text markers,
        // sometimes on an ancestor of the focused element. Try both forms.
        for _ in 0..<4 {
            guard let current = element else { break }
            if let text = textBeforeCursorUsingSelectedRange(
                in: current,
                maxCharacters: maxCharacters
            ) {
                logCursorContext(source: "selected-range", text: text, element: current)
                return text
            }
            if let text = textBeforeCursorUsingTextMarkers(
                in: current,
                maxCharacters: maxCharacters
            ) {
                logCursorContext(source: "text-marker", text: text, element: current)
                return text
            }
            element = parent(of: current)
        }

        // Some Chromium/Electron editors expose the focused text area's value
        // but no caret range at all. When nothing is selected, pasted text in
        // these controls normally lands at the end, so the value suffix is the
        // best available continuation context. Restrict this fallback to a
        // focused editable text role; never use a web area's or window's value.
        if let text = textBeforeCursorUsingFocusedValue(
            in: focusedElement,
            maxCharacters: maxCharacters
        ) {
            logCursorContext(source: "focused-value-end", text: text, element: focusedElement)
            return text
        }

        Log.write("cursor context unavailable role=\(role(of: focusedElement) ?? "unknown")")
        return nil
    }

    /// The system-wide focused-element query is not reliable for every app.
    /// Chromium/Electron and some sandboxed apps can reject it while still
    /// exposing the same element from their application Accessibility root.
    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = focusedElement(from: systemWide) {
            return focused
        }

        // The Accessibility-focused application may be an Electron/WebKit UI
        // helper rather than the bundle's main process. Querying it avoids the
        // PID mismatch that makes Codex and Chrome report no focused element.
        if let focusedApplication = uiElementAttribute(
            of: systemWide,
            named: kAXFocusedApplicationAttribute
        ),
        let focused = focusedElementWithinApplication(focusedApplication) {
            return focused
        }

        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return focusedElementWithinApplication(applicationElement)
    }

    private static func focusedElementWithinApplication(
        _ application: AXUIElement
    ) -> AXUIElement? {
        if let focused = focusedElementInExposedTree(application) {
            return focused
        }
        guard enableManualAccessibilityIfSupported(application) else { return nil }
        return focusedElementInExposedTree(application)
    }

    private static func focusedElementInExposedTree(
        _ application: AXUIElement
    ) -> AXUIElement? {
        if let focused = focusedElement(from: application) {
            return focused
        }
        guard let window = uiElementAttribute(
            of: application,
            named: kAXFocusedWindowAttribute
        ) else { return nil }
        if let focused = focusedElement(from: window) {
            return focused
        }
        return focusedEditableDescendant(of: window)
    }

    private static func enableManualAccessibilityIfSupported(
        _ application: AXUIElement
    ) -> Bool {
        let attribute = "AXManualAccessibility" as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            application,
            attribute,
            &settable
        ) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(
            application,
            attribute,
            kCFBooleanTrue
        ) == .success else { return false }

        Log.write("cursor context enabled manual accessibility for front app")
        return true
    }

    /// Last-resort lookup for apps that omit `AXFocusedUIElement` but expose a
    /// normal focused window tree. The bounds prevent a complex browser page
    /// from turning a trigger press into an unbounded accessibility traversal.
    private static func focusedEditableDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        let maximumDepth = 8
        let maximumElements = 512

        while index < queue.count, index < maximumElements {
            let candidate = queue[index]
            index += 1

            let isFocused = (attributeValue(
                of: candidate.element,
                named: kAXFocusedAttribute
            ) as? NSNumber)?.boolValue == true
            if isFocused, isEditableTextElement(candidate.element) {
                return candidate.element
            }

            guard candidate.depth < maximumDepth else { continue }
            for child in childElements(of: candidate.element) {
                queue.append((child, candidate.depth + 1))
                if queue.count >= maximumElements { break }
            }
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXChildrenAttribute, "AXChildrenInNavigationOrder"] {
            if let children = attributeValue(
                of: element,
                named: attribute
            ) as? [AXUIElement],
            !children.isEmpty {
                return children
            }
        }
        return []
    }

    private static func uiElementAttribute(
        of element: AXUIElement,
        named attribute: String
    ) -> AXUIElement? {
        guard let value = attributeValue(of: element, named: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedElement(from root: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(of: root, named: kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func textBeforeCursorUsingSelectedRange(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
        let selectedRangeValue,
        CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
        else { return nil }

        let selectedAXValue = selectedRangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(selectedAXValue, .cfRange, &selectedRange),
              selectedRange.location >= 0 else { return nil }

        let length = min(maxCharacters, selectedRange.location)
        guard length > 0 else { return "" }
        var requestedRange = CFRange(
            location: selectedRange.location - length,
            length: length
        )

        if let rangeValue = AXValueCreate(.cfRange, &requestedRange) {
            var substringValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &substringValue
            ) == .success,
            let substring = substringValue as? String {
                return substring
            }
        }

        // Native controls commonly expose a complete value but not the
        // parameterized range API. Read only the final slice from that value.
        var completeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &completeValue
        ) == .success,
        let completeText = completeValue as? String else { return nil }

        let utf16Text = completeText as NSString
        let cursor = min(selectedRange.location, utf16Text.length)
        let start = max(0, cursor - maxCharacters)
        return utf16Text.substring(with: NSRange(location: start, length: cursor - start))
    }

    /// WebKit-backed editors represent selections with opaque text markers
    /// instead of `AXSelectedTextRange`. Resolve the insertion marker to an
    /// index, build a short marker range before it, and request that string.
    private static func textBeforeCursorUsingTextMarkers(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {
        guard let selectedRange = attributeValue(
            of: element,
            named: "AXSelectedTextMarkerRange"
        ),
        let cursorMarker = parameterizedValue(
            of: element,
            named: "AXStartTextMarkerForTextMarkerRange",
            parameter: selectedRange
        ),
        let cursorIndexValue = parameterizedValue(
            of: element,
            named: "AXIndexForTextMarker",
            parameter: cursorMarker
        ) as? NSNumber
        else { return nil }

        let cursorIndex = cursorIndexValue.intValue
        guard cursorIndex >= 0 else { return nil }
        let startIndex = max(0, cursorIndex - maxCharacters)

        var cfStartIndex = startIndex
        guard let startIndexValue = CFNumberCreate(nil, .cfIndexType, &cfStartIndex),
              let startMarker = parameterizedValue(
                of: element,
                named: "AXTextMarkerForIndex",
                parameter: startIndexValue
              )
        else { return nil }

        let markers = [startMarker, cursorMarker] as CFArray
        guard let markerRange = parameterizedValue(
            of: element,
            named: "AXTextMarkerRangeForUnorderedTextMarkers",
            parameter: markers
        ),
        let text = parameterizedValue(
            of: element,
            named: "AXStringForTextMarkerRange",
            parameter: markerRange
        ) as? String
        else { return nil }

        return text
    }

    private static func textBeforeCursorUsingFocusedValue(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {
        guard isEditableTextElement(element) else { return nil }

        // If text is selected, paste will replace it rather than append at the
        // end. Without a range we cannot safely infer the preceding character.
        if let selectedText = attributeValue(
            of: element,
            named: kAXSelectedTextAttribute
        ) as? String,
        !selectedText.isEmpty {
            return nil
        }

        guard let completeText = attributeValue(
            of: element,
            named: kAXValueAttribute
        ) as? String else { return nil }

        let utf16Text = completeText as NSString
        let start = max(0, utf16Text.length - maxCharacters)
        return utf16Text.substring(
            with: NSRange(location: start, length: utf16Text.length - start)
        )
    }

    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let elementRole = role(of: element)
        let knownTextRole = elementRole == kAXTextFieldRole
            || elementRole == kAXTextAreaRole
            || elementRole == "AXComboBox"
        let explicitlyEditable = (attributeValue(
            of: element,
            named: "AXEditable"
        ) as? NSNumber)?.boolValue == true
        return knownTextRole || explicitlyEditable
    }

    private static func role(of element: AXUIElement) -> String? {
        attributeValue(of: element, named: kAXRoleAttribute) as? String
    }

    private static func logCursorContext(
        source: String,
        text: String,
        element: AXUIElement
    ) {
        Log.write(
            "cursor context source=\(source) chars=\(text.count) "
                + "role=\(role(of: element) ?? "unknown")"
        )
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(of: element, named: kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attributeValue(
        of element: AXUIElement,
        named attribute: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func parameterizedValue(
        of element: AXUIElement,
        named attribute: String,
        parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value
    }

    private static func pressCommandV() {
        // .hidSystemState + .cghidEventTap is the combination that actually
        // reaches other applications; session taps get dropped for synthetic
        // modifier-key combinations.
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9        // kVK_ANSI_V
        let cmdKey: CGKeyCode = 55     // kVK_Command

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            Log.write("  CGEvent creation FAILED (no event source)")
            return
        }

        // Stray modifiers still latched from the push-to-talk key would turn
        // Cmd-V into Cmd-Opt-V, which is not paste.
        let live = CGEventSource.flagsState(.combinedSessionState)
        if live.contains(.maskAlternate) || live.contains(.maskControl) || live.contains(.maskShift) {
            Log.write("  WARNING stray modifiers latched: \(live.rawValue)")
        }

        // Send a real modifier press/release around the V rather than only
        // stamping .maskCommand, so apps that track modifier state agree.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        Log.write("  posted Cmd-V to cghidEventTap")
    }

    private static func pressCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKey: CGKeyCode = 55
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: true
        ),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: false
        ) else { return }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, keyDown, keyUp, commandUp] {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func pressCommandShiftLeft() {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKey: CGKeyCode = 55
        let shiftKey: CGKeyCode = 56
        let leftArrow: CGKeyCode = 123
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: true
        ),
        let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: true),
        let leftDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true),
        let leftUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false),
        let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: false
        ) else { return }

        commandDown.flags = .maskCommand
        shiftDown.flags = [.maskCommand, .maskShift]
        leftDown.flags = [.maskCommand, .maskShift]
        leftUp.flags = [.maskCommand, .maskShift]
        shiftUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, shiftDown, leftDown, leftUp, shiftUp, commandUp] {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func pressKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else { return }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// The app running the HUD, so we can avoid pasting into ourselves.
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
