import AVFoundation
import Observation

/// One channel of one recording, played as its own track so it can be muted or soloed.
struct TrackID: Hashable, Sendable {
    let kind: RecordingSource.Kind
    let channel: Int
}

/// A track to load: a mono file, when its first sample was heard, and where it sits left to right.
struct PlaybackTrack: Sendable {
    let id: TrackID
    let file: URL
    let origin: Date?
    let pan: Float
}

/// Plays every channel of a session's recordings together, lined up on the session's wall clock, with mute and
/// solo per track, and maps wall-clock times (transcript, logs) onto the timeline. The timeline starts at the
/// earliest recording.
@MainActor @Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The wall-clock time the timeline starts at.
    private(set) var origin: Date?
    private(set) var muted: Set<TrackID> = []
    private(set) var soloed: Set<TrackID> = []
    var rate: Float = 1 {
        didSet {
            guard rate != oldValue else { return }
            let now = currentTime
            timePitch.rate = rate
            if isPlaying { start(at: now) }
        }
    }

    private final class Track {
        let id: TrackID
        let node = AVAudioPlayerNode()
        let file: AVAudioFile
        var origin: Date?
        var length: TimeInterval { Double(file.length) / file.processingFormat.sampleRate }
        init(id: TrackID, file: AVAudioFile, origin: Date?) { self.id = id; self.file = file; self.origin = origin }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let submix = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var tracks: [Track] = []
    /// The timeline position playback last started from, and the host time in seconds it started at.
    @ObservationIgnored private var clock: (time: TimeInterval, at: TimeInterval)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    var isLoaded: Bool { !tracks.isEmpty }
    var currentDate: Date? { origin?.addingTimeInterval(currentTime) }

    init() {
        engine.attach(submix)
        engine.attach(timePitch)
        engine.connect(submix, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        // The output device changed (headphones plugged in, say): the engine stopped, so start again where we were.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.start(at: self.position)
            }
        }
    }

    /// Loads the tracks, muting `muted`.
    func load(_ specs: [PlaybackTrack], muted: Set<TrackID> = []) {
        unload()
        for spec in specs {
            guard let file = try? AVAudioFile(forReading: spec.file) else { continue }
            let track = Track(id: spec.id, file: file, origin: spec.origin)
            engine.attach(track.node)
            engine.connect(track.node, to: submix, format: file.processingFormat)
            track.node.pan = spec.pan
            tracks.append(track)
        }
        self.muted = muted.intersection(tracks.map(\.id))
        layOut()
        applyGains()
    }

    func unload() {
        pause()
        for track in tracks { engine.detach(track.node) }
        tracks = []
        engine.stop()
        currentTime = 0
        duration = 0
        origin = nil
        muted = []
        soloed = []
    }

    /// Corrects when one recording started, keeping the playhead on the same moment.
    func setOrigin(_ date: Date?, of kind: RecordingSource.Kind) {
        guard tracks.contains(where: { $0.id.kind == kind }) else { return }
        let moment = currentDate, wasPlaying = isPlaying
        if wasPlaying { pause() }
        for track in tracks where track.id.kind == kind { track.origin = date }
        layOut()
        if let moment, let origin { currentTime = min(max(moment.timeIntervalSince(origin), 0), duration) }
        if wasPlaying { play() }
    }

    // MARK: Mute and solo

    func toggleMute(_ id: TrackID) { muted.formSymmetricDifference([id]); applyGains() }
    func toggleSolo(_ id: TrackID) { soloed.formSymmetricDifference([id]); applyGains() }

    /// Whether a track is heard: not muted, and soloed when any track is.
    func isAudible(_ id: TrackID) -> Bool { !muted.contains(id) && (soloed.isEmpty || soloed.contains(id)) }

    private func applyGains() {
        for track in tracks { track.node.volume = isAudible(track.id) ? 1 : 0 }
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard isLoaded, !isPlaying else { return }
        start(at: currentTime >= duration - 0.05 ? 0 : currentTime)
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = position
        for track in tracks { track.node.stop() }
        engine.pause()
        ticker?.invalidate()
        ticker = nil
        clock = nil
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if isPlaying { start(at: target) } else { currentTime = target }
    }

    func skip(_ delta: TimeInterval) { seek(to: (isPlaying ? position : currentTime) + delta) }

    /// Seconds into the timeline for a wall-clock time, if the recordings cover it.
    func offset(for date: Date?) -> TimeInterval? {
        guard let date, let origin else { return nil }
        let t = date.timeIntervalSince(origin)
        return t >= 0 && (duration == 0 || t <= duration + 1) ? t : nil
    }

    /// Jump to a moment, starting a little early so the lead-in is audible.
    func play(at date: Date?, leadIn: TimeInterval = 1.5) {
        guard let t = offset(for: date) else { return }
        seek(to: t - leadIn)
        play()
    }

    /// Starts every track at timeline position `time`, together. A track that starts later waits its turn.
    private func start(at time: TimeInterval) {
        for track in tracks { track.node.stop() }
        if !engine.isRunning {
            do { try engine.start() } catch { isPlaying = false; return }
        }
        let lead = AVAudioTime.hostTime(forSeconds: 0.05)
        let startHost = mach_absolute_time() + lead
        for track in tracks {
            let local = time - offset(of: track)
            guard local < track.length else { continue }
            let rate = track.file.processingFormat.sampleRate
            let first = AVAudioFramePosition(max(local, 0) * rate)
            let frames = track.file.length - first
            guard frames > 0 else { continue }
            // A track that begins later is scheduled that far into the node's own timeline.
            let when = local < 0 ? AVAudioTime(sampleTime: AVAudioFramePosition(-local * rate), atRate: rate) : nil
            track.node.scheduleSegment(track.file, startingFrame: first, frameCount: AVAudioFrameCount(frames), at: when)
            track.node.play(at: AVAudioTime(hostTime: startHost))
        }
        clock = (time, AVAudioTime.seconds(forHostTime: startHost))
        currentTime = time
        isPlaying = true
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Where playback is now on the timeline.
    private var position: TimeInterval {
        guard let clock else { return currentTime }
        let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - clock.at
        return clock.time + max(elapsed, 0) * Double(rate)
    }

    private func tick() {
        let now = position
        if now >= duration {
            pause()
            currentTime = duration
        } else {
            currentTime = now
        }
    }

    private func offset(of track: Track) -> TimeInterval {
        guard let origin, let start = track.origin else { return 0 }
        return start.timeIntervalSince(origin)
    }

    /// The timeline runs from the earliest recording's start to the latest one's end.
    private func layOut() {
        origin = tracks.compactMap(\.origin).min()
        duration = tracks.map { offset(of: $0) + $0.length }.max() ?? 0
    }
}

/// Final Cut–style skimming: as the pointer moves over a spectrogram, play the audio under it at normal speed,
/// without moving the playhead. Playback carries on smoothly while the pointer keeps up with it, jumps when the
/// pointer gets ahead or goes back, and fades out shortly after the pointer stops. Uses its own engine so the
/// main player is left alone.
@MainActor @Observable
final class Skimmer {
    static let enabledKey = "skimming"
    var isEnabled: Bool = UserDefaults.standard.object(forKey: Skimmer.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); if !isEnabled { end() } }
    }
    /// Where the pointer is on the session's wall clock, drawn as the skimmer line in every lane.
    private(set) var date: Date?

    /// How far the pointer may be from what is playing before playback jumps to it.
    private static let tolerance: TimeInterval = 0.35
    /// How long audio keeps going after the pointer stops.
    private static let linger: TimeInterval = 0.3
    /// Fades at the start and end of each stretch, so jumps don't click.
    private static let fade: TimeInterval = 0.012

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    /// The file second playback started from, and when.
    @ObservationIgnored private var started: (second: TimeInterval, at: Date)?
    @ObservationIgnored private var lastMove = Date.distantPast
    @ObservationIgnored private var stopper: Task<Void, Never>?

    init() { engine.attach(node) }

    /// The pointer is at `date` over the recording in `url`, whose first sample is at `origin`.
    /// Plays audio only when `audible` (the main player is paused, say).
    func move(to date: Date, url: URL, origin: Date, audible: Bool) {
        self.date = date
        guard isEnabled, audible, prepare(url), let file else { return }
        let second = date.timeIntervalSince(origin)
        let length = Double(file.length) / file.processingFormat.sampleRate
        guard second >= 0, second < length else { stop(); return }
        lastMove = Date()
        if let started, abs(started.second + Date().timeIntervalSince(started.at) - second) <= Self.tolerance {
            // Still keeping up: let it play.
        } else {
            play(from: second)
        }
        scheduleStop()
    }

    /// The pointer left the spectrogram, or a drag took over.
    func end() {
        date = nil
        stop()
    }

    private func play(from second: TimeInterval) {
        guard let file else { return }
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(second * rate)
        guard first < file.length else { return }
        node.stop()
        node.volume = 1
        // A short fade-in, then the rest of the file straight after it.
        let fadeFrames = AVAudioFrameCount(min(Double(file.length - first), Self.fade * rate))
        if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: fadeFrames) {
            file.framePosition = first
            if (try? file.read(into: buffer, frameCount: fadeFrames)) != nil, let data = buffer.floatChannelData {
                let n = Int(buffer.frameLength)
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<n { data[c][i] *= Float(i) / Float(max(n, 1)) }
                }
                node.scheduleBuffer(buffer)
            }
        }
        let rest = first + AVAudioFramePosition(fadeFrames)
        if rest < file.length {
            node.scheduleSegment(file, startingFrame: rest, frameCount: AVAudioFrameCount(file.length - rest), at: nil)
        }
        node.play()
        started = (second, Date())
    }

    /// Fades out once the pointer has been still for `linger`.
    private func scheduleStop() {
        stopper?.cancel()
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.linger))
            guard let self, !Task.isCancelled, Date().timeIntervalSince(self.lastMove) >= Self.linger else { return }
            await self.fadeOut()
        }
    }

    private func fadeOut() async {
        for step in stride(from: 0.75, through: 0, by: -0.25) {
            node.volume = Float(step)
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { node.volume = 1; return }
        }
        node.stop()
        node.volume = 1
        started = nil
    }

    private func stop() {
        stopper?.cancel()
        stopper = nil
        node.stop()
        node.volume = 1
        started = nil
    }

    private func prepare(_ url: URL) -> Bool {
        if file?.url == url { return true }
        stop()
        engine.stop()
        guard let opened = try? AVAudioFile(forReading: url) else { file = nil; return false }
        file = opened
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: opened.processingFormat)
        do { try engine.start() } catch { file = nil; return false }
        return true
    }
}

/// Each channel of a recording as its own mono file, decoded once and cached beside it, so channels can be muted
/// and soloed. Decoding also gives every sample its true place: AVPlayer mistimes LiveKit's Ogg Opus recordings,
/// which skip silent stretches. A mix whose channels are identical gives one file.
enum PlaybackFile {
    /// The cached files for `url`, one per distinct channel, decoding them first if needed.
    static func channels(_ url: URL) throws -> [URL] {
        let first = file(url, channel: 0), second = file(url, channel: 1)
        let fm = FileManager.default
        if fm.fileExists(atPath: first.path) {
            let input = try AVAudioFile(forReading: url)
            let count = Int(input.processingFormat.channelCount)
            if count == 1 || !fm.fileExists(atPath: second.path) { return [first] }
            let all = (0..<count).map { file(url, channel: $0) }
            if all.allSatisfy({ fm.fileExists(atPath: $0.path) }) { return all }
        }
        return try decode(url)
    }

    static func file(_ url: URL, channel: Int) -> URL { url.appendingPathExtension("ch\(channel).caf") }

    private static func decode(_ url: URL) throws -> [URL] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let count = Int(format.channelCount)
        guard count > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 1 << 16) else { throw CocoaError(.fileReadCorruptFile) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16,
        ]
        let partials = (0..<count).map { file(url, channel: $0).appendingPathExtension("partial") }
        for partial in partials { try? FileManager.default.removeItem(at: partial) }
        // Energy of each channel's difference from channel 0, against channel 0's, as the spectrogram measures it.
        var difference: Float = 0, signal: Float = 0
        do {
            let outputs = try partials.map { try AVAudioFile(forWriting: $0, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                let n = Int(buffer.frameLength)
                guard n > 0, let data = buffer.floatChannelData, let target = out.floatChannelData else { break }
                for c in 0..<count {
                    for i in 0..<n {
                        let v = data[c][i]
                        target[0][i] = v
                        if c == 0 { signal += v * v } else { let d = v - data[0][i]; difference += d * d }
                    }
                    out.frameLength = AVAudioFrameCount(n)
                    try outputs[c].write(from: out)
                }
            }
        }
        let identical = count > 1 && difference <= signal * 1e-4
        let keep = identical ? 1 : count
        var result: [URL] = []
        for c in 0..<count {
            let destination = file(url, channel: c)
            try? FileManager.default.removeItem(at: destination)
            if c < keep {
                try FileManager.default.moveItem(at: partials[c], to: destination)
                result.append(destination)
            } else {
                try? FileManager.default.removeItem(at: partials[c])
            }
        }
        return result
    }
}
