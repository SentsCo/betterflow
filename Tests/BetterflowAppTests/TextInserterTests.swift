import CoreGraphics
import Testing

@testable import BetterflowApp

@MainActor @Test
func unicodeInsertionEventsDoNotInheritHeldModifiers() throws {
  let (keyDown, keyUp) = try TextInserter.makeUnicodeEvents(Array("hello".utf16))
  let modifierMask: CGEventFlags = [
    .maskCommand,
    .maskControl,
    .maskAlternate,
    .maskShift,
  ]

  #expect(keyDown.flags.intersection(modifierMask).isEmpty)
  #expect(keyUp.flags.intersection(modifierMask).isEmpty)
}

@MainActor @Test
func queuedReturnEventsBypassBetterflowAndDoNotInheritHeldModifiers() throws {
  let (keyDown, keyUp) = try TextInserter.makeKeyEvents(virtualKey: 36)
  let modifierMask: CGEventFlags = [
    .maskCommand,
    .maskControl,
    .maskAlternate,
    .maskShift,
    .maskSecondaryFn,
  ]

  #expect(keyDown.flags.intersection(modifierMask).isEmpty)
  #expect(keyUp.flags.intersection(modifierMask).isEmpty)
  #expect(
    keyDown.getIntegerValueField(.eventSourceUserData)
      == betterflowSyntheticKeyEventMarker
  )
  #expect(
    keyUp.getIntegerValueField(.eventSourceUserData)
      == betterflowSyntheticKeyEventMarker
  )
}
