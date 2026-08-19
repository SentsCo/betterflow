import CoreGraphics
import Testing

@testable import BetterflowApp

@Test
func pushToTalkGestureLatchesOnTapAndFinishesOnHold() {
  var gesture = PushToTalkGesture()

  gesture.press(dictationStarted: true)
  #expect(gesture.release() == .latch)

  gesture.press(dictationStarted: true)
  gesture.holdThresholdReached()
  #expect(gesture.release() == .finish)
}

@Test
func pushToTalkGestureIgnoresPressWhenDictationDidNotStart() {
  var gesture = PushToTalkGesture()

  gesture.press(dictationStarted: false)
  gesture.holdThresholdReached()

  #expect(gesture.release() == .none)
}

@Test
func dictationKeyCommandsRespectModifiersAndSessionState() {
  #expect(
    dictationKeyCommand(keyCode: 36, flags: [], mode: .recording) == .finish
  )
  #expect(
    dictationKeyCommand(keyCode: 36, flags: .maskCommand, mode: .recording)
      == .insertCurrent
  )
  #expect(
    dictationKeyCommand(keyCode: 76, flags: .maskCommand, mode: .finalizing)
      == .insertCurrent
  )
  #expect(
    dictationKeyCommand(keyCode: 53, flags: [], mode: .finalizing) == .cancel
  )
  #expect(
    dictationKeyCommand(keyCode: 6, flags: [], mode: .recording) == .toggleCleanup
  )
  #expect(
    dictationKeyCommand(keyCode: 6, flags: .maskShift, mode: .finalizing)
      == .toggleCleanup
  )
  #expect(
    dictationKeyCommand(
      keyCode: 6,
      flags: .maskAlternate,
      mode: .recording,
      ignoring: .maskAlternate
    ) == .toggleCleanup
  )
  #expect(
    dictationKeyCommand(
      keyCode: 36,
      flags: .maskControl,
      mode: .recording,
      ignoring: .maskControl
    ) == .finish
  )
  #expect(
    dictationKeyCommand(
      keyCode: 6,
      flags: [.maskAlternate, .maskCommand],
      mode: .recording,
      ignoring: .maskAlternate
    ) == nil
  )
  #expect(dictationKeyCommand(keyCode: 6, flags: .maskCommand, mode: .recording) == nil)
  #expect(dictationKeyCommand(keyCode: 6, flags: [], mode: .none) == nil)
  #expect(dictationKeyCommand(keyCode: 36, flags: [], mode: .finalizing) == nil)
  #expect(dictationKeyCommand(keyCode: 36, flags: .maskCommand, mode: .none) == nil)
}
