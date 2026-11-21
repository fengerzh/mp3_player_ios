import AVFoundation
import MediaPlayer

@MainActor
final class AudioEngine: ObservableObject {
    @Published private(set) var currentId: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private let store: LibraryStore
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastPersist: Double = 0

    init(store: LibraryStore) {
        self.store = store
        configureAudioSession()
        setupRemoteCommands()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("音频会话配置失败: \(error)")
        }
    }

    var currentTrack: Track? {
        guard let id = currentId else { return nil }
        return store.tracks.first { $0.id == id }
    }

    /// 切换文件夹时只恢复曲目信息（不自动播放），进度条显示该文件夹上次的进度
    func prepare(id: String) {
        guard let track = store.tracks.first(where: { $0.id == id }) else { return }
        detachPlayer()
        currentId = id
        duration = track.duration
        currentTime = track.position
        isPlaying = false
        updateNowPlaying()
    }

    func unload() {
        detachPlayer()
        currentId = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        updateNowPlaying()
    }

    func play(id: String) {
        guard let track = store.tracks.first(where: { $0.id == id }) else { return }
        store.rememberTrack(id)

        if currentId == id, let player = player {
            if track.duration > 0 && currentTime >= track.duration - 0.5 {
                player.seek(to: CMTime.zero)
                currentTime = 0
            }
            player.rate = store.speed
            isPlaying = true
            updateNowPlaying()
            return
        }

        detachPlayer()
        let item = AVPlayerItem(url: store.fileURL(for: id))
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentId = id
        duration = track.duration
        currentTime = track.position
        if track.position > 0 {
            newPlayer.seek(to: CMTime(seconds: track.position, preferredTimescale: 600))
        }
        newPlayer.rate = store.speed
        isPlaying = true
        lastPersist = track.position
        attachObservers(to: newPlayer, item: item)
        updateNowPlaying()
    }

    func toggle() {
        if let id = currentId, store.visibleTracks.contains(where: { $0.id == id }) {
            if isPlaying { pause() } else { play(id: id) }
        } else if let first = store.visibleTracks.first {
            play(id: first.id)
        }
    }

    func pause() {
        player?.rate = 0
        isPlaying = false
        persistProgress()
        updateNowPlaying()
    }

    private func skipInFolder(_ delta: Int) {
        let list = store.visibleTracks
        guard !list.isEmpty else { return }
        if let id = currentId, let index = list.firstIndex(where: { $0.id == id }) {
            play(id: list[(index + delta + list.count) % list.count].id)
        } else {
            play(id: list[delta > 0 ? 0 : list.count - 1].id)
        }
    }

    func next() { skipInFolder(1) }

    func previous() { skipInFolder(-1) }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        updateNowPlaying()
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func setSpeed(_ value: Float) {
        store.setSpeed(value)
        if isPlaying { player?.rate = store.speed }
        updateNowPlaying()
    }

    func stopForRemoval(id: String) {
        if currentId == id {
            pause()
            detachPlayer()
            currentId = nil
            currentTime = 0
            duration = 0
            updateNowPlaying()
        }
    }

    func persistProgress() {
        guard let id = currentId else { return }
        let rawDuration = duration > 0 ? duration : (player?.currentItem?.duration.seconds ?? 0)
        store.saveProgress(
            id: id,
            position: currentTime,
            duration: rawDuration.isFinite ? rawDuration : 0
        )
    }

    private func detachPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.rate = 0
        player = nil
    }

    private func attachObservers(to player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds.isFinite ? time.seconds : 0
                self.currentTime = seconds
                if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                    self.duration = total
                }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
                info[MPMediaItemPropertyPlaybackDuration] = self.duration
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                if seconds - self.lastPersist >= 5 {
                    self.lastPersist = seconds
                    self.persistProgress()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistProgress()
                self?.next()
            }
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        if let track = currentTrack {
            info[MPMediaItemPropertyTitle] = track.name
            info[MPMediaItemPropertyArtist] = "本地音频"
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? store.speed : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let id = self.currentId else { return }
                self.play(id: id)
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }
}
