@preconcurrency import AVFoundation
import Foundation
@preconcurrency import WhisperKit

public struct AudioData: Sendable {
  public let samples: [Float]
  public let sampleRate: Double
  public let speechStartSeconds: Double

  public var durationSeconds: Double { Double(samples.count) / sampleRate }

  public init(samples: [Float], sampleRate: Double, speechStartSeconds: Double = 0) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.speechStartSeconds = speechStartSeconds
  }
}

public enum AudioIO {
  public static let targetSampleRate = 16_000.0

  public static func load(url: URL) throws -> AudioData {
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    guard !samples.isEmpty else { throw AudioError.emptyAudio }
    return AudioData(
      samples: samples,
      sampleRate: targetSampleRate,
      speechStartSeconds: speechStart(in: samples, sampleRate: targetSampleRate)
    )
  }

  static func buffer(samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ), let channel = buffer.floatChannelData?.pointee
    else {
      throw AudioError.cannotAllocateBuffer
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
      channel[index] = sample
    }
    return buffer
  }

  static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws
    -> AVAudioPCMBuffer
  {
    if buffer.format == format { return buffer }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
      throw AudioError.cannotCreateConverter
    }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw AudioError.cannotAllocateBuffer
    }
    let input = OneShotAudioInput(buffer)
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
      input.take(inputStatus)
    }
    guard status != .error else {
      throw conversionError ?? AudioError.conversionFailed
    }
    return converted
  }

  private static func speechStart(in samples: [Float], sampleRate: Double) -> Double {
    let frameSize = Int(sampleRate * 0.02)
    let peak = samples.map(abs).max() ?? 0
    let threshold = max(0.008, Double(peak) * 0.08)
    var consecutive = 0
    for offset in stride(from: 0, to: samples.count, by: frameSize) {
      let end = min(offset + frameSize, samples.count)
      let frame = samples[offset..<end]
      let rms = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(frame.count, 1)))
      consecutive = rms >= threshold ? consecutive + 1 : 0
      if consecutive == 2 {
        return Double(max(0, offset - frameSize)) / sampleRate
      }
    }
    return 0
  }
}

private final class OneShotAudioInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.withLock {
      guard !supplied else {
        status.pointee = .endOfStream
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
  }
}

enum AudioError: LocalizedError {
  case cannotAllocateBuffer
  case cannotCreateConverter
  case conversionFailed
  case emptyAudio

  var errorDescription: String? {
    switch self {
    case .cannotAllocateBuffer: "Could not allocate an audio buffer."
    case .cannotCreateConverter: "Could not create a compatible audio converter."
    case .conversionFailed: "Audio conversion failed."
    case .emptyAudio: "The audio file is empty."
    }
  }
}
