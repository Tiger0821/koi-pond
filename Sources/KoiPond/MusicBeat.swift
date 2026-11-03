import AppKit
import Combine
import CoreAudio
import KoiPondCore
import KoiPondRender

/// Listens to Apple Music's audio, and only Music's, through a Core Audio process tap, and turns it into a
/// loudness and a beat count for the fish. Nothing is recorded or kept: each buffer is measured and dropped.
/// macOS asks the user once (Privacy & Security › Screen & System Audio Recording). It listens only while
/// a song is playing, so the audio hardware isn't kept awake otherwise.
final class MusicBeat: ObservableObject {
    @Published private(set) var status = "Off"

    private let lock = NSLock()
    private var latest = PondMusic()
    /// Read by the render loop once a frame.
    var music: PondMusic {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private let queue = DispatchQueue(label: "com.koifishwallpaper.koipond.beat", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Touched only on `queue` while listening.
    private var detector = BeatDetector(sampleRate: 48000)
    private var heardSeconds: Float = 0
    private var heardSound = false
    private var silenceCheck: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private var isListening: Bool { deviceID != kAudioObjectUnknown }

    func start(store: SettingsStore, player: MusicPlayer) {
        store.$settings.map(\.danceToMusic).removeDuplicates()
            .combineLatest(player.$isPlaying.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] dance, playing in self?.update(dance: dance, playing: playing) }
            .store(in: &cancellables)
    }

    private func update(dance: Bool, playing: Bool) {
        if dance && playing {
            listen()
        } else {
            stop()
            status = dance ? "Waiting for a song to play in Music" : "Off"
        }
    }

    // MARK: Listening

    private func listen() {
        guard !isListening else { return }
        guard #available(macOS 14.2, *) else {
            status = "Needs macOS 14.2 or later"
            return
        }
        do {
            let (tapUID, sampleRate) = try makeTap()
            try makeDevice(tapUID: tapUID)
            detector = BeatDetector(sampleRate: sampleRate)
            heardSeconds = 0
            heardSound = false
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { [weak self] _, input, _, _, _ in
                self?.process(input)
            }, "set up listening")
            procID = proc
            try check(AudioDeviceStart(deviceID, proc), "start listening")
            status = "Dancing to the beat"
            Log.info("listening to Music for the beat at \(Int(sampleRate)) Hz")
            scheduleSilenceCheck()
        } catch {
            Log.info("couldn't listen to Music: \(error)")
            stop()
            status = "Couldn't listen to Music"
        }
    }

    private func stop() {
        silenceCheck?.cancel()
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.lock()
        latest = PondMusic()
        lock.unlock()
    }

    /// When access is refused, macOS hands the tap silence rather than an error.
    private func scheduleSilenceCheck() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, isListening else { return }
            let heard = queue.sync { self.heardSound }
            let music = self.music
            Log.info("beat check after 5 s: heard sound \(heard), \(music.beats) beats, level \(String(format: "%.2f", music.level))")
            if !heard {
                status = "Can't hear Music: allow Koi Pond in Privacy & Security › Screen & System Audio Recording"
            }
        }
        silenceCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    @available(macOS 14.2, *)
    private func makeTap() throws -> (uid: String, sampleRate: Float) {
        let description: CATapDescription
        if #available(macOS 26.0, *) {
            // By bundle ID, so the tap follows Music even if it restarts.
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = [MusicPlayer.bundleID]
            description.isProcessRestoreEnabled = true
        } else {
            guard let process = Self.musicAudioProcess() else { throw TapError("Music has no audio yet") }
            description = CATapDescription(stereoMixdownOfProcesses: [process])
        }
        description.uuid = UUID()
        description.name = "Koi Pond beat"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "tap Music")

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap format")
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw TapError("unexpected tap format \(format)")
        }
        return (description.uuid.uuidString, Float(format.mSampleRate))
    }

    /// A private aggregate device clocked by the current output, with the tap as its only input.
    private func makeDevice(tapUID: String) throws {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koi Pond beat",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let output = Self.defaultOutputUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = output
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "create the listening device")
    }

    /// On the audio queue: folds every buffer into the detector, then publishes the result.
    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // Interleaved stereo arrives as one buffer; split channels as one buffer each, of which the first will do.
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let samples = data.assumingMemoryBound(to: Float.self)
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        var loudest: Float = 0
        for frame in 0..<frames {
            var mono: Float = 0
            for channel in 0..<channels { mono += samples[frame * channels + channel] }
            mono /= Float(channels)
            loudest = max(loudest, abs(mono))
            detector.add(mono)
        }
        if loudest > 0 { heardSound = true }
        let music = detector.music
        lock.lock()
        latest = music
        lock.unlock()
    }

    // MARK: Core Audio helpers

    private static func musicAudioProcess() -> AudioObjectID? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: MusicPlayer.bundleID).first?
            .processIdentifier else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var processID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &processID, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &uid, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw TapError("couldn't \(step) (\(status))") }
    }
}

private struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
