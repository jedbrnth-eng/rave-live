import CoreAudio
import Foundation

/// How long after capture the user actually hears the sound: CoreAudio-reported latency of the
/// default output device (device + stream latency + safety offset + I/O buffer). Bluetooth headphones
/// add far more than wired speakers, so visuals timed to the capture clock would run early on AirPods.
enum OutputLatency {
    struct Info { var seconds: Double; var name: String; var transport: String }

    static func current() -> Info {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else {
            return Info(seconds: 0.02, name: "?", transport: "?")
        }
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32 {
            var v: UInt32 = 0; var sz = UInt32(4)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : 0
        }
        var sr: Float64 = 48000; var srSize = UInt32(8)
        var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &srAddr, 0, nil, &srSize, &sr)
        // first output stream's own latency
        var streamLat: UInt32 = 0
        var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var sSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &sAddr, 0, nil, &sSize) == noErr, sSize >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(sSize) / 4)
            if AudioObjectGetPropertyData(dev, &sAddr, 0, nil, &sSize, &streams) == noErr, let st = streams.first {
                var la = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var lsz = UInt32(4); _ = AudioObjectGetPropertyData(st, &la, 0, nil, &lsz, &streamLat)
            }
        }
        let frames = u32(kAudioDevicePropertyLatency) + u32(kAudioDevicePropertySafetyOffset) + u32(kAudioDevicePropertyBufferFrameSize) + streamLat
        let transportCode = u32(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        let transport: String
        switch transportCode {
        case kAudioDeviceTransportTypeBuiltIn: transport = "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = "bluetooth"
        case kAudioDeviceTransportTypeUSB: transport = "usb"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = "hdmi/dp"
        case kAudioDeviceTransportTypeAirPlay: transport = "airplay"
        default: transport = "other"
        }
        var name: CFString = "" as CFString; var nSize = UInt32(MemoryLayout<CFString>.size)
        var nAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &nAddr, 0, nil, &nSize, $0) }
        var secs = Double(frames) / max(8000, sr)
        // CoreAudio under-reports Bluetooth (codec + radio). Typical A2DP/AAC end-to-end is ~150-250 ms.
        if transport == "bluetooth" { secs = max(secs, 0.18) }
        if transport == "airplay" { secs = max(secs, 1.8) }
        return Info(seconds: secs, name: name as String, transport: transport)
    }
}
