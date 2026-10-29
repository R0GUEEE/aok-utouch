import UIKit

/// HID usage -> Linux evdev keycode. UIKit gives us `UIKeyboardHIDUsage`
/// (USB HID keyboard page), QEMU wants evdev codes.
enum KeyMap {
    static let letters: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardA: 30, .keyboardB: 48, .keyboardC: 46, .keyboardD: 32,
        .keyboardE: 18, .keyboardF: 33, .keyboardG: 34, .keyboardH: 35,
        .keyboardI: 23, .keyboardJ: 36, .keyboardK: 37, .keyboardL: 38,
        .keyboardM: 50, .keyboardN: 49, .keyboardO: 24, .keyboardP: 25,
        .keyboardQ: 16, .keyboardR: 19, .keyboardS: 31, .keyboardT: 20,
        .keyboardU: 22, .keyboardV: 47, .keyboardW: 17, .keyboardX: 45,
        .keyboardY: 21, .keyboardZ: 44,
    ]

    static let digits: [UIKeyboardHIDUsage: UInt32] = [
        .keyboard1: 2, .keyboard2: 3, .keyboard3: 4, .keyboard4: 5,
        .keyboard5: 6, .keyboard6: 7, .keyboard7: 8, .keyboard8: 9,
        .keyboard9: 10, .keyboard0: 11,
    ]

    static let punctuation: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardHyphen: 12, .keyboardEqualSign: 13, .keyboardOpenBracket: 26,
        .keyboardCloseBracket: 27, .keyboardBackslash: 43, .keyboardSemicolon: 39,
        .keyboardQuote: 40, .keyboardGraveAccentAndTilde: 41, .keyboardComma: 51,
        .keyboardPeriod: 52, .keyboardSlash: 53,
    ]

    static let special: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardReturnOrEnter: 28, .keyboardEscape: 1, .keyboardDeleteOrBackspace: 14,
        .keyboardTab: 15, .keyboardSpacebar: 57, .keyboardCapsLock: 58,
        .keyboardLeftShift: 42, .keyboardRightShift: 54,
        .keyboardLeftControl: 29, .keyboardRightControl: 97,
        .keyboardLeftAlt: 56, .keyboardRightAlt: 100,
        .keyboardLeftGUI: 125, .keyboardRightGUI: 126,
        .keyboardLeftArrow: 105, .keyboardRightArrow: 106,
        .keyboardUpArrow: 103, .keyboardDownArrow: 108,
        .keyboardHome: 102, .keyboardEnd: 107,
        .keyboardPageUp: 104, .keyboardPageDown: 109,
        .keyboardInsert: 110, .keyboardDeleteForward: 111,
        .keyboardF1: 59, .keyboardF2: 60, .keyboardF3: 61, .keyboardF4: 62,
        .keyboardF5: 63, .keyboardF6: 64, .keyboardF7: 65, .keyboardF8: 66,
        .keyboardF9: 67, .keyboardF10: 68, .keyboardF11: 87, .keyboardF12: 88,
        .keyboardPrintScreen: 99, .keyboardScrollLock: 70, .keyboardPause: 119,
    ]

    static func code(for usage: UIKeyboardHIDUsage) -> UInt32? {
        letters[usage] ?? digits[usage] ?? punctuation[usage] ?? special[usage]
    }

    /// Printable characters arriving through UIKeyInput (software keyboard,
    /// dictation, paste). Shifted characters are folded onto the unshifted
    /// code plus a synthetic shift; the guest's keymap does the rest.
    static func code(forCharacter ch: Character) -> (UInt32, Bool)? {
        switch ch {
        case "a"..."z":
            return (letters[usageForLetter(ch.asciiValue!)] ?? 0, false)
        case "A"..."Z":
            let lower = Character(ch.lowercased())
            return (letters[usageForLetter(lower.asciiValue!)] ?? 0, true)
        case "0"..."9":
            let map: [Character: UInt32] = ["1": 2, "2": 3, "3": 4, "4": 5, "5": 6,
                                            "6": 7, "7": 8, "8": 9, "9": 10, "0": 11]
            return (map[ch] ?? 0, false)
        case " ": return (57, false)
        case "\n": return (28, false)
        case "\t": return (15, false)
        case "-": return (12, false)
        case "=": return (13, false)
        case "[": return (26, false)
        case "]": return (27, false)
        case "\\": return (43, false)
        case ";": return (39, false)
        case "'": return (40, false)
        case "`": return (41, false)
        case ",": return (51, false)
        case ".": return (52, false)
        case "/": return (53, false)
        default: return nil
        }
    }

    private static func usageForLetter(_ ascii: UInt8) -> UIKeyboardHIDUsage {
        // HID usage for A is 0x04 and runs to Z at 0x1D.
        let offset = Int(ascii - UInt8(ascii: "a"))
        return UIKeyboardHIDUsage(rawValue: 0x04 + offset) ?? .keyboardA
    }
}

/// The rectangle the guest image occupies inside `bounds` for a given aspect.
struct Letterbox {
    var rect: CGRect

    init(bounds: CGRect, guestWidth: Int, guestHeight: Int) {
        guard guestWidth > 0, guestHeight > 0, bounds.width > 0, bounds.height > 0 else {
            rect = bounds
            return
        }
        let guestAspect = CGFloat(guestWidth) / CGFloat(guestHeight)
        let hostAspect = bounds.width / bounds.height
        if hostAspect > guestAspect {
            let w = bounds.height * guestAspect
            let h = bounds.height
            rect = CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: h)
        } else {
            let w = bounds.width
            let h = bounds.width / guestAspect
            rect = CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: w, height: h)
        }
    }
}

/// Touch + keyboard input over the scanout.
///
/// One finger is the pointer (virtio-tablet, absolute). A second finger is
/// ignored until M5 gives us a multi-touch device; the gesture is not silently
/// swallowed either — it just does nothing.
final class InputView: UIView, UIKeyInput {
    /// QEMU's absolute axis range (INPUT_EVENT_ABS_MAX).
    static let absMax: UInt32 = 0x7FFF

    var guestWidth = 1280
    var guestHeight = 720

    /// Sticky modifiers, set by the on-screen toolbar.
    private(set) var stickyControl = false
    private(set) var stickyAlt = false

    private var lastPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Pointer

    private func guestCoordinate(_ point: CGPoint) -> (Int32, Int32) {
        let box = Letterbox(bounds: bounds, guestWidth: guestWidth, guestHeight: guestHeight).rect
        guard box.width > 0, box.height > 0 else { return (0, 0) }
        let nx = ((point.x - box.minX) / box.width).clamped(to: 0...1)
        let ny = ((point.y - box.minY) / box.height).clamped(to: 0...1)
        let maxAxis = CGFloat(InputView.absMax)
        return (Int32(nx * maxAxis), Int32(ny * maxAxis))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        guard let touch = touches.first else { return }
        let (x, y) = guestCoordinate(touch.location(in: self))
        lastPoint = touch.location(in: self)
        aok_ios_pointer_abs(Int32(x), Int32(y))
        aok_ios_pointer_button(1 /* LEFT */, 1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        if let last = lastPoint,
           abs(location.x - last.x) < 1.0, abs(location.y - last.y) < 1.0 { return }
        lastPoint = location
        let (x, y) = guestCoordinate(location)
        aok_ios_pointer_abs(Int32(x), Int32(y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        aok_ios_pointer_button(1, 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        aok_ios_pointer_button(1, 0)
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = KeyMap.code(for: key.keyCode) else { continue }
            sendStickyModifiers(down: true)
            aok_ios_key_linux(code, 1)
            aok_ios_key_linux(code, 0)
            sendStickyModifiers(down: false)
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
    }

    private func sendStickyModifiers(down: Bool) {
        if stickyControl { aok_ios_key_linux(29, down ? 1 : 0) }
        if stickyAlt { aok_ios_key_linux(56, down ? 1 : 0) }
    }

    func toggleControl() { stickyControl.toggle() }
    func toggleAlt() { stickyAlt.toggle() }
    func releaseSticky() { stickyControl = false; stickyAlt = false }

    // MARK: UIKeyInput (software keyboard)

    var hasText: Bool { false }

    func insertText(_ text: String) {
        for ch in text {
            guard let (code, shift) = KeyMap.code(forCharacter: ch), code != 0 else { continue }
            if shift { aok_ios_key_linux(42, 1) }
            aok_ios_key_linux(code, 1)
            aok_ios_key_linux(code, 0)
            if shift { aok_ios_key_linux(42, 0) }
        }
    }

    func deleteBackward() {
        aok_ios_key_linux(14, 1)
        aok_ios_key_linux(14, 0)
    }

}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
