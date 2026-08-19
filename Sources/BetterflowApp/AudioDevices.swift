import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let deviceID: AudioDeviceID
  let isDefault: Bool
}

enum AudioDeviceCatalog {
  static func inputDevices() -> [AudioInputDevice] {
    let defaultID = defaultInputDeviceID()
    return allDeviceIDs()
      .filter(hasInputChannels)
      .compactMap { deviceID in
        guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
          let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(
          id: uid,
          name: name,
          deviceID: deviceID,
          isDefault: deviceID == defaultID
        )
      }
      .sorted { left, right in
        if left.isDefault != right.isDefault { return left.isDefault }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
  }

  static func selectedDevice(
    priorityEnabled: Bool,
    priority: [String]
  ) -> AudioInputDevice? {
    let devices = inputDevices()
    if priorityEnabled,
      let preferred = priority.compactMap({ uid in devices.first { $0.id == uid } })
        .first
    {
      return preferred
    }
    return devices.first(where: \.isDefault) ?? devices.first
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return [] }
    var devices = [AudioDeviceID](
      repeating: 0,
      count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
    else { return [] }
    return devices
  }

  private static func defaultInputDeviceID() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
    else { return 0 }
    return deviceID
  }

  private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
      let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        as UnsafeMutableRawPointer?
    else { return false }
    defer { pointer.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else {
      return false
    }
    let list = pointer.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
  }

  private static func stringProperty(
    _ deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value?.takeUnretainedValue() as String?
  }

}
