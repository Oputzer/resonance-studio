import AppKit
import SwiftUI

/// Text prompt shown as an alert (new folder, new set, rename…).
struct NamePrompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String? = nil
    var initial: String = ""
    var confirm: String = "Create"
    var action: (String) -> Void
}

extension View {
    func namePrompt(_ prompt: Binding<NamePrompt?>) -> some View {
        modifier(NamePromptModifier(prompt: prompt))
    }
}

private struct NamePromptModifier: ViewModifier {
    @Binding var prompt: NamePrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField("Name", text: $text)
                Button(prompt?.confirm ?? "OK") {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { prompt?.action(value) }
                    prompt = nil
                }
                Button("Cancel", role: .cancel) { prompt = nil }
            } message: {
                if let m = prompt?.message { Text(m) }
            }
            .onChange(of: prompt?.id) { _, _ in text = prompt?.initial ?? "" }
    }
}

/// Camelot key shown as a colored pill, the way DJ software does.
struct KeyBadge: View {
    let camelot: String?
    var name: String?
    var dimmed = false

    var body: some View {
        if let c = Analyzer.parseCamelot(camelot), let camelot {
            Text(camelot)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 34)
                .background(Capsule().fill(Self.color(c.number, minor: c.minor)))
                .opacity(dimmed ? 0.28 : 1)
                .help(name ?? camelot)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// Each step around the Camelot wheel gets its own hue; minor keys are a little deeper.
    static func color(_ number: Int, minor: Bool) -> Color {
        // Spread the 12 wheel positions across the full color circle so neighbours look different.
        let hue = (Double((number * 5) % 12) / 12 + 0.02).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: minor ? 0.70 : 0.55, brightness: minor ? 0.72 : 0.84)
    }
}

enum ColumnStore {
    static let key = "trackTableColumns"
    static func load() -> TableColumnCustomization<TrackMeta> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(TableColumnCustomization<TrackMeta>.self, from: data) else { return .init() }
        return value
    }
    static func save(_ value: TableColumnCustomization<TrackMeta>) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct PlaylistView: View {
    let playlistID: String
    let folderName: String?

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var selection = Set<TrackMeta.ID>()
    @State private var sortOrder = [KeyPathComparator(\TrackMeta.index)]
    @State private var search = ""
    @State private var showInspector = true
    @State private var columns = ColumnStore.load()
    @State private var prompt: NamePrompt?
    @State private var confirmArrange = false
    @State private var trashIDs: [String]?

    var body: some View {
        Group {
            if let playlist = library.playlist(id: playlistID) {
                content(playlist)
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list",
                                       description: Text("It may have been moved or deleted in Finder."))
            }
        }
        .namePrompt($prompt)
    }

    // MARK: Data

    private var isManualOrder: Bool {
        guard let first = sortOrder.first else { return true }
        return first.keyPath == \TrackMeta.index as PartialKeyPath<TrackMeta> && first.order == .forward
    }

    private func visible(_ p: LibraryPlaylist) -> [TrackMeta] {
        var list = p.tracks(inFolder: folderName)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { t in
                [t.title, t.displayArtist, t.displayGenre ?? "", t.displayAlbum ?? "", t.camelot ?? "",
                 t.analysis?.keyName ?? "", t.bpm.map { Fmt.bpm($0) } ?? "", t.folder ?? ""]
                    .contains { $0.lowercased().contains(q) }
            }
        }
        return isManualOrder ? list : list.sorted(using: sortOrder)
    }

    /// The number shown in the # column. Inside a folder it matches the file's number;
    /// for the whole playlist it counts straight through.
    private func positions(_ p: LibraryPlaylist) -> [String: Int] {
        var result: [String: Int] = [:]
        if folderName == nil {
            for (n, t) in p.manifest.orderedTracks.enumerated() { result[t.id] = n + 1 }
            return result
        }
        for (_, group) in Dictionary(grouping: p.manifest.orderedTracks, by: { $0.folder ?? "" }) {
            for (n, t) in group.enumerated() { result[t.id] = n + 1 }
        }
        return result
    }

    private var sortName: String {
        guard let kp = sortOrder.first?.keyPath else { return "" }
        let names: [PartialKeyPath<TrackMeta>: String] = [
            \TrackMeta.sortTitle: "title", \TrackMeta.sortArtist: "artist", \TrackMeta.sortBPM: "BPM",
            \TrackMeta.sortKey: "key", \TrackMeta.sortDuration: "time", \TrackMeta.sortGenre: "genre",
            \TrackMeta.sortAlbum: "album", \TrackMeta.sortDate: "release date", \TrackMeta.sortFolder: "folder",
        ]
        return names[kp] ?? "column"
    }

    // MARK: Layout

    private func content(_ p: LibraryPlaylist) -> some View {
        let tracks = visible(p)
        let numbers = positions(p)
        let selectedTrack = selection.count == 1 ? p.manifest.tracks.first { selection.contains($0.id) } : nil
        let compareKey = selectedTrack?.camelot

        return VStack(spacing: 0) {
            header(p)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)

            if !isManualOrder {
                sortBanner(p, tracks: tracks)
            }

            Table(of: TrackMeta.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("#", value: \.index) { t in
                    if player.isCurrent(p.fileURL(for: t)) {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(Brand.accent)
                    } else {
                        Text("\(numbers[t.id] ?? t.index)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(34)
                .customizationID("index")

                TableColumn("Title", value: \.sortTitle) { t in
                    HStack(spacing: 10) {
                        ArtworkView(url: p.artworkURL(for: t), size: 28, corner: 4)
                        Text(t.title).lineLimit(1)
                        if t.catalog?.explicit == true {
                            Image(systemName: "e.square.fill").foregroundStyle(.secondary).font(.caption)
                        }
                        if folderName == nil, let f = t.folder {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("In folder “\(f)”")
                        }
                    }
                }
                .width(min: 180, ideal: 300)
                .customizationID("title")

                TableColumn("Artist", value: \.sortArtist) { t in Text(t.displayArtist).lineLimit(1) }
                    .width(min: 90, ideal: 150)
                    .customizationID("artist")

                TableColumn("BPM", value: \.sortBPM) { t in bpmCell(p, t) }
                    .width(min: 46, ideal: 54, max: 70)
                    .customizationID("bpm")

                TableColumn("Key", value: \.sortKey) { t in
                    KeyBadge(camelot: t.camelot, name: t.analysis?.keyName,
                             dimmed: compareKey != nil && !selection.contains(t.id) && !Analyzer.isCompatible(compareKey, t.camelot))
                }
                .width(min: 46, ideal: 52, max: 70)
                .customizationID("key")

                TableColumn("Time", value: \.sortDuration) { t in
                    Text(Fmt.duration(t.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 52, max: 70)
                .customizationID("time")

                TableColumn("Genre", value: \.sortGenre) { t in Text(t.displayGenre ?? "—").lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
                    .customizationID("genre")

                TableColumn("Album", value: \.sortAlbum) { t in Text(t.displayAlbum ?? "—").lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 120)
                    .customizationID("album")
                    .defaultVisibility(.hidden)

                TableColumn("Released", value: \.sortDate) { t in
                    Text(t.displayDate?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 96)
                .customizationID("date")

                TableColumn("Folder", value: \.sortFolder) { t in Text(t.folder ?? "—").lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
                    .customizationID("folder")
                    .defaultVisibility(.hidden)
            } rows: {
                ForEach(tracks) { t in
                    TableRow(t).draggable(p.fileURL(for: t))
                }
                .dropDestination(for: URL.self) { index, urls in
                    handleTableDrop(p, urls: urls, at: index, visible: tracks)
                }
            }
            .contextMenu(forSelectionType: TrackMeta.ID.self) { ids in
                rowMenu(p, ids: ids, tracks: tracks)
            } primaryAction: { ids in
                if let id = ids.first, let t = tracks.first(where: { $0.id == id }) { play(p, tracks, from: t) }
            }

            footer(p, tracks: tracks)
        }
        .navigationTitle(folderName ?? p.manifest.title)
        .navigationSubtitle(folderName == nil ? "" : p.manifest.title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search songs, keys, BPM")
        .inspector(isPresented: $showInspector) {
            Group {
                if let t = selectedTrack {
                    TrackInspector(track: t, playlist: p) { play(p, tracks, from: t) }
                } else {
                    PlaylistInspector(playlist: p, enriching: library.enriching.contains(p.id),
                                      selectedCount: selection.count)
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem { organizeMenu(p, tracks: tracks) }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Info", systemImage: "info.circle") }
                    .help("Show or hide song details")
            }
        }
        .onChange(of: columns) { _, new in ColumnStore.save(new) }
        .onChange(of: playlistID) { _, _ in selection = [] }
        .confirmationDialog("Arrange for mixing?", isPresented: $confirmArrange) {
            Button("Arrange") {
                let ids = library.mixOrder(p.tracks(inFolder: folderName))
                library.applyOrder(p.id, visible: ids)
                sortOrder = [KeyPathComparator(\TrackMeta.index)]
            }
        } message: {
            Text("Puts the songs in an order where each one mixes smoothly into the next: compatible keys, the closest tempo, and building energy. The file numbers are updated to match.")
        }
        .confirmationDialog(trashTitle(p), isPresented: Binding(get: { trashIDs != nil }, set: { if !$0 { trashIDs = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let ids = trashIDs { library.trashTracks(p.id, ids: ids); selection = [] }
                trashIDs = nil
            }
        } message: {
            Text(p.manifest.isSet ? "The files are moved to the Trash." : "The files are moved to the Trash, and checking SoundCloud for new songs won't download them again.")
        }
    }

    private func trashTitle(_ p: LibraryPlaylist) -> String {
        let n = trashIDs?.count ?? 0
        if n == 1, let id = trashIDs?.first, let t = p.manifest.tracks.first(where: { $0.id == id }) { return "Move “\(t.title)” to the Trash?" }
        return "Move \(n) songs to the Trash?"
    }

    @ViewBuilder
    private func bpmCell(_ p: LibraryPlaylist, _ t: TrackMeta) -> some View {
        if let bpm = t.bpm {
            Text(Fmt.bpm(bpm)).monospacedDigit()
        } else if library.isAnalyzing(p.id, t.id) {
            ProgressView().controlSize(.mini).help("Detecting BPM and key…")
        } else if library.isQueued(p.id, t.id) {
            Text("…").foregroundStyle(.tertiary).help("Waiting to be analyzed")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func header(_ p: LibraryPlaylist) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(url: p.coverURL, size: 156, corner: 12)
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                if folderName != nil {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Brand.accent)
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(folderName != nil ? "FOLDER" : p.manifest.isSet ? "SET" : p.manifest.isSingleTrack ? "SONG" : "PLAYLIST")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(folderName ?? p.manifest.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                if folderName != nil {
                    Text(p.manifest.title).font(.title3.weight(.medium)).foregroundStyle(Brand.accent)
                } else if let uploader = p.manifest.uploader {
                    Text(uploader).font(.title3.weight(.medium)).foregroundStyle(Brand.accent)
                }
                Text(summary(p)).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    actionButtons(p, compact: false)
                    actionButtons(p, compact: true)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButtons(_ p: LibraryPlaylist, compact: Bool) -> some View {
        let list = visible(p)
        let dir = folderName.map { p.folder.appendingPathComponent($0, isDirectory: true) } ?? p.folder
        return HStack(spacing: 10) {
            Button { play(p, list, from: nil) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .disabled(list.isEmpty)
            Group {
                Button { play(p, list.shuffled(), from: nil) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Shuffle")
                    .disabled(list.isEmpty)
                Button { NSWorkspace.shared.open(dir) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show in Finder")
                if !p.manifest.isSet, let link = URL(string: p.manifest.sourceURL) {
                    Button { NSWorkspace.shared.open(link) } label: { Label("SoundCloud", systemImage: "arrow.up.right.square") }
                        .help("Open the original on SoundCloud")
                }
            }
            .labelStyle(AdaptiveLabelStyle(compact: compact))
        }
        .controlSize(.large)
        .fixedSize()
    }

    private func sortBanner(_ p: LibraryPlaylist, tracks: [TrackMeta]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down").foregroundStyle(Brand.accent)
            Text("Sorted by \(sortName). Drag to reorder works in playlist order.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Make This the Playlist Order") {
                library.applyOrder(p.id, visible: tracks.map(\.id))
                sortOrder = [KeyPathComparator(\TrackMeta.index)]
            }
            .help("Saves this order and renumbers the files to match")
            Button("Back to Playlist Order") { sortOrder = [KeyPathComparator(\TrackMeta.index)] }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Brand.accent.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func footer(_ p: LibraryPlaylist, tracks: [TrackMeta]) -> some View {
        let pending = p.manifest.tracks.filter { library.isQueued(p.id, $0.id) }.count
        return HStack(spacing: 8) {
            Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(Fmt.longDuration(tracks.compactMap(\.duration).reduce(0, +)))")
            if pending > 0 {
                Text("·")
                ProgressView().controlSize(.mini)
                Text("Detecting BPM and key, \(pending) to go")
            }
            Spacer()
            if isManualOrder {
                Text("Drag songs to reorder, or onto a folder or set in the sidebar.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    private func summary(_ p: LibraryPlaylist) -> String {
        let list = p.tracks(inFolder: folderName)
        let songs = "\(list.count) \(list.count == 1 ? "song" : "songs")"
        let length = Fmt.longDuration(list.compactMap(\.duration).reduce(0, +))
        if p.manifest.isSet { return [songs, length, p.manifest.formatLabel].joined(separator: " · ") }
        let date = p.manifest.lastChanged.formatted(date: .abbreviated, time: .omitted)
        let verb = p.manifest.updatedAt.map { $0 > p.manifest.downloadedAt.addingTimeInterval(60) } == true ? "Updated" : "Downloaded"
        return [songs, length, p.manifest.format.title, "\(verb) \(date)"].joined(separator: " · ")
    }

    // MARK: Menus

    private func organizeMenu(_ p: LibraryPlaylist, tracks: [TrackMeta]) -> some View {
        Menu {
            Button("New Folder…", systemImage: "folder.badge.plus") { askNewFolder(p, moving: []) }
            Button("Arrange for Mixing…", systemImage: "wand.and.stars") { confirmArrange = true }
                .disabled(tracks.filter { $0.bpm != nil }.count < 2)
            Button("Re-detect BPM and Key", systemImage: "waveform") {
                library.reanalyze(p.id, p.tracks(inFolder: folderName).map(\.id))
            }
            if !p.manifest.isSet && !p.manifest.sourceURL.isEmpty {
                Divider()
                Button("Check SoundCloud for New Songs", systemImage: "arrow.triangle.2.circlepath") {
                    downloads.start(url: p.manifest.sourceURL, format: p.manifest.format)
                }
            }
        } label: {
            Label("Organize", systemImage: "square.grid.3x1.folder.badge.plus")
        }
        .help("Folders, arranging and updates")
    }

    @ViewBuilder
    private func rowMenu(_ p: LibraryPlaylist, ids: Set<TrackMeta.ID>, tracks: [TrackMeta]) -> some View {
        let chosen = p.manifest.orderedTracks.filter { ids.contains($0.id) }
        let idList = chosen.map(\.id)
        if let first = chosen.first {
            Button("Play") { play(p, tracks, from: first) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map { p.fileURL(for: $0) }) }
            Divider()
            Menu("Move to Folder") {
                Button(p.manifest.title) { library.moveTracks(p.id, ids: idList, toFolder: nil) }
                    .disabled(chosen.allSatisfy { $0.folder == nil })
                if !p.manifest.folderList.isEmpty { Divider() }
                ForEach(p.manifest.folderList, id: \.self) { f in
                    Button(f) { library.moveTracks(p.id, ids: idList, toFolder: f) }
                        .disabled(chosen.allSatisfy { $0.folder == f })
                }
                Divider()
                Button("New Folder…") { askNewFolder(p, moving: idList) }
            }
            Menu("Add to Set") {
                ForEach(library.sets.filter { $0.id != p.id }) { set in
                    Button(set.manifest.title) { library.copyTracks(from: p.id, ids: idList, to: set.id) }
                }
                if library.sets.contains(where: { $0.id != p.id }) { Divider() }
                Button("New Set…") {
                    prompt = NamePrompt(title: "New Set", message: "A set collects songs from any of your playlists.", initial: "New Set") { name in
                        if let id = library.createSet(named: name) { library.copyTracks(from: p.id, ids: idList, to: id) }
                    }
                }
            }
            Divider()
            Menu("BPM") {
                Button("Double (×2)") { library.setBPM(p.id, ids: idList) { $0 * 2 } }
                Button("Halve (÷2)") { library.setBPM(p.id, ids: idList) { $0 / 2 } }
                Divider()
                Button("Re-detect BPM and Key") { library.reanalyze(p.id, idList) }
            }
            Menu("Key") {
                ForEach(1...12, id: \.self) { n in
                    Button(keyLabel("\(n)A")) { library.setKey(p.id, ids: idList, camelot: "\(n)A") }
                }
                Divider()
                ForEach(1...12, id: \.self) { n in
                    Button(keyLabel("\(n)B")) { library.setKey(p.id, ids: idList, camelot: "\(n)B") }
                }
            }
            if chosen.count == 1, let link = first.sourceURL.flatMap(URL.init(string:)) {
                Divider()
                Button("Open on SoundCloud") { NSWorkspace.shared.open(link) }
            }
            Divider()
            Button(chosen.count == 1 ? "Move to Trash…" : "Move \(chosen.count) Songs to Trash…", role: .destructive) { trashIDs = idList }
        }
    }

    private func keyLabel(_ camelot: String) -> String {
        guard let c = Analyzer.parseCamelot(camelot) else { return camelot }
        let pc = Analyzer.camelotMajor.firstIndex(of: c.number) ?? 0
        let name = c.minor ? "\(Analyzer.minorPitchNames[(pc + 9) % 12]) minor" : "\(Analyzer.pitchNames[pc]) major"
        return "\(camelot)  ·  \(name)"
    }

    private func askNewFolder(_ p: LibraryPlaylist, moving ids: [String]) {
        prompt = NamePrompt(title: "New Folder", message: "Folders help you split a playlist into parts of a set, like Warm-up, Peak and Closing.", initial: "New Folder") { name in
            if let created = library.createFolder(p.id, named: name), !ids.isEmpty {
                library.moveTracks(p.id, ids: ids, toFolder: created)
            }
        }
    }

    // MARK: Actions

    private func handleTableDrop(_ p: LibraryPlaylist, urls: [URL], at index: Int, visible: [TrackMeta]) {
        let byPath = Dictionary(p.manifest.tracks.map { (p.fileURL(for: $0).standardizedFileURL.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        let own = urls.compactMap { byPath[$0.standardizedFileURL.path] }
        if !own.isEmpty {
            guard isManualOrder else { return }
            library.reorder(p.id, moving: own, to: index, within: visible.map(\.id))
            return
        }
        // Songs dragged in from another playlist: copy them here.
        for (sourceID, ids) in library.locate(urls) where sourceID != p.id {
            library.copyTracks(from: sourceID, ids: ids, to: p.id, folder: folderName)
        }
    }

    private func play(_ p: LibraryPlaylist, _ list: [TrackMeta], from track: TrackMeta?) {
        let items = list.map {
            QueueItem(file: p.fileURL(for: $0), title: $0.title, artist: $0.displayArtist, artwork: p.artworkURL(for: $0))
        }
        let start = track.flatMap { t in list.firstIndex { $0.id == t.id } } ?? 0
        player.play(items, startAt: start)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String?
    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkRow: View {
    let label: String
    let url: String?
    var body: some View {
        if let s = url, let u = URL(string: s) {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Link(destination: u) { Label("Open", systemImage: "arrow.up.right") }
                Spacer()
            }
            .font(.callout)
        }
    }
}

struct TrackInspector: View {
    let track: TrackMeta
    let playlist: LibraryPlaylist
    var play: () -> Void

    private var fileURL: URL { playlist.fileURL(for: track) }
    private var fileSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
    }
    private var fileBitrate: String? {
        guard let size = fileSize, let d = track.duration, d > 0 else { return nil }
        return "\(Int((Double(size) * 8 / d / 1000).rounded())) kbps"
    }
    private var sourceQuality: String? {
        let codec = track.sourceCodec.map { $0 == "mp4a.40.2" ? "AAC" : $0.uppercased() }
        let rate = track.sourceBitrate.map { "\(Int($0.rounded())) kbps" }
        let parts = [codec, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArtworkView(url: playlist.bestArtworkURL(for: track), corner: 10)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.title3.bold()).textSelection(.enabled)
                    Text(track.displayArtist).foregroundStyle(Brand.accent)
                }

                HStack {
                    Button(action: play) { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }

                InfoSection(title: "Mixing") {
                    HStack(spacing: 10) {
                        Text("BPM").foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Text(track.bpm.map(Fmt.bpm) ?? "Not detected yet").monospacedDigit()
                    }
                    .font(.callout)
                    HStack(spacing: 10) {
                        Text("Key").foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        KeyBadge(camelot: track.camelot, name: track.analysis?.keyName)
                        if let name = track.analysis?.keyName { Text(name) }
                    }
                    .font(.callout)
                    if let a = track.analysis, track.analysisEdited != true, a.keyConfidence < 0.15 {
                        Text("The key wasn't clear-cut for this song. Right-click it to set the key by hand.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if track.analysisEdited == true {
                        Text("Edited by hand.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                InfoSection(title: "Song") {
                    InfoRow(label: "Album", value: track.displayAlbum)
                    InfoRow(label: "Genre", value: track.displayGenre)
                    InfoRow(label: "Released", value: track.catalog?.releaseDate?.formatted(date: .long, time: .omitted))
                    InfoRow(label: "Track", value: track.catalog?.trackNumber.map { n in
                        track.catalog?.trackCount.map { "\(n) of \($0)" } ?? "\(n)"
                    })
                    InfoRow(label: "Length", value: Fmt.duration(track.duration))
                    InfoRow(label: "Explicit", value: track.catalog?.explicit.map { $0 ? "Yes" : "No" })
                }

                InfoSection(title: "SoundCloud") {
                    InfoRow(label: "Uploaded by", value: track.artist)
                    InfoRow(label: "Published", value: track.uploadDate?.formatted(date: .long, time: .omitted))
                    InfoRow(label: "Plays", value: Fmt.count(track.playCount))
                    InfoRow(label: "Likes", value: Fmt.count(track.likeCount))
                    InfoRow(label: "Reposts", value: Fmt.count(track.repostCount))
                    InfoRow(label: "Comments", value: Fmt.count(track.commentCount))
                    InfoRow(label: "License", value: track.license.map(Self.licenseName))
                    LinkRow(label: "Song page", url: track.sourceURL)
                    LinkRow(label: "Artist page", url: track.uploaderURL)
                }

                if let c = track.catalog {
                    InfoSection(title: "Apple Music Catalog") {
                        InfoRow(label: "Title", value: c.trackName)
                        InfoRow(label: "Artist", value: c.artistName)
                        InfoRow(label: "Album", value: c.albumName)
                        LinkRow(label: "Listing", url: c.storeURL)
                    }
                }

                InfoSection(title: "File") {
                    InfoRow(label: "Format", value: playlist.manifest.format.title + " (." + fileURL.pathExtension + ")")
                    InfoRow(label: "Bitrate", value: fileBitrate)
                    InfoRow(label: "Size", value: fileSize.map(Fmt.bytes))
                    InfoRow(label: "Source", value: sourceQuality)
                    InfoRow(label: "Folder", value: track.folder)
                    InfoRow(label: "File name", value: (track.fileName as NSString).lastPathComponent)
                }

                if let d = track.description {
                    InfoSection(title: "Description") {
                        Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(18)
        }
    }

    static func licenseName(_ raw: String) -> String {
        switch raw {
        case "all-rights-reserved": return "All rights reserved"
        case "no-rights-reserved": return "No rights reserved"
        default: return raw.hasPrefix("cc-") ? "Creative Commons (\(raw.dropFirst(3).uppercased()))" : raw
        }
    }
}

private struct PlaylistInspector: View {
    private var averageBPM: String? {
        let values = playlist.manifest.tracks.compactMap(\.bpm)
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return "\(Fmt.bpm(values.reduce(0, +) / Double(values.count))) (\(Fmt.bpm(sorted.first!))–\(Fmt.bpm(sorted.last!)))"
    }

    let playlist: LibraryPlaylist
    let enriching: Bool
    var selectedCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArtworkView(url: playlist.coverURL, corner: 10)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                Text(playlist.manifest.title).font(.title3.bold())
                if enriching {
                    Label("Looking up release dates and album info…", systemImage: "sparkle.magnifyingglass")
                        .font(.callout).foregroundStyle(.secondary)
                }
                InfoSection(title: playlist.manifest.isSet ? "Set" : "Playlist") {
                    InfoRow(label: "Curated by", value: playlist.manifest.uploader)
                    InfoRow(label: "Average BPM", value: averageBPM)
                    InfoRow(label: "Songs", value: "\(playlist.manifest.tracks.count)")
                    InfoRow(label: "Length", value: Fmt.longDuration(playlist.manifest.totalDuration))
                    InfoRow(label: "Format", value: playlist.manifest.formatLabel)
                    InfoRow(label: "Folders", value: playlist.manifest.folderList.isEmpty ? nil : playlist.manifest.folderList.joined(separator: ", "))
                    InfoRow(label: playlist.manifest.isSet ? "Created" : "Downloaded",
                            value: playlist.manifest.downloadedAt.formatted(date: .long, time: .shortened))
                    if !playlist.manifest.isSet, let updated = playlist.manifest.updatedAt,
                       updated > playlist.manifest.downloadedAt.addingTimeInterval(60) {
                        InfoRow(label: "Updated", value: updated.formatted(date: .long, time: .shortened))
                    }
                    LinkRow(label: "SoundCloud", url: playlist.manifest.sourceURL.nilIfBlank)
                }
                InfoSection(title: "Location") {
                    Text(playlist.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout).textSelection(.enabled)
                    Button { NSWorkspace.shared.open(playlist.folder) } label: { Label("Show in Finder", systemImage: "folder") }
                }
                if let d = playlist.manifest.description {
                    InfoSection(title: "Description") {
                        Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text(selectedCount > 1 ? "\(selectedCount) songs selected." : "Select a song to see its details.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .padding(18)
        }
    }
}

private struct AdaptiveLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 6) { configuration.icon; configuration.title }
        }
    }
}
