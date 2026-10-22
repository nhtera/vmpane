@preconcurrency import AVFoundation
@preconcurrency import CocoaSpice
import os

/// A Windows VM's sound, through SPICE (QEMU's `spice` audiodev): the guest's playback goes to the Mac's output,
/// and while the VM's microphone setting is on, the Mac's microphone goes to the guest's recording. CoreAudio runs
/// here, in the helper (which has the microphone entitlement and usage text), never in QEMU. SPICE calls on its main
/// loop thread; audio starts and stops on a queue of its own, so a slow device or the microphone question never
/// holds up the display. The Mac's microphone is open only while the guest records: `recordStop`, the session's end
/// (`sessionEnded`, also when SPICE never said the recording stopped) and the setting turned off all close it.
final class SpiceAudio: NSObject, CSAudioSink, @unchecked Sendable {
    private static let log = Logger(subsystem: "app.vmpane.mac.vm", category: "spice-audio")
    /// Guest sound queued for the output at most this long: more (the guest a little faster than the Mac's device) is
    /// dropped, so the sound never lags behind the picture.
    static let maxQueuedSeconds = 0.3
    /// Itests: the guest's recording is noted but the Mac's microphone is never opened (its permission question
    /// would be a dialog on the Mac's screen); the guest records silence.
    static let microphoneOff = ProcessInfo.processInfo.environment["VMPANE_TEST_NO_MICROPHONE"] == "1"

    private struct Format: Equatable {
        var channels: Int
        var rate: Int
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.vmpane.mac.vm.spice-audio")

    // Guarded by `lock` (read on SPICE's thread and the engines' threads).
    private var playbackOn = false
    private var recordingOn = false
    private var player: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
    private var queuedFrames = 0
    /// The guest's levels, kept across its streams (QEMU sends them only when the guest changes them).
    private var playLevel: Float = 1
    private var recordLevel: Float = 1
    /// The guest records now (late microphone buffers after its stop are dropped).
    private var recording = false
    private weak var _connection: CSConnection?
    var connection: CSConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }

    // On `queue`.
    private var playEngine: AVAudioEngine?
    private var engineFormat: Format?
    /// What the guest asked for and has not stopped: started (again) when the setting allows, or after a device change.
    private var playbackRequest: Format?
    private var recordEngine: AVAudioEngine?
    private var recordRequest: Format?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged(_:)), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    /// The VM's sound settings, at each start: playback to the Mac's output, recording from its microphone.
    func configure(output: Bool, input: Bool) {
        lock.withLock { (playbackOn, recordingOn) = (output, input) }
        queue.async { [self] in
            if output, let request = playbackRequest, playEngine == nil { startPlayback(request) } else if !output { stopPlayback() }
            if input, let request = recordRequest, recordEngine == nil { startRecording(request) } else if !input { stopRecording() }
        }
    }

    /// The SPICE session went away (the VM stopped, paused or restarts): nothing plays or records until it comes back.
    func sessionEnded() {
        lock.withLock { recording = false }
        queue.async { [self] in
            playbackRequest = nil
            recordRequest = nil
            stopPlayback()
            stopRecording()
        }
    }

    /// The Mac's output or input device changed: an engine stops then, so each one starts again with the new device.
    @objc private func configurationChanged(_ note: Notification) {
        let engine = note.object as? AVAudioEngine
        queue.async { [self] in
            if let engine, engine === playEngine, let request = playbackRequest {
                stopPlayback()
                startPlayback(request)
            }
            if let engine, engine === recordEngine, let request = recordRequest {
                startRecording(request)
            }
        }
    }

    // MARK: Playback

    func playbackStart(withChannels channels: Int32, rate: Int32) {
        let format = Format(channels: Int(channels), rate: Int(rate))
        queue.async { [self] in
            playbackRequest = format
            // The same format as the stream before: the running engine plays it (no sound lost while one starts).
            guard playEngine == nil || engineFormat != format else { return }
            startPlayback(format)
        }
    }

    func playbackData(_ data: UnsafeRawPointer, size: Int32) {
        // Signed 16-bit interleaved → the player's float format, scheduled at once (this is SPICE's thread).
        lock.lock()
        guard playbackOn, let player, let format = playFormat else {
            lock.unlock()
            return
        }
        let channels = Int(format.channelCount)
        let frames = Int(size) / (2 * channels)
        guard frames > 0, queuedFrames + frames <= Int(format.sampleRate * Self.maxQueuedSeconds),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let out = buffer.floatChannelData
        else {
            lock.unlock()
            return
        }
        queuedFrames += frames
        lock.unlock()
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = data.assumingMemoryBound(to: Int16.self)
        for frame in 0..<frames {
            for channel in 0..<channels { out[channel][frame] = Float(samples[frame * channels + channel]) / 32768 }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            lock.withLock { queuedFrames = max(0, queuedFrames - frames) }
        }
    }

    func playbackStop() {
        // The engine stays for the guest's next stream (Windows starts one for every sound); the session's end or the
        // setting turned off stops it.
        queue.async { [self] in playbackRequest = nil }
    }

    func playbackVolume(_ volume: Float, muted: Bool) {
        lock.withLock {
            playLevel = Self.level(volume, muted: muted)
            player?.volume = playLevel
        }
    }

    /// SPICE's volume (0 to 1, linear in its 16-bit range) as a gain: cubed, as spice-gtk's own audio does.
    static func level(_ volume: Float, muted: Bool) -> Float {
        muted ? 0 : max(0, min(1, volume * volume * volume))
    }

    private func startPlayback(_ request: Format) {
        stopPlayback()
        guard lock.withLock({ playbackOn }), request.channels > 0,
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(request.rate), channels: AVAudioChannelCount(request.channels))
        else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Self.log.error("cannot play the guest's sound: \(String(describing: error), privacy: .public)")
            return
        }
        player.play()
        (playEngine, engineFormat) = (engine, request)
        lock.withLock {
            player.volume = playLevel
            (self.player, playFormat, queuedFrames) = (player, format, 0)
        }
        Self.log.notice("guest sound playing: \(request.channels, privacy: .public) channels at \(request.rate, privacy: .public) Hz")
    }

    private func stopPlayback() {
        let player = lock.withLock {
            defer { (self.player, playFormat, queuedFrames) = (nil, nil, 0) }
            return self.player
        }
        player?.stop()
        playEngine?.stop()
        (playEngine, engineFormat) = (nil, nil)
    }

    // MARK: Recording

    func recordStart(withChannels channels: Int32, rate: Int32) {
        let format = Format(channels: Int(channels), rate: Int(rate))
        queue.async { [self] in
            recordRequest = format
            startRecording(format)
        }
    }

    func recordStop() {
        lock.withLock { recording = false }
        queue.async { [self] in
            if recordRequest != nil { Self.log.notice("the guest stopped recording") }
            recordRequest = nil
            stopRecording()
        }
    }

    func recordVolume(_ volume: Float, muted: Bool) {
        lock.withLock { recordLevel = Self.level(volume, muted: muted) }
    }

    /// The Mac's microphone, converted to what the guest asked for, while the VM's microphone setting is on. The first
    /// time, macOS asks the person whether VMPane may use the microphone; denied, the guest records silence.
    private func startRecording(_ request: Format) {
        stopRecording()
        guard lock.withLock({ recordingOn }), request.channels > 0, request.rate > 0 else { return }
        Self.log.notice("the guest records: \(request.channels, privacy: .public) channels at \(request.rate, privacy: .public) Hz")
        guard !Self.microphoneOff else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard granted, let self else { return }
                    queue.async { if let request = self.recordRequest, self.recordEngine == nil { self.startRecording(request) } }
                }
            } else {
                Self.log.notice("the microphone is not allowed for VMPane: the guest records silence")
            }
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(request.rate), channels: AVAudioChannelCount(request.channels),
                interleaved: true),
            let converter = AVAudioConverter(from: source, to: target)
        else {
            Self.log.error("no usable microphone for the guest")
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
            self?.send(buffer, converter: converter, target: target)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Self.log.error("cannot record from the microphone: \(String(describing: error), privacy: .public)")
            return
        }
        recordEngine = engine
        lock.withLock { recording = true }
        Self.log.notice("the Mac's microphone goes to the guest")
    }

    private func send(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        let (active, gain, connection) = lock.withLock { (recording, recordLevel, _connection) }
        guard active, let connection else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let input = OneBuffer(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in input.take(status) }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let count = Int(out.frameLength) * Int(target.channelCount)
        if gain < 1 {
            for i in 0..<count { samples[i] = Int16(Float(samples[i]) * gain) }
        }
        connection.sendRecordedAudio(Data(bytes: samples, count: count * 2))
    }

    private func stopRecording() {
        lock.withLock { recording = false }
        guard let engine = recordEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recordEngine = nil
    }
}

/// A converter's input: the one tap buffer, then "no more for now".
private final class OneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        defer { buffer = nil }
        status.pointee = buffer == nil ? .noDataNow : .haveData
        return buffer
    }
}
