import AppKit
import AudioToolbox
import CoreAudio

/// CoreAudio output devices: the list, sample rate, bit depth, hardware volume and AirPlay targets.
enum CoreOut {
    struct Device {
        let id: AudioObjectID
        let uid: String
        let name: String
        let transport: UInt32
        var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
        var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }
        /// A note shown next to the device name.
        var note: String {
            if isBluetooth { return "Bluetooth: re-compressed by the connection" }
            if isAirPlay { return "AirPlay" }
            switch transport {
            case kAudioDeviceTransportTypeUSB: return "USB"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
            default: return ""
            }
        }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    static let standardRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
        var a = address(sel, scope), v = zero, size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private static func list<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ zero: T) -> [T] {
        var a = address(sel, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var v = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return [] }
        return v
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var a = address(sel), ref: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let s = ref?.takeRetainedValue() else { return "" }
        return s as String
    }

    @discardableResult
    private static func store<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ newValue: T) -> Bool {
        var a = address(sel, scope), v = newValue
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    // MARK: devices

    static var systemDefault: AudioObjectID { value(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, zeroID) ?? 0 }
    private static let zeroID = AudioObjectID(0)

    static func devices() -> [Device] {
        list(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, zeroID).compactMap { id in
            guard !list(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, zeroID).isEmpty else { return nil }
            let hidden: UInt32 = value(id, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
            guard hidden == 0 else { return nil }
            return info(id)
        }
    }

    static func info(_ id: AudioObjectID) -> Device {
        Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
               transport: value(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0)
    }

    static func device(uid: String) -> AudioObjectID? { devices().first { $0.uid == uid }?.id }

    // MARK: sample rate & format

    static func rate(_ id: AudioObjectID) -> Double { value(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) ?? 0 }

    static func rates(_ id: AudioObjectID) -> [Double] {
        let ranges = list(id, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, AudioValueRange())
        var out = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { out.insert(r.mMinimum) }
            for s in standardRates where s >= r.mMinimum && s <= r.mMaximum { out.insert(s) }
        }
        return out.sorted()
    }

    /// The rate the device should run at for a song: the song's own rate when the device has it, else a clean
    /// multiple of it (44.1 → 88.2 kHz), else the closest rate the device offers.
    static func bestRate(for r: Double, on id: AudioObjectID) -> Double? {
        let all = rates(id)
        guard !all.isEmpty, r > 0 else { return nil }
        if all.contains(r) { return r }
        if let m = all.first(where: { $0 > r && ($0 / r).rounded() == $0 / r }) { return m }
        return all.min { abs($0 - r) < abs($1 - r) }
    }

    private static func outputStream(_ id: AudioObjectID) -> AudioObjectID? { list(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, zeroID).first }

    /// Bits the device hardware takes per sample, and whether it takes floating point.
    static func physicalFormat(_ id: AudioObjectID) -> (bits: Int, float: Bool)? {
        guard let s = outputStream(id), let f = value(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription()) else { return nil }
        return (Int(f.mBitsPerChannel), f.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    /// Switches the device to `rate`, choosing its deepest PCM format there (so a 24-bit song isn't cut to 16 bits).
    /// Setting the physical format changes the rate in the same step, so the device reconfigures only once.
    @discardableResult
    static func setRate(_ id: AudioObjectID, _ r: Double) -> Bool {
        if let s = outputStream(id) {
            let cur = value(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            let formats = list(s, kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, AudioStreamRangedDescription())
                .filter { $0.mSampleRateRange.mMinimum <= r && r <= $0.mSampleRateRange.mMaximum }
                .map(\.mFormat)
                .filter { $0.mFormatID == kAudioFormatLinearPCM && $0.mFormatFlags & kAudioFormatFlagIsNonMixable == 0
                    && $0.mChannelsPerFrame == (cur?.mChannelsPerFrame ?? $0.mChannelsPerFrame) }
            if var best = formats.max(by: { depth($0) < depth($1) }) {
                best.mSampleRate = r
                if store(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, best) { return true }
            }
        }
        return store(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, r)
    }

    private static func depth(_ f: AudioStreamBasicDescription) -> Int {
        Int(f.mBitsPerChannel) * 2 + (f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? 1 : 0)
    }

    // MARK: volume

    static func volume(_ id: AudioObjectID) -> Float? {
        value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(0))
    }

    static func hasVolume(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    static func setVolume(_ id: AudioObjectID, _ v: Float) -> Bool {
        store(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(max(0, min(1, v))))
    }

    // MARK: data sources (the receivers behind the AirPlay device, or speakers / headphones on some devices)

    static func dataSources(_ id: AudioObjectID) -> [(id: UInt32, name: String)] {
        list(id, kAudioDevicePropertyDataSources, kAudioObjectPropertyScopeOutput, UInt32(0)).map { src in
            var sid = src
            var name: Unmanaged<CFString>?
            let ok = withUnsafeMutablePointer(to: &sid) { ip in
                withUnsafeMutablePointer(to: &name) { op in
                    var a = address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioObjectPropertyScopeOutput)
                    var trans = AudioValueTranslation(mInputData: ip, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                      mOutputData: op, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &trans) == noErr
                }
            }
            return (src, ok ? (name?.takeRetainedValue() as String? ?? "Source \(src)") : "Source \(src)")
        }
    }

    static func dataSource(_ id: AudioObjectID) -> UInt32? { value(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, UInt32(0)) }
    @discardableResult
    static func setDataSource(_ id: AudioObjectID, _ src: UInt32) -> Bool { store(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, src) }

    // MARK: change notifications

    /// Calls `block` on the main queue whenever the property changes.
    static func listen(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ block: @escaping @MainActor () -> Void) {
        var a = address(sel, scope)
        AudioObjectAddPropertyListenerBlock(id, &a, DispatchQueue.main) { _, _ in MainActor.assumeIsolated { block() } }
    }
    static func listenSystem(_ sel: AudioObjectPropertySelector, _ block: @escaping @MainActor () -> Void) { listen(system, sel, kAudioObjectPropertyScopeGlobal, block) }

    /// Bit depth a file was encoded from (16 or 24 for most FLAC), when the format records one.
    static func sourceBits(_ url: URL) -> Int? {
        var f: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &f) == noErr, let f else { return nil }
        defer { AudioFileClose(f) }
        var bits: UInt32 = 0, size = UInt32(4)
        guard AudioFileGetProperty(f, kAudioFilePropertySourceBitDepth, &size, &bits) == noErr else { return nil }
        let v = Int(Int32(bitPattern: bits))
        return v > 0 ? v : (v < 0 ? -v : nil)   // negative = floating point source
    }
}
