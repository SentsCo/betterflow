import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let betterflowSyntheticKeyEventMarker: Int64 = 0x4245_5454_4552_464C

struct TextInsertionTarget {
  fileprivate let element: AXUIElement
}

@MainActor
enum TextInserter {
  static func captureTarget() -> TextInsertionTarget? {
    guard AXIsProcessTrusted() else { return nil }
    let system = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        system,
        kAXFocusedUIElementAttribute as CFString,
        &focusedValue
      ) == .success,
      let focusedValue
    else { return nil }
    let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
    guard isEditable(element) else { return nil }
    return TextInsertionTarget(element: element)
  }

  static func insert(_ text: String, into capturedTarget: TextInsertionTarget?) throws {
    guard !text.isEmpty else { return }
    guard AXIsProcessTrusted() else { throw TextInsertionError.accessibilityDenied }

    guard let target = capturedTarget else { throw TextInsertionError.noTextDestination }

    if let currentTarget = captureTarget(), CFEqual(currentTarget.element, target.element) {
      try postUnicode(text)
      return
    }

    var selectedTextIsSettable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(
      target.element,
      kAXSelectedTextAttribute as CFString,
      &selectedTextIsSettable
    ) == .success,
      selectedTextIsSettable.boolValue,
      AXUIElementSetAttributeValue(
        target.element,
        kAXSelectedTextAttribute as CFString,
        text as CFTypeRef
      ) == .success
    {
      return
    }

    throw TextInsertionError.noTextDestination
  }

  static func pressReturn(into capturedTarget: TextInsertionTarget?) throws {
    guard AXIsProcessTrusted() else { throw TextInsertionError.accessibilityDenied }
    guard let capturedTarget, let currentTarget = captureTarget(),
      CFEqual(currentTarget.element, capturedTarget.element)
    else { throw TextInsertionError.noTextDestination }

    let (keyDown, keyUp) = try makeKeyEvents(virtualKey: 36)
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }

  private static func postUnicode(_ text: String) throws {
    let characters = Array(text.utf16)
    for chunkStart in stride(from: 0, to: characters.count, by: 32) {
      let end = min(chunkStart + 32, characters.count)
      let chunk = Array(characters[chunkStart..<end])
      let (keyDown, keyUp) = try makeUnicodeEvents(chunk)
      keyDown.post(tap: .cghidEventTap)
      keyUp.post(tap: .cghidEventTap)
    }
  }

  static func makeUnicodeEvents(_ characters: [UInt16]) throws -> (CGEvent, CGEvent) {
    guard let source = CGEventSource(stateID: .privateState),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else {
      throw TextInsertionError.cannotCreateKeyboardEvent
    }
    keyDown.flags = []
    keyUp.flags = []
    characters.withUnsafeBufferPointer { buffer in
      keyDown.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress!
      )
      keyUp.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress!
      )
    }
    return (keyDown, keyUp)
  }

  static func makeKeyEvents(virtualKey: CGKeyCode) throws -> (CGEvent, CGEvent) {
    guard let source = CGEventSource(stateID: .privateState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: virtualKey,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: virtualKey,
        keyDown: false
      )
    else { throw TextInsertionError.cannotCreateKeyboardEvent }
    keyDown.flags = []
    keyUp.flags = []
    keyDown.setIntegerValueField(
      .eventSourceUserData,
      value: betterflowSyntheticKeyEventMarker
    )
    keyUp.setIntegerValueField(
      .eventSourceUserData,
      value: betterflowSyntheticKeyEventMarker
    )
    return (keyDown, keyUp)
  }

  private static func isEditable(_ element: AXUIElement) -> Bool {
    var selectedTextIsSettable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &selectedTextIsSettable
    ) == .success,
      selectedTextIsSettable.boolValue
    {
      return true
    }

    var roleValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
      let role = roleValue as? String
    else { return false }
    return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
  }
}

enum TextDeliveryResult: Equatable {
  case inserted
  case copied
}

@MainActor
enum TextDelivery {
  static func deliver(_ text: String, into target: TextInsertionTarget?) -> TextDeliveryResult {
    do {
      try TextInserter.insert(text, into: target)
      return .inserted
    } catch {
      copy(text)
      return .copied
    }
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

enum TextInsertionError: LocalizedError {
  case accessibilityDenied
  case cannotCreateKeyboardEvent
  case noTextDestination

  var errorDescription: String? {
    switch self {
    case .accessibilityDenied:
      "Accessibility permission is required to insert dictated text."
    case .cannotCreateKeyboardEvent:
      "macOS could not create a text insertion event."
    case .noTextDestination:
      "The app you were dictating into no longer has an editable text field."
    }
  }
}
