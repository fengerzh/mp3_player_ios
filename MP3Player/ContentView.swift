import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    init(hex: String) {
        let text = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

private enum Palette {
    static let page = Color(hex: "F5F6FA")
    static let primary = Color(hex: "2A6DF7")
    static let ink = Color(hex: "1A1A2E")
    static let muted = Color(hex: "8888A0")
    static let headerStart = Color(hex: "D5D6F9")
    static let headerEnd = Color(hex: "E8E6F3")
    static let cover = Color(hex: "E4EBFF")
    static let tagBackground = Color(hex: "EEE9FF")
    static let tagText = Color(hex: "6B5BD2")
    static let chipIdle = Color(hex: "D8DDEB")
    static let rowActive = Color(hex: "EEF3FF")
    static let rowBorder = Color(hex: "EEF0F5")
    static let control = Color(hex: "F1F3F8")
}

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

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.page.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        importButton
                        playerCard
                        playlistCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationBarHidden(true)
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .frame(width: 38, height: 38)
                .background(Color(hex: "EAE0FF"))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text("MP3播放器")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("本地音乐播放")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            if !store.tracks.isEmpty {
                Text("\(store.tracks.count) 首")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "E8F0FE"))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Palette.headerStart, Palette.headerEnd],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var importButton: some View {
        Button { showingImporter = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                Text("导入 MP3")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Palette.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在播放")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.tagText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.tagBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(engine.currentTrack?.name ?? "未选择曲目")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)

                    Text("\(formatTime(engine.currentTime)) / \(formatTime(engine.duration))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 62, height: 62)
                    .background(Palette.cover)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
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
            .tint(Palette.primary)
            .padding(.top, 14)

            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Button { engine.skip(-15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.primary)
                }
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.primary)
                        .frame(width: 42, height: 42)
                        .background(Palette.control)
                        .clipShape(Circle())
                }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Palette.primary)
                        .clipShape(Circle())
                }
                Button { engine.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.primary)
                        .frame(width: 42, height: 42)
                        .background(Palette.control)
                        .clipShape(Circle())
                }
                Button { engine.skip(15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.primary)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            speedChips
                .padding(.top, 14)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var speedChips: some View {
        HStack(spacing: 6) {
            Text("倍速")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibraryStore.supportedSpeeds, id: \.self) { speed in
                        Button { engine.setSpeed(speed) } label: {
                            Text("\(String(format: "%g", speed))×")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .foregroundStyle(store.speed == speed ? .white : Palette.ink)
                                .background(store.speed == speed ? Palette.primary : Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(
                                            store.speed == speed ? Palette.primary : Palette.chipIdle,
                                            lineWidth: 0.8
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var playlistCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("播放列表", systemImage: "list.bullet")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(store.tracks.count) 首歌曲")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.primary)
            }

            if store.tracks.isEmpty {
                emptyView
            } else {
                ForEach(store.tracks) { track in
                    trackRow(track)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(Palette.muted)
            Text("还没有歌曲")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text("点上方「导入 MP3」从文件 App 选择歌曲")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private func trackRow(_ track: Track) -> some View {
        let active = engine.currentId == track.id
        Button {
            engine.play(id: track.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 30, height: 30)
                    .background(active ? Palette.cover : Palette.control)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(track.name)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Palette.primary : Palette.ink)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(formatTime(track.position))
                    .font(.system(size: 11))
                    .foregroundStyle(active ? Palette.primary : Palette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(active ? Palette.rowActive : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                HStack(spacing: 0) {
                    if active {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.primary)
                            .frame(width: 3)
                    }
                    Spacer()
                },
                alignment: .leading
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Color.clear : Palette.rowBorder, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                engine.stopForRemoval(id: track.id)
                store.remove(ids: [track.id])
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
