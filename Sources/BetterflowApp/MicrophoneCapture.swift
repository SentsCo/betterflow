import AudioToolbox
import Foundation
import OSLog

private let microphoneLogger = Logger(
  subsystem: "com.zachsents.betterflow",
  category: "Microphone"
)

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

  func prepare(deviceUID: String?) throws {
    try capture.prepare(deviceUID: deviceUID)
  }

  func start(deviceUID: String?) throws -> AsyncStream<Int> {
    try capture.start(deviceUID: deviceUID)
  }

  func enterIdle(_ behavior: MicrophoneIdleBehavior) {
    capture.enterIdle(behavior)
  }

  func shutdown() {
    capture.dispose()
  }
}

final class MicrophoneCapture: @unchecked Sendable {
  static let sampleRate = 24_000.0
  static let bufferDurationSeconds = 0.03

  private enum QueueState: String {
    case ready
    case running
    case pausing
    case paused
    case stopping
    case stopped
    case disposing
  }

  private let lock = NSLock()
  private var queue: AudioQueueRef?
  private var queueDeviceUID: String?
  private var queueState: QueueState?
  private var buffers: [AudioQueueBufferRef] = []
  private var samples: [Float] = []
  private var active = false
  private var pendingPeakLevel = 0.0
  private var sampleUpdatesContinuation: AsyncStream<Int>.Continuation?

  func prepare(deviceUID: String?) throws {
    let alreadyPrepared = lock.withLock {
      queue != nil && queueDeviceUID == deviceUID && queueState != .disposing
    }
    guard !alreadyPrepared else { return }
    dispose()
    let started = ContinuousClock.now
    try createQueue(deviceUID: deviceUID)
    microphoneLogger.info(
      "Microphone queue prepared elapsedMs=\(started.duration(to: .now).milliseconds)"
    )
  }

  func start(deviceUID: String?) throws -> AsyncStream<Int> {
    try prepare(deviceUID: deviceUID)
    let (sampleUpdates, continuation) = AsyncStream<Int>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let (currentQueue, currentBuffers, previousState) = lock.withLock {
      samples.removeAll(keepingCapacity: true)
      pendingPeakLevel = 0
      sampleUpdatesContinuation = continuation
      active = true
      let previousState = queueState
      queueState = .running
      return (queue, buffers, previousState)
    }
    guard let currentQueue, let previousState else {
      continuation.finish()
      throw MicrophoneCaptureError.missingQueue
    }

    let started = ContinuousClock.now
    do {
      if previousState == .stopped {
        for buffer in currentBuffers {
          try check(
            AudioQueueEnqueueBuffer(currentQueue, buffer, 0, nil),
            operation: "re-enqueue a microphone buffer"
          )
        }
      }
      try check(AudioQueueStart(currentQueue, nil), operation: "start microphone capture")
      microphoneLogger.info(
        "Microphone queue started from=\(previousState.rawValue, privacy: .public) elapsedMs=\(started.duration(to: .now).milliseconds)"
      )
      return sampleUpdates
    } catch {
      lock.withLock {
        active = false
        sampleUpdatesContinuation = nil
      }
      continuation.finish()
      dispose()
      throw error
    }
  }

  @discardableResult
  func finish() -> [Float] {
    let (continuation, capturedSamples) = lock.withLock {
      active = false
      let continuation = sampleUpdatesContinuation
      sampleUpdatesContinuation = nil
      pendingPeakLevel = 0
      return (continuation, samples)
    }
    continuation?.finish()
    return capturedSamples
  }

  func enterIdle(_ behavior: MicrophoneIdleBehavior) {
    let transition = lock.withLock { () -> (AudioQueueRef, QueueState)? in
      guard let queue, let queueState else { return nil }
      switch behavior {
      case .paused:
        guard queueState == .running else { return nil }
        self.queueState = .pausing
      case .stopped:
        guard queueState == .running || queueState == .paused || queueState == .pausing
        else { return nil }
        self.queueState = .stopping
      }
      return (queue, queueState)
    }
    guard let (currentQueue, previousState) = transition else { return }

    let started = ContinuousClock.now
    var status: OSStatus
    var idleState: QueueState
    switch behavior {
    case .paused:
      status = AudioQueuePause(currentQueue)
      idleState = .paused
      if status != noErr {
        microphoneLogger.notice(
          "Pausing microphone queue failed status=\(status); falling back to stopped"
        )
        status = AudioQueueStop(currentQueue, true)
        idleState = .stopped
      }
    case .stopped:
      status = AudioQueueStop(currentQueue, true)
      idleState = .stopped
    }
    lock.withLock {
      if queue == currentQueue { queueState = status == noErr ? idleState : previousState }
    }
    guard status == noErr else {
      microphoneLogger.error(
        "Microphone queue idle transition failed behavior=\(behavior.rawValue, privacy: .public) status=\(status)"
      )
      return
    }
    microphoneLogger.info(
      "Microphone queue idle behavior=\(idleState.rawValue, privacy: .public) elapsedMs=\(started.duration(to: .now).milliseconds)"
    )
  }

  func dispose() {
    let (currentQueue, continuation) = lock.withLock {
      active = false
      let continuation = sampleUpdatesContinuation
      sampleUpdatesContinuation = nil
      queueState = .disposing
      return (queue, continuation)
    }
    continuation?.finish()
    if let currentQueue { AudioQueueDispose(currentQueue, true) }
    lock.withLock {
      if queue == currentQueue {
        queue = nil
        queueDeviceUID = nil
        queueState = nil
        buffers = []
      }
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

  func consumePeakLevel() -> Double {
    lock.withLock {
      defer { pendingPeakLevel = 0 }
      return pendingPeakLevel
    }
  }

  fileprivate func receive(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
    let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
    guard count > 0 else { return }
    let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
    let chunk = UnsafeBufferPointer(start: pointer, count: count)
    let level = sqrt(chunk.reduce(0.0) { $0 + Double($1 * $1) } / Double(count))
    let result = lock.withLock {
      () -> (update: (AsyncStream<Int>.Continuation, Int)?, reenqueue: Bool) in
      guard self.queue == queue, let queueState else { return (nil, false) }
      let shouldReenqueue =
        queueState == .running || queueState == .pausing || queueState == .paused
      guard active, let sampleUpdatesContinuation else { return (nil, shouldReenqueue) }
      samples.append(contentsOf: chunk)
      pendingPeakLevel = max(pendingPeakLevel, min(1, level * 8))
      return ((sampleUpdatesContinuation, samples.count), shouldReenqueue)
    }
    if let (continuation, sampleCount) = result.update {
      continuation.yield(sampleCount)
    }
    if result.reenqueue {
      AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
  }

  private func createQueue(deviceUID: String?) throws {
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
      var newBuffers: [AudioQueueBufferRef] = []
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
        newBuffers.append(buffer)
      }
      lock.withLock {
        queue = newQueue
        queueDeviceUID = deviceUID
        queueState = .ready
        buffers = newBuffers
      }
    } catch {
      if let newQueue { AudioQueueDispose(newQueue, true) }
      throw error
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
