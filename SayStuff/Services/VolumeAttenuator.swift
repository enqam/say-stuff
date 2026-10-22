import CoreAudio
import AudioToolbox
import QuartzCore

/// Smoothly lowers system output volume while recording and fades it back afterwards.
/// The original volume is persisted so a crash mid-recording can't leave the Mac quiet.
final class VolumeAttenuator {
    private let queue = DispatchQueue(label: "com.saystuff.volume", qos: .userInitiated)

    // queue state
    private var device: AudioDeviceID?
    private var savedVolume: Float?
    private var fadeTimer: DispatchSourceTimer?
    private var pendingAttenuation: DispatchWorkItem?
    private var restoreCheck: DispatchWorkItem?

    private let defaults = UserDefaults.standard
    private let isAttenuatingKey = "VolumeAttenuator_isAttenuating"
    private let savedVolumeKey = "VolumeAttenuator_savedVolume"
    private let savedDeviceKey = "VolumeAttenuator_savedDevice"

    private let fadeDownDuration: Double = 0.8
    static let fadeUpDuration: Double = 0.45
    private let tickRate: Double = 120
    /// Bluetooth speakers get each step as a radio command; at 120 Hz some are dropped.
    private let bluetoothTickRate: Double = 30

    init() {
        queue.sync { recoverFromCrash() }
    }

    /// Fades output to `fraction` of the current volume, optionally after `delay`
    /// (so a start sound can finish at full volume).
    func attenuate(to fraction: Float, after delay: TimeInterval = 0) {
        let work = DispatchWorkItem { [weak self] in self?.beginAttenuation(fraction) }
        queue.async { [self] in
            pendingAttenuation?.cancel()
            pendingAttenuation = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Fades back to the saved volume. `completion` runs on the main queue once it's done
    /// (immediately if nothing was attenuated).
    func restore(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            pendingAttenuation?.cancel()
            pendingAttenuation = nil
            guard let device, let target = savedVolume else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            fade(device: device, to: target, duration: Self.fadeUpDuration) { [self] in
                confirm(device: device, volume: target, attempt: 1) { [self] in
                    clearSavedState()
                    if let completion { DispatchQueue.main.async(execute: completion) }
                }
            }
        }
    }

    /// Synchronous restore for app termination.
    func restoreImmediately() {
        queue.sync {
            pendingAttenuation?.cancel()
            restoreCheck?.cancel()
            restoreCheck = nil
            fadeTimer?.cancel()
            fadeTimer = nil
            if let device, let savedVolume { setVolume(device: device, volume: savedVolume) }
            clearSavedState()
        }
    }

    // MARK: - queue

    private func beginAttenuation(_ fraction: Float) {
        pendingAttenuation = nil
        if savedVolume == nil {
            guard let output = defaultOutputDevice(), let current = getVolume(device: output), current > 0.01 else { return }
            device = output
            savedVolume = current
            defaults.set(true, forKey: isAttenuatingKey)
            defaults.set(current, forKey: savedVolumeKey)
            defaults.set(Int(output), forKey: savedDeviceKey)
        }
        guard let device, let savedVolume else { return }
        fade(device: device, to: savedVolume * fraction, duration: fadeDownDuration, completion: nil)
    }

    /// Eased fade from the device's *current* volume, so reversing mid-fade never jumps.
    private func fade(device: AudioDeviceID, to target: Float, duration: Double, completion: (() -> Void)?) {
        fadeTimer?.cancel()
        fadeTimer = nil
        restoreCheck?.cancel()
        restoreCheck = nil

        guard let start = getVolume(device: device), abs(start - target) > 0.002 else {
            setVolume(device: device, volume: target)
            completion?()
            return
        }

        let startTime = CACurrentMediaTime()
        let rate = isBluetooth(device) ? bluetoothTickRate : tickRate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / rate, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer else { return }
            let t = min((CACurrentMediaTime() - startTime) / duration, 1)
            // Coming back up, most of the volume returns early so the done sound, played
            // as the text lands, isn't muffled; going down stays a gentle smoothstep.
            let eased = target > start ? Float(1 - pow(1 - t, 3)) : Float(t * t * (3 - 2 * t))
            self.setVolume(device: device, volume: start + (target - start) * eased)
            if t >= 1 {
                timer.cancel()
                if self.fadeTimer === timer { self.fadeTimer = nil }
                completion?()
            }
        }
        fadeTimer = timer
        timer.resume()
    }

    /// Reads the volume back and re-sends it until it sticks: a Bluetooth speaker can drop or
    /// reorder the last steps of a fade and stay quiet. The saved state stays until then.
    private func confirm(device: AudioDeviceID, volume: Float, attempt: Int, done: @escaping () -> Void) {
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreCheck = nil
            guard let current = self.getVolume(device: device), abs(current - volume) > 0.02, attempt < 6 else {
                if attempt > 1 { print("[VolumeAttenuator] Restore needed \(attempt - 1) retries") }
                done()
                return
            }
            self.setVolume(device: device, volume: volume)
            self.confirm(device: device, volume: volume, attempt: attempt + 1, done: done)
        }
        restoreCheck = check
        queue.asyncAfter(deadline: .now() + 0.12 * Double(attempt), execute: check)
    }

    private func clearSavedState() {
        device = nil
        savedVolume = nil
        defaults.removeObject(forKey: isAttenuatingKey)
        defaults.removeObject(forKey: savedVolumeKey)
        defaults.removeObject(forKey: savedDeviceKey)
    }

    private func recoverFromCrash() {
        guard defaults.bool(forKey: isAttenuatingKey) else { return }
        let volume = defaults.float(forKey: savedVolumeKey)
        let savedDevice: AudioDeviceID? = defaults.object(forKey: savedDeviceKey) == nil
            ? nil
            : AudioDeviceID(defaults.integer(forKey: savedDeviceKey))
        if volume > 0, let output = savedDevice ?? defaultOutputDevice() {
            setVolume(device: output, volume: volume)
            print("[VolumeAttenuator] Crash recovery: restored volume to \(volume)")
        }
        clearSavedState()
    }

    // MARK: - CoreAudio

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func getVolume(device: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private func setVolume(device: AudioDeviceID, volume: Float) {
        var value = min(max(volume, 0), 1)
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
