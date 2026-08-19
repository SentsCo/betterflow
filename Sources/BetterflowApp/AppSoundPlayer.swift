import AppKit

enum BetterflowSound: Hashable {
  case recordingStarted
  case textInserted
  case textCopied
  case insertionFallback
}

@MainActor
final class AppSoundPlayer {
  private let sounds: [BetterflowSound: NSSound] = [
    .recordingStarted: NSSound(named: "Pop"),
    .textInserted: NSSound(named: "Glass"),
    .textCopied: NSSound(named: "Glass"),
    .insertionFallback: NSSound(named: "Tink"),
  ].compactMapValues { $0 }

  func play(_ sound: BetterflowSound) {
    guard let player = sounds[sound] else { return }
    for sound in sounds.values {
      sound.stop()
    }
    player.volume = sound == .textInserted || sound == .textCopied ? 0.4 : 0.35
    player.play()
  }
}
