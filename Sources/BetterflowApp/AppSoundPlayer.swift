import AudioToolbox
import Foundation

enum BetterflowSound: CaseIterable, Hashable, Sendable {
  case recordingStarted
  case textInserted
  case textCopied
  case insertionFallback

  fileprivate var systemSoundName: String {
    switch self {
    case .recordingStarted: "Pop"
    case .textInserted, .textCopied: "Glass"
    case .insertionFallback: "Tink"
    }
  }
}

@MainActor
final class AppSoundPlayer {
  private let soundIDs: [BetterflowSound: SystemSoundID]

  init() {
    soundIDs = Dictionary(
      uniqueKeysWithValues: BetterflowSound.allCases.compactMap { sound in
        let url = URL(fileURLWithPath: "/System/Library/Sounds")
          .appendingPathComponent(sound.systemSoundName)
          .appendingPathExtension("aiff")
        var soundID = SystemSoundID()
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError
        else { return nil }
        return (sound, soundID)
      }
    )
  }

  deinit {
    for soundID in soundIDs.values {
      AudioServicesDisposeSystemSoundID(soundID)
    }
  }

  func play(_ sound: BetterflowSound) {
    guard let soundID = soundIDs[sound] else { return }
    AudioServicesPlaySystemSound(soundID)
  }
}
