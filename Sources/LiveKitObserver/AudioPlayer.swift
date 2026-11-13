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
