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
