import Testing

@testable import BetterflowApp

@Test
func liveInferenceGateUsesMinimumThenAdaptsToInferenceTime() {
  var gate = LiveInferenceGate(sampleRate: 16_000)

  #expect(!gate.shouldRun(at: 4_799))
  #expect(gate.shouldRun(at: 4_800))

  gate.didFinishInference(processedSampleCount: 4_800, durationSeconds: 0.1)
  #expect(!gate.shouldRun(at: 9_599))
  #expect(gate.shouldRun(at: 9_600))

  gate.didFinishInference(processedSampleCount: 9_600, durationSeconds: 0.5)
  #expect(gate.requiredNewSampleCount == 16_000)
  #expect(!gate.shouldRun(at: 25_599))
  #expect(gate.shouldRun(at: 25_600))
}
