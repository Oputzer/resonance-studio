import AppKit
import Foundation

@MainActor
final class Library: ObservableObject {
    @Published private(set) var playlists: [LibraryPlaylist] = []
    /// Playlist ids whose song details are being looked up.
    @Published private(set) var enriching: Set<String> = []
    /// "playlistID/trackID" for songs whose BPM and key are being worked out right now.
    @Published private(set) var analyzing: Set<String> = []
    @Published var lastError: String?

    weak var player: Player?

    private var analysisQueue: [(playlist: String, track: String)] = []
    private var queued: Set<String> = []
    private var analysisWorkers = 0

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let root = Paths.libraryRoot
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        let found = folders.compactMap { folder -> LibraryPlaylist? in
            guard var manifest = PlaylistManifest.load(from: folder) else { return nil }
            if manifest.uid == nil {
                manifest.uid = UUID().uuidString
                try? manifest.save(to: folder)
            }
            return LibraryPlaylist(folder: folder, manifest: manifest)
        }
        let sorted = found.sorted { $0.manifest.lastChanged > $1.manifest.lastChanged }
        if sorted != playlists { playlists = sorted }
    }

    func playlist(id: String) -> LibraryPlaylist? { playlists.first { $0.id == id } }
    func playlist(at folder: URL) -> LibraryPlaylist? {
        playlists.first { $0.folder.standardizedFileURL == folder.standardizedFileURL }
    }
    var sets: [LibraryPlaylist] { playlists.filter(\.manifest.isSet) }

    /// Finds a playlist previously downloaded from the same SoundCloud link.
    func playlist(sourceID: String?, url: String) -> LibraryPlaylist? {
        if let sourceID, let hit = playlists.first(where: { !$0.manifest.isSet && $0.manifest.sourceID == sourceID }) {
            return hit
        }
        let key = Self.normalize(url)
        return playlists.first { !$0.manifest.isSet && Self.normalize($0.manifest.sourceURL) == key }
    }

    static func normalize(_ url: String) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return url.lowercased() }
        c.query = nil
        c.fragment = nil
        var host = (c.host ?? "").lowercased()
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        var path = c.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// The one way to change a playlist: edits the current copy, saves it, and publishes it,
    /// so background work (song details, analysis) never overwrites someone's edits.
    @discardableResult
    func mutate(_ id: String, _ body: (inout PlaylistManifest, URL) -> Void) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return false }
        var m = playlists[i].manifest
        let folder = playlists[i].folder
        body(&m, folder)
        do {
            try m.save(to: folder)
            playlists[i].manifest = m
            return true
        } catch {
            lastError = "Couldn't save changes: \(error.localizedDescription)"
            return false
        }
    }

    /// Points a playlist at its folder's new location after a rename.
    func relocate(_ id: String, to folder: URL) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].folder = folder
    }

    func moveToTrash(_ playlist: LibraryPlaylist) {
        try? FileManager.default.trashItem(at: playlist.folder, resultingItemURL: nil)
        reload()
    }

    // MARK: Song details

    /// Fills in release dates, genres, albums and high-resolution covers from Apple's public catalog.
    func enrich(_ id: String) {
        guard !enriching.contains(id) else { return }
        enriching.insert(id)
        Task {
            defer { enriching.remove(id) }
            let pending = playlist(id: id)?.manifest.tracks.filter { $0.catalogChecked != true } ?? []
            for t in pending {
                var match = await Catalog.shared.lookup(title: t.title, artist: t.artist)
                if var m = match, let folder = playlist(id: id)?.folder {
                    m.artworkFile = await Catalog.saveArtwork(m, trackID: t.id, folder: folder)
                    match = m
                }
                mutate(id) { manifest, _ in
                    guard let j = manifest.tracks.firstIndex(where: { $0.id == t.id }) else { return }
                    if let match { manifest.tracks[j].catalog = match }
                    manifest.tracks[j].catalogChecked = true
                }
            }
        }
    }

    func enrichAllPending() {
        for p in playlists where p.manifest.tracks.contains(where: { $0.catalogChecked != true }) {
            enrich(p.id)
        }
    }

    // MARK: BPM and key

    func isAnalyzing(_ playlistID: String, _ trackID: String) -> Bool {
        analyzing.contains("\(playlistID)/\(trackID)")
    }

    func isQueued(_ playlistID: String, _ trackID: String) -> Bool {
        queued.contains("\(playlistID)/\(trackID)")
    }

    /// Queues every song that hasn't been analyzed yet (or was analyzed by an older version).
    func analyzePending() {
        for p in playlists {
            for t in p.manifest.orderedTracks where t.needsAnalysis { enqueue(p.id, t.id) }
        }
    }

    func reanalyze(_ playlistID: String, _ trackIDs: [String]) {
        mutate(playlistID) { m, _ in
            for i in m.tracks.indices where trackIDs.contains(m.tracks[i].id) {
                m.tracks[i].analysisEdited = nil
                m.tracks[i].analysisVersion = nil
            }
        }
        for id in trackIDs { enqueue(playlistID, id) }
    }

    private func enqueue(_ playlistID: String, _ trackID: String) {
        let key = "\(playlistID)/\(trackID)"
        guard !queued.contains(key) else { return }
        queued.insert(key)
        analysisQueue.append((playlistID, trackID))
        objectWillChange.send()
        // Two at a time keeps the Mac responsive while still getting through big playlists quickly.
        while analysisWorkers < 2 && !analysisQueue.isEmpty {
            analysisWorkers += 1
            Task { await analysisWorker() }
        }
    }

    private func analysisWorker() async {
        defer { analysisWorkers -= 1 }
        while !analysisQueue.isEmpty {
            let item = analysisQueue.removeFirst()
            let key = "\(item.playlist)/\(item.track)"
            defer { queued.remove(key); analyzing.remove(key) }
            guard let tools = Tools.locate(),
                  let p = playlist(id: item.playlist),
                  let t = p.manifest.tracks.first(where: { $0.id == item.track }), t.needsAnalysis else { continue }
            analyzing.insert(key)
            let result = try? await Analyzer.analyze(file: p.fileURL(for: t), duration: t.duration, ffmpeg: tools.ffmpeg)
            mutate(item.playlist) { m, _ in
                guard let j = m.tracks.firstIndex(where: { $0.id == item.track }), m.tracks[j].analysisEdited != true else { return }
                m.tracks[j].analysis = result
                m.tracks[j].analysisVersion = Analyzer.version
            }
        }
    }

    var pendingAnalysisCount: Int { queued.count }
}

/// Looks songs up in the iTunes Search API (free, no account needed).
actor Catalog {
    static let shared = Catalog()
    private var lastRequest = Date.distantPast

    func lookup(title: String, artist: String) async -> CatalogMatch? {
        // The API allows roughly 20 requests a minute.
        let wait = 3.2 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()

        let cleanTitle = Self.stripNoise(title)
        let term = cleanTitle.contains(" - ") ? cleanTitle : "\(artist) \(cleanTitle)"
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "15"),
        ]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }

        let haystack = Self.normalize("\(title) \(artist)")
        let normTitle = Self.normalize(cleanTitle)
        let sourceVersions = Self.versionWords(in: title)
        var candidates: [[String: Any]] = []
        for r in results {
            guard let name = r["trackName"] as? String, let artistName = r["artistName"] as? String else { continue }
            let n = Self.normalize(Self.stripNoise(name))
            let a = Self.normalize(artistName.components(separatedBy: CharacterSet(charactersIn: "&,")).first ?? artistName)
            guard n.count >= 3, a.count >= 2,
                  normTitle.contains(n) || n.contains(normTitle),
                  haystack.contains(a),
                  // Don't label an original as a remix/live/etc. version, or the other way round.
                  Self.versionWords(in: "\(name) \(r["collectionName"] as? String ?? "")") == sourceVersions
            else { continue }
            candidates.append(r)
        }
        // The earliest release is almost always the original album or single.
        let best = candidates.min { ($0["releaseDate"] as? String ?? "9") < ($1["releaseDate"] as? String ?? "9") }
        if let r = best, let name = r["trackName"] as? String, let artistName = r["artistName"] as? String {
            return CatalogMatch(
                trackName: name,
                artistName: artistName,
                albumName: r["collectionName"] as? String,
                releaseDate: (r["releaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                genre: r["primaryGenreName"] as? String,
                trackNumber: r["trackNumber"] as? Int,
                trackCount: r["trackCount"] as? Int,
                discNumber: r["discNumber"] as? Int,
                explicit: (r["trackExplicitness"] as? String).map { $0 == "explicit" },
                artworkURL: (r["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "3000x3000bb"),
                storeURL: r["trackViewUrl"] as? String,
                artworkFile: nil
            )
        }
        return nil
    }

    static func versionWords(in s: String) -> Set<String> {
        let words = ["remix", "live", "acoustic", "instrumental", "karaoke", "edit", "extended", "remaster", "remastered", "cover", "sped up", "slowed", "lofi", "lo-fi", "mix"]
        let lower = s.lowercased()
        return Set(words.filter { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil })
    }

    static func saveArtwork(_ match: CatalogMatch, trackID: String, folder: URL) async -> String? {
        guard let s = match.artworkURL, let url = URL(string: s),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
        let name = "\(trackID)-catalog.jpg"
        let dest = folder.appendingPathComponent(".resonance/art/\(name)")
        return (try? data.write(to: dest, options: .atomic)) != nil ? name : nil
    }

    /// Removes things like "(Free Download)", "[Official Audio]", "prod. by …".
    static func stripNoise(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(free|download|official|audio|video|out now|prod|premiere)[^\)\]]*[\)\]]"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+(prod\.?|produced) by .*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let cleaned = folded.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        let alnum = cleaned.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(alnum).split(separator: " ").joined(separator: " ")
    }
}

/// Small downsampling image cache so big covers don't slow down scrolling.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, maxPixels: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let cg = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
