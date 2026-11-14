import AVFoundation
import Observation

/// Plays a session recording and maps wall-clock times (transcript, logs) onto it.
@MainActor @Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var title = ""
    /// The wall-clock time of the recording's first sample.
    private(set) var origin: Date?
    var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    var isLoaded: Bool { player != nil }
    var currentDate: Date? { origin?.addingTimeInterval(currentTime) }

    func load(_ url: URL, origin: Date?, title: String) async {
        unload()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.origin = origin
        self.title = title
        duration = (try? await item.asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    func unload() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        origin = nil
        title = ""
    }

    /// Corrects when the loaded recording started, without interrupting playback.
    func setOrigin(_ date: Date?) { if isLoaded { origin = date } }

    func toggle() { isPlaying ? pause() : play() }
    func play() { guard let player else { return }; player.rate = rate; isPlaying = true }
    func pause() { player?.pause(); isPlaying = false }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    /// Seconds into the recording for a wall-clock time, if the recording covers it.
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
}

/// Final Cut–style skimming: as the pointer moves over a spectrogram, play short bursts of the audio under it,
/// without moving the playhead. Uses its own engine so the main player is left alone.
@MainActor @Observable
final class Skimmer {
    static let enabledKey = "skimming"
    var isEnabled: Bool = UserDefaults.standard.object(forKey: Skimmer.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); if !isEnabled { end() } }
    }
    /// Where the pointer is on the session's wall clock, drawn as the skimmer line in every lane.
    private(set) var date: Date?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var lastSecond: TimeInterval?
    @ObservationIgnored private var lastBurst = Date.distantPast

    init() { engine.attach(node) }

    /// The pointer is at `date` over the recording in `url`, whose first sample is at `origin`.
    /// Plays audio only when `audible` (the main player is paused, say).
    func move(to date: Date, url: URL, origin: Date, audible: Bool) {
        self.date = date
        guard isEnabled, audible, prepare(url) , let file else { return }
        let second = date.timeIntervalSince(origin)
        let now = Date()
        // A burst about as long as the pointer moved, so slow skims sound slow and fast ones stay short.
        let moved = abs(second - (lastSecond ?? second))
        guard now.timeIntervalSince(lastBurst) >= 0.04 || lastSecond == nil else { return }
        lastSecond = second
        lastBurst = now
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(second * rate)
        guard first >= 0, first < file.length else { node.stop(); return }
        let length = min(max(moved, 0.08), 0.25)
        let frames = AVAudioFrameCount(min(Double(file.length - first), length * rate))
        node.stop()
        node.scheduleSegment(file, startingFrame: first, frameCount: frames, at: nil)
        node.play()
    }

    /// The pointer left the spectrogram, or a drag took over.
    func end() {
        date = nil
        lastSecond = nil
        node.stop()
    }

    private func prepare(_ url: URL) -> Bool {
        if file?.url == url { return true }
        node.stop()
        engine.stop()
        guard let opened = try? AVAudioFile(forReading: url) else { file = nil; return false }
        file = opened
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: opened.processingFormat)
        do { try engine.start() } catch { file = nil; return false }
        return true
    }
}
