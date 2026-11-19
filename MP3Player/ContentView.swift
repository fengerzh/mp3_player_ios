import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store: LibraryStore
    @StateObject private var engine: AudioEngine
    @State private var showingImporter = false
    @State private var importedMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        _store = StateObject(wrappedValue: library)
        _engine = StateObject(wrappedValue: AudioEngine(store: library))
    }

    private var currentName: String {
        engine.currentTrack?.name ?? "未选择曲目"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbar
                if store.tracks.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(store.tracks) { track in
                            trackRow(track)
                        }
                        .onDelete { indexSet in
                            let ids = indexSet.map { store.tracks[$0].id }
                            for id in ids { engine.stopForRemoval(id: id) }
                            store.remove(ids: Set(ids))
                        }
                    }
                    .listStyle(.plain)
                }
                playerPanel
            }
            .navigationTitle("MP3 播放器")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.audio, .mp3],
                allowsMultipleSelection: true
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        let count = store.importFiles(urls)
                        importedMessage = count > 0 ? "已导入 \(count) 首" : "没有可导入的音频文件"
                    case .failure(let error):
                        importedMessage = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
            .onDrop(of: [.fileURL, .audio], isTargeted: nil) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    Task { @MainActor in
                        let count = store.importFiles(urls)
                        importedMessage = count > 0 ? "已导入 \(count) 首" : "没有可导入的音频文件"
                    }
                }
                return true
            }
            .onOpenURL { url in
                Task { @MainActor in
                    let count = store.importFiles([url])
                    importedMessage = count > 0 ? "已导入 \(count) 首" : "没有可导入的音频文件"
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || phase == .inactive {
                    engine.persistProgress()
                }
            }
            .alert(
                "导入结果",
                isPresented: Binding(
                    get: { importedMessage != nil },
                    set: { if !$0 { importedMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { importedMessage = nil }
            } message: {
                Text(importedMessage ?? "")
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("本地音乐").font(.headline)
            Spacer()
            Button { showingImporter = true } label: {
                Label("导入 MP3", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("还没有歌曲").font(.title3)
            Text("点「导入 MP3」从文件 App 选择歌曲，\n也可以把电脑里的 MP3 拖进来。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func trackRow(_ track: Track) -> some View {
        let active = engine.currentId == track.id
        Button {
            engine.play(id: track.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: active && engine.isPlaying ? "pause.circle.fill" : "music.note")
                    .font(.title3)
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .lineLimit(1)
                        .foregroundStyle(active ? Color.accentColor : .primary)
                    Text(active ? "播放中 · \(formatTime(engine.currentTime))" : "上次听到 \(formatTime(track.position))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playerPanel: some View {
        VStack(spacing: 10) {
            Text(currentName).font(.headline).lineLimit(1)
            HStack(spacing: 20) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Button { engine.next() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                Button { engine.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                Button { engine.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
            }
            Slider(
                value: Binding(
                    get: { engine.currentTime },
                    set: { engine.seek(to: $0) }
                ),
                in: 0...max(engine.duration, 1)
            ) { editing in
                if !editing { engine.persistProgress() }
            }
            .tint(Color.accentColor)
            HStack {
                Text(formatTime(engine.currentTime))
                Spacer()
                Text(formatTime(engine.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("倍速").font(.caption).foregroundStyle(.secondary)
                ForEach(LibraryStore.supportedSpeeds, id: \.self) { speed in
                    Button { engine.setSpeed(speed) } label: {
                        Text("\(String(format: "%g", speed))×")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                store.speed == speed ? Color.accentColor : Color.secondary.opacity(0.12)
                            )
                            .foregroundStyle(store.speed == speed ? Color.white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
