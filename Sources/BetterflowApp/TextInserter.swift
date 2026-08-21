import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

let betterflowSyntheticKeyEventMarker: Int64 = 0x4245_5454_4552_464C
private let textInsertionLogger = Logger(
  subsystem: "com.zachsents.betterflow",
  category: "TextInsertion"
)

struct TextInsertionTarget {
  fileprivate let element: AXUIElement
}

@MainActor
enum TextInserter {
  static func captureTarget(context: String) -> TextInsertionTarget? {
    guard AXIsProcessTrusted() else {
      textInsertionLogger.error(
        "Capture [\(context, privacy: .public)] failed: Accessibility is not granted"
      )
      return nil
    }

    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    let frontmostPID = frontmostApplication?.processIdentifier ?? 0
    let frontmostBundle = frontmostApplication?.bundleIdentifier ?? "unknown"
    textInsertionLogger.info(
      "Capture [\(context, privacy: .public)] began: frontmost pid=\(frontmostPID) bundle=\(frontmostBundle, privacy: .public), Betterflow pid=\(ProcessInfo.processInfo.processIdentifier) active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil)"
    )

    let system = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(
      system,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    )
    var focusedElement: AXUIElement?
    var captureSource = "system"
    if focusedResult == .success, let focusedValue {
      focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
    } else {
      guard let frontmostApplication else {
        textInsertionLogger.error(
          "Capture [\(context, privacy: .public)] failed: system result=\(focusedResult.rawValue), no frontmost app"
        )
        return nil
      }
      let applicationElement = AXUIElementCreateApplication(
        frontmostApplication.processIdentifier
      )
      var applicationFocusedValue: CFTypeRef?
      var applicationResult = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXFocusedUIElementAttribute as CFString,
        &applicationFocusedValue
      )
      if applicationResult != .success || applicationFocusedValue == nil {
        let applicationRole = attributeString(kAXRoleAttribute, of: applicationElement)
        applicationFocusedValue = nil
        applicationResult = AXUIElementCopyAttributeValue(
          applicationElement,
          kAXFocusedUIElementAttribute as CFString,
          &applicationFocusedValue
        )
        textInsertionLogger.info(
          "Capture [\(context, privacy: .public)] accessibility role probe: role=\(applicationRole, privacy: .public), focusedElementResult=\(applicationResult.rawValue)"
        )
      }
      if applicationResult == .success, let applicationFocusedValue {
        captureSource = "application"
        focusedElement = unsafeDowncast(applicationFocusedValue, to: AXUIElement.self)
      } else {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
          applicationElement,
          kAXFocusedWindowAttribute as CFString,
          &focusedWindowValue
        )
        var windowFocusedResult: AXError?
        if focusedWindowResult == .success, let focusedWindowValue {
          let focusedWindow = unsafeDowncast(focusedWindowValue, to: AXUIElement.self)
          var windowFocusedValue: CFTypeRef?
          let result = AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXFocusedUIElementAttribute as CFString,
            &windowFocusedValue
          )
          windowFocusedResult = result
          if result == .success, let windowFocusedValue {
            captureSource = "focused-window"
            focusedElement = unsafeDowncast(windowFocusedValue, to: AXUIElement.self)
          } else {
            textInsertionLogger.error(
              "Capture [\(context, privacy: .public)] focused window has no focused element: result=\(result.rawValue), window=\(summary(of: focusedWindow), privacy: .public), attributes=\(attributeNames(of: focusedWindow), privacy: .public)"
            )
          }
        }
        guard focusedElement != nil else {
          let windowFocusedCode = windowFocusedResult?.rawValue ?? Int32.min
          textInsertionLogger.error(
            "Capture [\(context, privacy: .public)] failed: system=\(focusedResult.rawValue), application=\(applicationResult.rawValue), focusedWindow=\(focusedWindowResult.rawValue), windowFocusedElement=\(windowFocusedCode), applicationAttributes=\(attributeNames(of: applicationElement), privacy: .public)"
          )
          return nil
        }
      }
    }

    guard let focusedElement else {
      textInsertionLogger.fault(
        "Capture [\(context, privacy: .public)] reached an impossible empty target"
      )
      return nil
    }
    let focusedSummary = summary(of: focusedElement)
    textInsertionLogger.info(
      "Capture [\(context, privacy: .public)] found target via \(captureSource, privacy: .public): \(focusedSummary, privacy: .public)"
    )
    guard isEditable(focusedElement) else {
      textInsertionLogger.error(
        "Capture [\(context, privacy: .public)] rejected non-editable target: \(focusedSummary, privacy: .public)"
      )
      return nil
    }
    return TextInsertionTarget(element: focusedElement)
  }

  static func insert(_ text: String, into capturedTarget: TextInsertionTarget?) throws {
    guard !text.isEmpty else { return }
    guard AXIsProcessTrusted() else {
      textInsertionLogger.error("Insertion failed: Accessibility is not granted")
      throw TextInsertionError.accessibilityDenied
    }

    guard let target = capturedTarget else {
      textInsertionLogger.error("Insertion failed: no target was captured at recording start")
      throw TextInsertionError.noTextDestination
    }
    textInsertionLogger.info(
      "Insertion began with captured target: \(summary(of: target.element), privacy: .public)"
    )

    if let currentTarget = captureTarget(context: "delivery") {
      let sameTarget = CFEqual(currentTarget.element, target.element)
      textInsertionLogger.info(
        "Delivery focus comparison: sameTarget=\(sameTarget), current=\(summary(of: currentTarget.element), privacy: .public)"
      )
      if sameTarget {
        textInsertionLogger.info("Inserting through keyboard events into the unchanged target")
        try postUnicode(text)
        textInsertionLogger.info("Posted Unicode keyboard events successfully")
        return
      }
    } else {
      textInsertionLogger.error("Delivery could not resolve the currently focused editable target")
    }

    var selectedTextIsSettable = DarwinBoolean(false)
    let settableResult = AXUIElementIsAttributeSettable(
      target.element,
      kAXSelectedTextAttribute as CFString,
      &selectedTextIsSettable
    )
    textInsertionLogger.info(
      "Captured-target fallback check: settableResult=\(settableResult.rawValue), selectedTextSettable=\(selectedTextIsSettable.boolValue), target=\(summary(of: target.element), privacy: .public)"
    )
    if settableResult == .success, selectedTextIsSettable.boolValue {
      let insertionResult = AXUIElementSetAttributeValue(
        target.element,
        kAXSelectedTextAttribute as CFString,
        text as CFTypeRef
      )
      if insertionResult == .success {
        textInsertionLogger.info("Inserted through the captured target's selected-text attribute")
        return
      }
      textInsertionLogger.error(
        "Captured-target selected-text insertion failed: result=\(insertionResult.rawValue)"
      )
    }

    textInsertionLogger.error("Insertion failed: captured target is no longer writable")
    throw TextInsertionError.noTextDestination
  }

  static func pressReturn(into capturedTarget: TextInsertionTarget?) throws {
    guard AXIsProcessTrusted() else { throw TextInsertionError.accessibilityDenied }
    guard let capturedTarget, let currentTarget = captureTarget(context: "queued-return"),
      CFEqual(currentTarget.element, capturedTarget.element)
    else {
      textInsertionLogger.error("Queued Return failed because the captured target lost focus")
      throw TextInsertionError.noTextDestination
    }

    let (keyDown, keyUp) = try makeKeyEvents(virtualKey: 36)
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    textInsertionLogger.info("Posted queued Return successfully")
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

  private static func summary(of element: AXUIElement) -> String {
    var processID = pid_t()
    let pidResult = AXUIElementGetPid(element, &processID)
    let bundle = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? "unknown"
    var selectedTextIsSettable = DarwinBoolean(false)
    let selectedTextResult = AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &selectedTextIsSettable
    )
    return "pid=\(processID) pidResult=\(pidResult.rawValue) bundle=\(bundle) role=\(attributeString(kAXRoleAttribute, of: element)) subrole=\(attributeString(kAXSubroleAttribute, of: element)) hash=\(CFHash(element)) selectedTextResult=\(selectedTextResult.rawValue) selectedTextSettable=\(selectedTextIsSettable.boolValue)"
  }

  private static func attributeString(_ attribute: String, of element: AXUIElement) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value = value as? String
    else { return "unavailable" }
    return value
  }

  private static func attributeNames(of element: AXUIElement) -> String {
    var names: CFArray?
    let result = AXUIElementCopyAttributeNames(element, &names)
    guard result == .success, let names = names as? [String] else {
      return "unavailable(result=\(result.rawValue))"
    }
    return names.sorted().joined(separator: ",")
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
      textInsertionLogger.error(
        "Delivery fell back to clipboard: \(String(describing: error), privacy: .public)"
      )
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
