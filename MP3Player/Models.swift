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
        let stored = defaults.object(forKey: speedKey) as? Float ?? 1.0
        speed = Self.supportedSpeeds.contains(stored) ? stored : 1.0
        loadLibrary()
    }

    // MARK: - 持久化与迁移

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: metaURL) else { return }
        let decoder = JSONDecoder()
        if var library = try? decoder.decode(Library.self, from: data) {
            // 过滤掉文件或文件夹已不存在的脏数据
            var validFolders = library.folders
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
    /// 同名文件夹再次导入时视为刷新：先清掉旧副本，避免重复堆积。
    func importFolder(_ url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.hasDirectoryPath else { return 0 }

        let name = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var sources: [URL] = []
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                sources.append(fileURL)
            }
        }
        sources.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let folderID: String
        if let existing = folders.first(where: { $0.name == name }) {
            folderID = existing.id
            remove(ids: Set(tracks.filter { $0.folderID == folderID }.map { $0.id }))
        } else {
            folderID = "folder_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            folders.append(Folder(id: folderID, name: name))
        }

        var addedIDs: [String] = []
        for source in sources {
            let fileScoped = source.startAccessingSecurityScopedResource()
            defer { if fileScoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            let base = source.deletingPathExtension().lastPathComponent
            let id = uniqueFileName(base: base, ext: ext)
            do {
                try fm.copyItem(at: source, to: tracksDir.appendingPathComponent(id))
                tracks.append(Track(id: id, name: base, folderID: folderID, position: 0, duration: 0))
                addedIDs.append(id)
            } catch {
                print("导入失败 \(source.lastPathComponent): \(error)")
            }
        }

        if !addedIDs.isEmpty {
            currentFolderID = folderID
            lastTrackIDByFolder[folderID] = addedIDs.first
        }
        persist()
        return addedIDs.count
    }

    /// 兼容原有能力：单曲导入归入固定的「单曲」文件夹。
    func importFiles(_ urls: [URL]) -> Int {
        let folderID = "single_tracks"
        if !folders.contains(where: { $0.id == folderID }) {
            folders.append(Folder(id: folderID, name: "单曲"))
        }
        var addedIDs: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard source.isFileURL, !source.hasDirectoryPath else { continue }
            let ext = source.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            let base = source.deletingPathExtension().lastPathComponent
            let id = uniqueFileName(base: base, ext: ext)
            do {
                try FileManager.default.copyItem(at: source, to: tracksDir.appendingPathComponent(id))
                tracks.append(Track(id: id, name: base, folderID: folderID, position: 0, duration: 0))
                addedIDs.append(id)
            } catch {
                print("导入失败 \(source.lastPathComponent): \(error)")
            }
        }
        if !addedIDs.isEmpty {
            currentFolderID = folderID
            lastTrackIDByFolder[folderID] = addedIDs.first
        }
        persist()
        return addedIDs.count
    }

    private func uniqueFileName(base: String, ext: String) -> String {
        var name = "\(base).\(ext)"
        var index = 2
        while FileManager.default.fileExists(atPath: tracksDir.appendingPathComponent(name).path) {
            name = "\(base) \(index).\(ext)"
            index += 1
        }
        return name
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

    func setSpeed(_ value: Float) {
        guard Self.supportedSpeeds.contains(value) else { return }
        speed = value
    }
}
