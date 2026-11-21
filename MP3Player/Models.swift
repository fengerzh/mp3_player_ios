import Foundation

struct Folder: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let folderID: String
    var position: Double
    var duration: Double
}

private struct Library: Codable {
    var folders: [Folder] = []
    var tracks: [Track] = []
    var currentFolderID: String? = nil
    var lastTrackIDByFolder: [String: String] = [:]
}

private struct LegacyTrack: Codable {
    let id: String
    let name: String
    var position: Double
    var duration: Double
}

struct ImportStatus: Sendable {
    let folderName: String
    let done: Int
    let total: Int
}

private struct CopiedTrack: Sendable {
    let id: String
    let name: String
}

/// 增量同步结果：reused=true 表示复用沙盒里已有的文件（播放进度保留）。
private struct SyncedTrack: Sendable {
    let id: String
    let name: String
    let reused: Bool
}

/// 后台扫描文件夹里的音频文件（不阻塞界面）。
private func scanAudioFiles(in folderURL: URL, extensions: [String]) async -> [URL] {
    await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        var sources: [URL] = []
        if let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                guard extensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                sources.append(fileURL)
            }
        }
        sources.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return sources
    }.value
}

/// 后台逐个复制音频到沙盒，每完成一首回报一次进度（不阻塞界面）。
private func copyAudioFiles(
    _ sources: [URL],
    to tracksDir: URL,
    progress: @escaping @Sendable (Int, Int) -> Void
) async -> [CopiedTrack] {
    await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        let total = sources.count
        progress(0, total)
        var added: [CopiedTrack] = []
        var usedNames = Set<String>()
        for (index, source) in sources.enumerated() {
            let fileScoped = source.startAccessingSecurityScopedResource()
            defer { if fileScoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            let base = source.deletingPathExtension().lastPathComponent
            var fileName = "\(base).\(ext)"
            var n = 2
            while usedNames.contains(fileName) || fm.fileExists(atPath: tracksDir.appendingPathComponent(fileName).path) {
                fileName = "\(base) \(n).\(ext)"
                n += 1
            }
            usedNames.insert(fileName)
            do {
                try fm.copyItem(at: source, to: tracksDir.appendingPathComponent(fileName))
                added.append(CopiedTrack(id: fileName, name: base))
            } catch {
                print("导入失败 \(source.lastPathComponent): \(error)")
            }
            progress(index + 1, total)
        }
        return added
    }.value
}

/// 后台增量同步：沙盒里已有的同名文件直接复用，只复制新增的；每首回报进度。
/// existingByBase 的 key 是去掉扩展名的文件名，value 是它在 Tracks 目录里的实际文件名。
private func syncAudioFiles(
    _ sources: [URL],
    to tracksDir: URL,
    existingByBase: [String: String],
    progress: @escaping @Sendable (Int, Int) -> Void
) async -> [SyncedTrack] {
    await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        let total = sources.count
        progress(0, total)
        var result: [SyncedTrack] = []
        var usedNames = Set(existingByBase.values)
        for (index, source) in sources.enumerated() {
            let ext = source.pathExtension.lowercased()
            let base = source.deletingPathExtension().lastPathComponent
            if let reusedID = existingByBase[base] {
                result.append(SyncedTrack(id: reusedID, name: base, reused: true))
                progress(index + 1, total)
                continue
            }
            let fileScoped = source.startAccessingSecurityScopedResource()
            defer { if fileScoped { source.stopAccessingSecurityScopedResource() } }
            var fileName = "\(base).\(ext)"
            var n = 2
            while usedNames.contains(fileName) || fm.fileExists(atPath: tracksDir.appendingPathComponent(fileName).path) {
                fileName = "\(base) \(n).\(ext)"
                n += 1
            }
            usedNames.insert(fileName)
            do {
                try fm.copyItem(at: source, to: tracksDir.appendingPathComponent(fileName))
                result.append(SyncedTrack(id: fileName, name: base, reused: false))
            } catch {
                print("导入失败 \(source.lastPathComponent): \(error)")
            }
            progress(index + 1, total)
        }
        return result
    }.value
}

@MainActor
final class LibraryStore: ObservableObject {
    static let supportedSpeeds: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]

    @Published private(set) var folders: [Folder] = []
    @Published private(set) var tracks: [Track] = []
    @Published var currentFolderID: String? {
        didSet {
            if currentFolderID != oldValue { persist() }
        }
    }
    @Published var speed: Float {
        didSet { persist() }
    }
    @Published private(set) var importStatus: ImportStatus?

    /// 导入代号：用于丢弃过期的进度回调，避免遮罩在导入结束后被旧 Task 重新点亮。
    private var importGeneration: UInt64 = 0

    private var lastTrackIDByFolder: [String: String] = [:]
    private let tracksDir: URL
    private let metaURL: URL
    private let defaults = UserDefaults.standard
    private let speedKey = "com.buzz.mp3player.speed"
    private let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]

    var currentFolder: Folder? {
        guard let id = currentFolderID else { return nil }
        return folders.first { $0.id == id }
    }

    var currentFolderName: String {
        currentFolder?.name ?? "请选择文件夹"
    }

    var visibleTracks: [Track] {
        guard let id = currentFolderID else { return [] }
        return tracks
            .filter { $0.folderID == id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fileURL(for id: String) -> URL {
        tracksDir.appendingPathComponent(id)
    }

    func lastTrackID(for folderID: String) -> String? {
        lastTrackIDByFolder[folderID]
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        tracksDir = documents.appendingPathComponent("Tracks", isDirectory: true)
        metaURL = documents.appendingPathComponent("library.json")
        if !FileManager.default.fileExists(atPath: tracksDir.path) {
            try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        }
        // 这些歌都能从「文件」App 的源文件重新导入，不进 iCloud 备份，避免同时占手机和云空间。
        var backupDir = tracksDir
        var dirValues = URLResourceValues()
        dirValues.isExcludedFromBackup = true
        try? backupDir.setResourceValues(dirValues)
        let stored = defaults.object(forKey: speedKey) as? Float ?? 1.0
        speed = Self.supportedSpeeds.contains(stored) ? stored : 1.0
        loadLibrary()
        cleanupOrphanFiles()
    }

    /// 清理 Tracks 目录里没有曲库记录的孤儿文件（例如导入中途失败留下的半截副本）。
    private func cleanupOrphanFiles() {
        let fm = FileManager.default
        let known = Set(tracks.map { $0.id })
        guard let files = try? fm.contentsOfDirectory(at: tracksDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !known.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
            print("清理孤儿文件: \(file.lastPathComponent)")
        }
    }

    // MARK: - 持久化与迁移

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: metaURL) else { return }
        let decoder = JSONDecoder()
        if var library = try? decoder.decode(Library.self, from: data) {
            // 过滤掉文件或文件夹已不存在的脏数据
            let validFolders = library.folders
            if let saved = library.currentFolderID, !validFolders.contains(where: { $0.id == saved }) {
                library.currentFolderID = validFolders.first?.id
            }
            library.tracks.removeAll { track in
                !validFolders.contains(where: { $0.id == track.folderID })
                    || !FileManager.default.fileExists(atPath: tracksDir.appendingPathComponent(track.id).path)
            }
            folders = validFolders
            tracks = library.tracks
            currentFolderID = library.currentFolderID ?? validFolders.first?.id
            lastTrackIDByFolder = library.lastTrackIDByFolder
            backfillLastTrack()
            persist()
            return
        }
        // 迁移旧版：扁平的 [Track]，没有文件夹概念
        if let legacy = try? decoder.decode([LegacyTrack].self, from: data) {
            let folder = Folder(id: "local_songs", name: "本地歌曲")
            folders = [folder]
            tracks = legacy.compactMap { item in
                guard FileManager.default.fileExists(atPath: tracksDir.appendingPathComponent(item.id).path) else { return nil }
                return Track(id: item.id, name: item.name, folderID: folder.id, position: item.position, duration: item.duration)
            }
            currentFolderID = folder.id
            lastTrackIDByFolder = [:]
            backfillLastTrack()
            persist()
        }
    }

    /// 兜底：某个文件夹若无「上次曲目」记录，自动选一首有播放进度的曲目补上。
    /// 解决旧数据迁移后 lastTrackIDByFolder 为空、启动无法恢复播放区的问题。
    /// 只补 position > 0 的曲目，避免未听过的歌被误当成"上次在听"。
    private func backfillLastTrack() {
        for folder in folders {
            if let saved = lastTrackIDByFolder[folder.id],
               tracks.contains(where: { $0.id == saved && $0.folderID == folder.id }) {
                continue
            }
            let candidate = tracks
                .filter { $0.folderID == folder.id && $0.position > 0 }
                .max { $0.position < $1.position }
            if let candidate = candidate {
                lastTrackIDByFolder[folder.id] = candidate.id
            }
        }
    }

    private func persist() {
        let library = Library(
            folders: folders,
            tracks: tracks,
            currentFolderID: currentFolderID,
            lastTrackIDByFolder: lastTrackIDByFolder
        )
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: metaURL, options: .atomic)
        }
        defaults.set(speed, forKey: speedKey)
    }

    // MARK: - 导入

    /// 从文件 App 选中的文件夹批量导入其中所有音频（含子文件夹）。
    /// 同名文件夹再次导入时做增量同步：保留已有曲目的播放进度，只复制新增文件，清掉源里已删除的旧曲目。
    /// 扫描与文件复制在后台线程执行，主线程只更新界面状态，避免卡顿。
    func importFolder(_ url: URL) async -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.hasDirectoryPath else { return 0 }

        let name = url.deletingPathExtension().lastPathComponent
        importGeneration += 1
        let generation = importGeneration
        importStatus = ImportStatus(folderName: name, done: 0, total: 0)

        // 后台扫描
        let sources = await scanAudioFiles(in: url, extensions: audioExtensions)
        guard generation == importGeneration else { return 0 }
        guard !sources.isEmpty else {
            importStatus = nil
            return 0
        }

        let folderID: String
        let existingTracks: [Track]
        if let existing = folders.first(where: { $0.name == name }) {
            folderID = existing.id
            existingTracks = tracks.filter { $0.folderID == folderID }
        } else {
            folderID = "folder_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            existingTracks = []
        }

        // 已有曲目按「去掉扩展名的文件名」建索引，用于复用沙盒文件、保住进度
        var existingByBase: [String: String] = [:]
        for track in existingTracks { existingByBase[track.name] = track.id }

        // 后台增量同步并回报进度（丢弃过期代号）
        let dir = tracksDir
        let synced = await syncAudioFiles(sources, to: dir, existingByBase: existingByBase) { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.importGeneration == generation else { return }
                self.importStatus = ImportStatus(folderName: name, done: done, total: total)
            }
        }
        guard generation == importGeneration else { return 0 }

        // 回到主线程一次性更新数据：清掉源里已不存在的旧曲目，新增曲目入账，已有曲目原样保留进度。
        if !folders.contains(where: { $0.id == folderID }) {
            folders.append(Folder(id: folderID, name: name))
        }
        let keptIDs = Set(synced.map { $0.id })
        let staleIDs = Set(existingTracks.map { $0.id }).subtracting(keptIDs)
        if !staleIDs.isEmpty { remove(ids: staleIDs) }
        for item in synced where !item.reused {
            tracks.append(Track(id: item.id, name: item.name, folderID: folderID, position: 0, duration: 0))
        }
        if !synced.isEmpty {
            currentFolderID = folderID
            if let lastID = lastTrackIDByFolder[folderID], keptIDs.contains(lastID) {
                // 上次在听的曲目还在，保留它的位置和进度
            } else {
                lastTrackIDByFolder[folderID] = synced.first?.id
            }
            persist()
        }
        importStatus = nil
        return synced.filter { !$0.reused }.count
    }

    /// 兼容原有能力：单曲导入归入固定的「单曲」文件夹。复制同样走后台。
    func importFiles(_ urls: [URL]) async -> Int {
        // 单曲按文件名去重：同一首歌重复导入不再生成「歌名 2.mp3」这样的第二份副本
        let singleFolderID = "single_tracks"
        let existingNames = Set(tracks.filter { $0.folderID == singleFolderID }.map { $0.id })
        let valid = urls.filter { url in
            guard url.isFileURL, !url.hasDirectoryPath,
                  audioExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return !existingNames.contains(url.lastPathComponent)
        }
        guard !valid.isEmpty else { return 0 }
        importGeneration += 1
        let generation = importGeneration
        importStatus = ImportStatus(folderName: "单曲", done: 0, total: valid.count)

        let dir = tracksDir
        let copied = await copyAudioFiles(valid, to: dir) { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.importGeneration == generation else { return }
                self.importStatus = ImportStatus(folderName: "单曲", done: done, total: total)
            }
        }

        importStatus = nil
        guard !copied.isEmpty else { return 0 }
        let folderID = singleFolderID
        if !folders.contains(where: { $0.id == folderID }) {
            folders.append(Folder(id: folderID, name: "单曲"))
        }
        for item in copied {
            tracks.append(Track(id: item.id, name: item.name, folderID: folderID, position: 0, duration: 0))
        }
        currentFolderID = folderID
        lastTrackIDByFolder[folderID] = copied.first?.id
        persist()
        return copied.count
    }

    // MARK: - 文件夹与进度

    func selectFolder(_ id: String) {
        guard folders.contains(where: { $0.id == id }) else { return }
        currentFolderID = id
        persist()
    }

    func rememberTrack(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        guard lastTrackIDByFolder[track.folderID] != id else { return }
        lastTrackIDByFolder[track.folderID] = id
        persist()
    }

    func saveProgress(id: String, position: Double, duration: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard tracks[index].position != position || tracks[index].duration != duration else { return }
        tracks[index].position = position
        tracks[index].duration = duration
        persist()
    }

    func remove(ids: Set<String>) {
        for id in ids {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
        let removed = tracks.filter { ids.contains($0.id) }
        tracks.removeAll { ids.contains($0.id) }
        for track in removed where lastTrackIDByFolder[track.folderID] == track.id {
            lastTrackIDByFolder.removeValue(forKey: track.folderID)
        }
        persist()
    }

    /// 删除整个文件夹：清掉该文件夹的全部曲目文件、进度记录和文件夹本身。
    func removeFolder(_ id: String) {
        guard folders.contains(where: { $0.id == id }) else { return }
        remove(ids: Set(tracks.filter { $0.folderID == id }.map { $0.id }))
        folders.removeAll { $0.id == id }
        lastTrackIDByFolder.removeValue(forKey: id)
        if currentFolderID == id {
            currentFolderID = folders.first?.id
        }
        persist()
    }

    func setSpeed(_ value: Float) {
        guard Self.supportedSpeeds.contains(value) else { return }
        speed = value
    }
}
