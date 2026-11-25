import AppKit
import SwiftUI

/// Where the keyboard goes when the launcher's window opens.
///
/// The first time a window is shown, AppKit makes its first text field first responder, and a
/// text field focused that way has all of its text selected. With an account name remembered,
/// that left the whole name selected under the keyboard, and two keystrokes typed into another
/// app while the launcher came up (2026-10-15) replaced it with "de". So:
///
/// - With an account name filled in, no field is focused when the window opens. Typing then goes
///   nowhere until a field is clicked or tabbed into.
/// - With none, the (empty) account field is focused, as a convenience for the first sign-in.
/// - Nothing is ever selected on open: a field found focused with all of its text selected right
///   after the window first becomes key is let go of. A click leaves a caret, not a selection,
///   so a field the user clicked keeps the keyboard.
enum OpenFocus {
    /// Should the account field be focused when the window opens?
    static func focusAccount(accountName: String, fieldsDisabled: Bool) -> Bool {
        !fieldsDisabled && accountName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The signature of AppKit's focus-on-open: a non-empty field with every character selected.
    static func isSelectAll(_ selected: NSRange, textLength: Int) -> Bool {
        textLength > 0 && selected.location == 0 && selected.length == textLength
    }

    /// A key that would type text into a field: printable characters, no Command or Control.
    /// Tab, Return, Escape (control characters) and arrows and function keys (AppKit's
    /// U+F700-U+F8FF) are not.
    static func isTyping(_ characters: String, shortcut: Bool) -> Bool {
        !shortcut && !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }
}

/// Holds the keyboard when the window opens instead of the first text field (it is the window's
/// `initialFirstResponder`), and tells the view once the window has first become key. Zero-sized
/// and drawn nowhere; typing while it holds the keyboard is dropped, Tab moves on as usual.
struct OpenFocusAnchor: NSViewRepresentable {
    /// Once, just after the window first becomes key.
    var onOpen: () -> Void

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.onOpen = onOpen
        return v
    }

    func updateNSView(_ v: AnchorView, context: Context) { v.onOpen = onOpen }

    final class AnchorView: NSView {
        var onOpen: () -> Void = {}
        private var keyObserver: NSObjectProtocol?
        private var opened = false

        override var acceptsFirstResponder: Bool { true }
        /// Never a stop in the Tab cycle (an invisible one would look like Tab doing nothing);
        /// Tab from here still reaches the first field.
        override var canBecomeKeyView: Bool { false }
        override var focusRingType: NSFocusRingType { get { .none } set { } }

        override func keyDown(with event: NSEvent) {
            // Typing goes nowhere (no beep either); Tab, Return, Escape, arrows and shortcuts
            // carry on the usual way.
            if !OpenFocus.isTyping(event.characters ?? "",
                                   shortcut: !event.modifierFlags.intersection([.command, .control]).isEmpty) {
                super.keyDown(with: event)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
            guard let w = window, !opened else { return }
            if !w.isVisible { w.initialFirstResponder = self }
            if w.isKeyWindow {
                DispatchQueue.main.async { [weak self] in self?.windowOpened() }
                return
            }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                // After this turn of the run loop, so whatever AppKit or SwiftUI focuses as the
                // window becomes key has been focused already.
                DispatchQueue.main.async { self?.windowOpened() }
            }
        }

        private func windowOpened() {
            guard !opened, let w = window else { return }
            opened = true
            if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
            releaseSelectAll(in: w)
            onOpen()
            // SwiftUI can apply its own default focus a layout pass later; look once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let w = self.window else { return }
                self.releaseSelectAll(in: w)
            }
        }

        /// A field focused with all of its text selected was focused by the window opening, not
        /// by anyone choosing it: take the keyboard back. The text itself is untouched. True when
        /// it did (for --selftest-ui-text).
        @discardableResult
        func releaseSelectAll(in w: NSWindow) -> Bool {
            guard let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                  OpenFocus.isSelectAll(editor.selectedRange(), textLength: (editor.string as NSString).length)
            else { return false }
            return w.makeFirstResponder(self)
        }

        deinit {
            if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        }
    }
}
