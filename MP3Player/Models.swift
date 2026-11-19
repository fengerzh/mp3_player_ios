import Foundation

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var position: Double
    var duration: Double
}

@MainActor
final class LibraryStore: ObservableObject {
    static let supportedSpeeds: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]

    @Published private(set) var tracks: [Track] = []
    @Published var speed: Float {
        didSet { persist() }
    }

    private let tracksDir: URL
    private let metaURL: URL
    private let defaults = UserDefaults.standard
    private let speedKey = "com.buzz.mp3player.speed"
    private let audioExtensions = ["mp3", "m4a", "wav", "aac", "aiff"]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        tracksDir = documents.appendingPathComponent("Tracks", isDirectory: true)
        metaURL = documents.appendingPathComponent("library.json")
        if !FileManager.default.fileExists(atPath: tracksDir.path) {
            try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        }
        let stored = defaults.object(forKey: speedKey) as? Float ?? 1.0
        speed = Self.supportedSpeeds.contains(stored) ? stored : 1.0
        loadTracks()
    }

    func fileURL(for id: String) -> URL {
        tracksDir.appendingPathComponent(id)
    }

    private func loadTracks() {
        var saved: [String: Track] = [:]
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            for item in decoded { saved[item.id] = item }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: tracksDir, includingPropertiesForKeys: nil)) ?? []
        var result: [Track] = []
        for url in files {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let id = url.lastPathComponent
            let track = saved[id] ?? Track(
                id: id,
                name: url.deletingPathExtension().lastPathComponent,
                position: 0,
                duration: 0
            )
            result.append(track)
        }
        tracks = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    func importFiles(_ urls: [URL]) -> Int {
        var imported = 0
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard source.isFileURL else { continue }
            let ext = source.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            let base = source.deletingPathExtension().lastPathComponent
            var target = tracksDir.appendingPathComponent("\(base).\(ext)")
            var index = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = tracksDir.appendingPathComponent("\(base) \(index).\(ext)")
                index += 1
            }
            do {
                try FileManager.default.copyItem(at: source, to: target)
                imported += 1
            } catch {
                print("导入失败 \(source.lastPathComponent): \(error)")
            }
        }
        if imported > 0 { loadTracks() }
        return imported
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
        tracks.removeAll { ids.contains($0.id) }
        persist()
    }

    func setSpeed(_ value: Float) {
        guard Self.supportedSpeeds.contains(value) else { return }
        speed = value
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: metaURL, options: .atomic)
        }
        defaults.set(speed, forKey: speedKey)
    }
}
