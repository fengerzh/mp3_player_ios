import Foundation
import AppIntents

/// 界面与 Siri 共用的播放中枢。整个 App 只有一套 store / engine，
/// 这样 Siri 说「继续播放」时恢复的进度，和界面上看到的是同一份。
@MainActor
final class PlaybackController {
    static let shared = PlaybackController()

    let store: LibraryStore
    let engine: AudioEngine

    private init() {
        let store = LibraryStore()
        let engine = AudioEngine(store: store)
        self.store = store
        self.engine = engine
        // 启动恢复：只显示当前文件夹上次曲目的进度，不自动播放（与原来的行为一致）
        if let folderID = store.currentFolderID,
           let lastID = store.lastTrackID(for: folderID),
           store.visibleTracks.contains(where: { $0.id == lastID }) {
            engine.prepare(id: lastID)
        }
    }

    /// Siri「继续播放」：优先继续当前曲目，其次恢复当前文件夹上次曲目。
    /// play(id:) 内部会从 track.position seek，所以是接着上次的进度播，不是从头开始。
    func resume() {
        if let id = engine.currentId,
           store.visibleTracks.contains(where: { $0.id == id }) {
            engine.play(id: id)
            return
        }
        if let folderID = store.currentFolderID,
           let lastID = store.lastTrackID(for: folderID),
           store.visibleTracks.contains(where: { $0.id == lastID }) {
            engine.play(id: lastID)
            return
        }
        if let first = store.visibleTracks.first {
            engine.play(id: first.id)
        }
    }

    func pause() {
        engine.pause()
    }
}

// MARK: - Siri / 快捷指令

struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "继续播放"
    static let description = IntentDescription("从上次的位置继续播放随听里的音频")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PlaybackController.shared.resume()
        return .result(dialog: "好的，继续播放")
    }
}

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停播放"
    static let description = IntentDescription("暂停随听当前的播放")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PlaybackController.shared.pause()
        return .result(dialog: "好的，已暂停")
    }
}

/// 语音短语。Apple 要求短语里带 App 名字，用 \(.applicationName) 自动代入显示名「随听」。
struct SuitingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "用\(.applicationName)继续播放",
                "\(.applicationName)继续播放"
            ],
            shortTitle: "继续播放",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "用\(.applicationName)暂停播放",
                "\(.applicationName)暂停"
            ],
            shortTitle: "暂停播放",
            systemImageName: "pause.fill"
        )
    }
}
