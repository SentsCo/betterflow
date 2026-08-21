import AudioToolbox
import Foundation

private let microphoneInputCallback: AudioQueueInputCallback = {
  userData, queue, buffer, _, _, _ in
  guard let userData else { return }
  let capture = Unmanaged<MicrophoneCapture>.fromOpaque(userData).takeUnretainedValue()
  capture.receive(buffer: buffer, queue: queue)
}

actor MicrophoneCaptureLifecycle {
  private let capture: MicrophoneCapture

  init(capture: MicrophoneCapture) {
    self.capture = capture
  }

  func start(deviceUID: String?) throws -> AsyncStream<Int> {
    try capture.start(deviceUID: deviceUID)
  }

  func stop() -> [Float] {
    capture.stop()
  }
}

final class MicrophoneCapture: @unchecked Sendable {
  static let sampleRate = 24_000.0
  static let bufferDurationSeconds = 0.03

  private let lock = NSLock()
  private var queue: AudioQueueRef?
  private var samples: [Float] = []
  private var active = false
  private var latestLevel = 0.0
  private var sampleUpdatesContinuation: AsyncStream<Int>.Continuation?

  func start(deviceUID: String?) throws -> AsyncStream<Int> {
    stop()
    let (sampleUpdates, continuation) = AsyncStream<Int>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    lock.withLock {
      samples.removeAll(keepingCapacity: true)
      latestLevel = 0
      sampleUpdatesContinuation = continuation
    }

    var format = AudioStreamBasicDescription(
      mSampleRate: Self.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    var newQueue: AudioQueueRef?
    do {
      try check(
        AudioQueueNewInput(
          &format,
          microphoneInputCallback,
          Unmanaged.passUnretained(self).toOpaque(),
          nil,
          nil,
          0,
          &newQueue
        ),
        operation: "create the microphone input"
      )
      guard let newQueue else { throw MicrophoneCaptureError.missingQueue }
      lock.withLock { queue = newQueue }

      if let deviceUID {
        var uid = deviceUID as CFString
        try withUnsafePointer(to: &uid) { pointer in
          try check(
            AudioQueueSetProperty(
              newQueue,
              kAudioQueueProperty_CurrentDevice,
              pointer,
              UInt32(MemoryLayout<CFString>.size)
            ),
            operation: "select \(deviceUID)"
          )
        }
      }

      let bufferSize =
        UInt32(Self.sampleRate * Self.bufferDurationSeconds)
        * UInt32(MemoryLayout<Float>.size)
      for _ in 0..<3 {
        var buffer: AudioQueueBufferRef?
        try check(
          AudioQueueAllocateBuffer(newQueue, bufferSize, &buffer),
          operation: "allocate a microphone buffer"
        )
        guard let buffer else { throw MicrophoneCaptureError.missingBuffer }
        try check(
          AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil),
          operation: "enqueue a microphone buffer"
        )
      }
      lock.withLock { active = true }
      try check(AudioQueueStart(newQueue, nil), operation: "start microphone capture")
      return sampleUpdates
    } catch {
      if let newQueue {
        AudioQueueDispose(newQueue, true)
      }
      lock.withLock {
        queue = nil
        sampleUpdatesContinuation = nil
      }
      continuation.finish()
      throw error
    }
  }

  @discardableResult
  func stop() -> [Float] {
    let (currentQueue, continuation) = lock.withLock {
      active = false
      let continuation = sampleUpdatesContinuation
      sampleUpdatesContinuation = nil
      return (queue, continuation)
    }
    continuation?.finish()
    if let currentQueue {
      AudioQueueStop(currentQueue, true)
      AudioQueueDispose(currentQueue, true)
    }
    return lock.withLock {
      queue = nil
      latestLevel = 0
      return samples
    }
  }

  func snapshot() -> [Float] {
    lock.withLock { samples }
  }

  func samples(from start: Int, through end: Int) -> [Float] {
    lock.withLock {
      let lowerBound = max(0, min(start, samples.count))
      let upperBound = max(lowerBound, min(end, samples.count))
      return Array(samples[lowerBound..<upperBound])
    }
  }

  func level() -> Double {
    lock.withLock { latestLevel }
  }

  fileprivate func receive(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
    let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
    guard count > 0 else { return }
    let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
    let chunk = Array(UnsafeBufferPointer(start: pointer, count: count))
    let level = sqrt(chunk.reduce(0.0) { $0 + Double($1 * $1) } / Double(count))
    let update = lock.withLock { () -> (AsyncStream<Int>.Continuation, Int)? in
      guard active, let sampleUpdatesContinuation else { return nil }
      samples.append(contentsOf: chunk)
      latestLevel = min(1, level * 8)
      return (sampleUpdatesContinuation, samples.count)
    }
    if let (continuation, sampleCount) = update {
      continuation.yield(sampleCount)
      AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
  }

  private func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
      throw MicrophoneCaptureError.audioQueue(operation: operation, status: status)
    }
  }
}

enum MicrophoneCaptureError: LocalizedError {
  case missingQueue
  case missingBuffer
  case audioQueue(operation: String, status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .missingQueue: "macOS did not create a microphone input queue."
    case .missingBuffer: "macOS did not allocate a microphone buffer."
    case .audioQueue(let operation, let status):
      "Could not \(operation) (Core Audio \(status))."
    }
  }
}
