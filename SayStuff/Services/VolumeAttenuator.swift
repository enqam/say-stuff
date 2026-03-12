import CoreAudio
import AudioToolbox

/// Temporarily lowers system volume during recording and restores it when done.
/// Persists state to UserDefaults for crash recovery.
class VolumeAttenuator {
    private var savedVolume: Float?
    private var fadeTimer: DispatchSourceTimer?

    private let defaults = UserDefaults.standard
    private let isAttenuatingKey = "VolumeAttenuator_isAttenuating"
    private let savedVolumeKey = "VolumeAttenuator_savedVolume"

    // Fade-down parameters
    private let fadeDuration: Double = 0.25  // seconds
    private let fadeSteps: Int = 15

    init() {
        restoreIfNeeded()
    }

    func attenuate(to fraction: Float) {
        guard savedVolume == nil else { return }

        guard let deviceID = defaultOutputDevice() else {
            print("[VolumeAttenuator] No default output device")
            return
        }

        guard let currentVolume = getVolume(device: deviceID) else {
            print("[VolumeAttenuator] Failed to read volume")
            return
        }

        savedVolume = currentVolume

        // Persist for crash recovery
        defaults.set(true, forKey: isAttenuatingKey)
        defaults.set(currentVolume, forKey: savedVolumeKey)

        let targetVolume = currentVolume * fraction
        fadeVolume(device: deviceID, from: currentVolume, to: targetVolume)
        print("[VolumeAttenuator] Attenuating \(currentVolume) → \(targetVolume) over \(fadeDuration)s")
    }

    private func fadeVolume(device: AudioDeviceID, from startVolume: Float, to endVolume: Float) {
        fadeTimer?.cancel()

        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDelta = (endVolume - startVolume) / Float(fadeSteps)
        var currentStep = 0

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: stepInterval)
        timer.setEventHandler { [weak self] in
            currentStep += 1
            let volume = currentStep >= self?.fadeSteps ?? 0
                ? endVolume
                : startVolume + volumeDelta * Float(currentStep)
            self?.setVolume(device: device, volume: volume)

            if currentStep >= self?.fadeSteps ?? 0 {
                timer.cancel()
                self?.fadeTimer = nil
            }
        }
        fadeTimer = timer
        timer.resume()
    }

    func restore() {
        // Cancel any in-progress fade to prevent it from overwriting the restored volume
        fadeTimer?.cancel()
        fadeTimer = nil

        guard let volume = savedVolume else { return }

        if let deviceID = defaultOutputDevice() {
            setVolume(device: deviceID, volume: volume)
            print("[VolumeAttenuator] Restored volume to \(volume)")
        }

        savedVolume = nil
        defaults.removeObject(forKey: isAttenuatingKey)
        defaults.removeObject(forKey: savedVolumeKey)
    }

    /// Restore volume if app crashed while attenuating
    private func restoreIfNeeded() {
        guard defaults.bool(forKey: isAttenuatingKey) else { return }
        let volume = defaults.float(forKey: savedVolumeKey)
        guard volume > 0 else {
            defaults.removeObject(forKey: isAttenuatingKey)
            defaults.removeObject(forKey: savedVolumeKey)
            return
        }

        savedVolume = volume
        restore()
        print("[VolumeAttenuator] Crash recovery: restored volume to \(volume)")
    }

    // MARK: - CoreAudio

    private func defaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    private func getVolume(device: AudioDeviceID) -> Float? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            device,
            &propertyAddress,
            0, nil,
            &dataSize,
            &volume
        )

        return status == noErr ? volume : nil
    }

    private func setVolume(device: AudioDeviceID, volume: Float) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var vol = volume
        let dataSize = UInt32(MemoryLayout<Float32>.size)

        AudioObjectSetPropertyData(
            device,
            &propertyAddress,
            0, nil,
            dataSize,
            &vol
        )
    }
}
