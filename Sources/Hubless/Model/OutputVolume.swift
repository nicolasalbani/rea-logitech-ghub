import CoreAudio
import Foundation

/// The macOS output volume and mute of one audio device, found by name (e.g. "G560 Gaming Speaker").
/// This is the same volume as the menu-bar / keyboard volume when the device is the system output,
/// so it is live state, not a profile setting. The G560 exposes hardware volume on channels 1 and 2.
@MainActor
final class OutputVolume: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var level: Double = 0 // 0...1
    @Published private(set) var muted = false
    @Published private(set) var isDefaultOutput = false

    private let deviceName: String
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeElements: [UInt32] = []
    private var hasMute = false
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    private let listenerQueue = DispatchQueue.main
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.readState() }
    }
    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.locate() }
    }

    init(deviceName: String) {
        self.deviceName = deviceName
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = Self.address(sel)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, listenerQueue, systemListener)
        }
        locate()
    }

    /// Sets the output volume (0...1) on every hardware volume channel. Unmutes when raised above zero.
    func setLevel(_ value: Double) {
        guard isAvailable else { return }
        var v = Float32(max(0, min(1, value)))
        for el in volumeElements {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        level = Double(v)
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        guard isAvailable, hasMute else { return }
        var m: UInt32 = on ? 1 : 0
        var a = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        muted = on
    }

    var supportsMute: Bool { hasMute }

    // MARK: Discovery

    private func locate() {
        let found = Self.allDevices().first { Self.name(of: $0) == deviceName && Self.hasOutput($0) }
            ?? AudioObjectID(kAudioObjectUnknown)
        if found != listenedDevice { relisten(to: found) }
        deviceID = found
        volumeElements = [0, 1, 2, 3, 4, 5, 6, 7, 8].filter {
            Self.isSettable(found, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0)
        }
        // Prefer the master element when present; otherwise drive the individual channels.
        if volumeElements.contains(0) { volumeElements = [0] }
        hasMute = Self.isSettable(found, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, 0)
        isAvailable = found != kAudioObjectUnknown && !volumeElements.isEmpty
        readState()
    }

    private func relisten(to device: AudioObjectID) {
        let selectors: [(AudioObjectPropertySelector, UInt32)] =
            [(kAudioDevicePropertyMute, 0)] + (0...8).map { (kAudioDevicePropertyVolumeScalar, UInt32($0)) }
        if listenedDevice != kAudioObjectUnknown {
            for (sel, el) in selectors {
                var a = Self.address(sel, kAudioDevicePropertyScopeOutput, el)
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &a, listenerQueue, deviceListener)
            }
        }
        listenedDevice = device
        guard device != kAudioObjectUnknown else { return }
        for (sel, el) in selectors {
            var a = Self.address(sel, kAudioDevicePropertyScopeOutput, el)
            if AudioObjectHasProperty(device, &a) {
                AudioObjectAddPropertyListenerBlock(device, &a, listenerQueue, deviceListener)
            }
        }
    }

    private func readState() {
        guard isAvailable else { return }
        let levels: [Float32] = volumeElements.compactMap {
            Self.get(deviceID, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0, Float32(0))
        }
        if !levels.isEmpty { level = Double(levels.max()!) }
        if hasMute { muted = (Self.get(deviceID, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, 0, UInt32(0)) ?? 0) != 0 }
        let def = Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioObjectPropertyScopeGlobal, 0, AudioObjectID(0))
        isDefaultOutput = def == deviceID
    }

    // MARK: CoreAudio helpers

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ el: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    private static func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ el: UInt32, _ initial: T) -> T? {
        var a = address(sel, scope, el)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func isSettable(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                   _ scope: AudioObjectPropertyScope, _ el: UInt32) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var a = address(sel, scope, el)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    private static func allDevices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func name(of id: AudioObjectID) -> String? {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }
}
