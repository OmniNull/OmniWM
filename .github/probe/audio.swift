import AudioToolbox
import CoreAudio

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var device = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
print("default output status \(status) device \(device)")
var volumeAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
var volume: Float32 = -1
var volumeSize = UInt32(MemoryLayout<Float32>.size)
let has = AudioObjectHasProperty(device, &volumeAddress)
let volumeStatus = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume)
print("main volume has \(has) status \(volumeStatus) value \(volume)")
