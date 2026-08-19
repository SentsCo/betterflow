import Testing

@testable import BetterflowApp

@Test
func liveInferenceGateUsesMinimumThenAdaptsToInferenceTime() {
  var gate = LiveInferenceGate(sampleRate: 16_000)

  #expect(!gate.shouldRun(at: 3_999))
  #expect(gate.shouldRun(at: 4_000))

  gate.didFinishInference(processedSampleCount: 4_000, durationSeconds: 0.1)
  #expect(!gate.shouldRun(at: 7_999))
  #expect(gate.shouldRun(at: 8_000))

  gate.didFinishInference(processedSampleCount: 8_000, durationSeconds: 0.5)
  #expect(gate.requiredNewSampleCount == 8_800)
  #expect(!gate.shouldRun(at: 16_799))
  #expect(gate.shouldRun(at: 16_800))
}
