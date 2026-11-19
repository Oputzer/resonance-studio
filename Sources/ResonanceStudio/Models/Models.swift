import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case original, mp3, aac, wav, flac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        }
    }

    var detail: String {
        switch self {
        case .original: return "Untouched source file. Best quality, smallest size."
        case .mp3: return "320 kbps. Plays on everything."
        case .aac: return "Apple's format. Great for the Music app."
        case .wav: return "Uncompressed. For DJ and editing software."
        case .flac: return "Lossless, and smaller than WAV."
        }
    }

    var ytdlpArguments: [String] {
        // Never accept SoundCloud's 30-second previews of Go+ songs.
        let source = ["-f", "bestaudio[format_id!*=preview]/best[format_id!*=preview]"]
        switch self {
        case .original: return source
        case .mp3: return source + ["-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        case .aac: return source + ["-x", "--audio-format", "m4a", "--audio-quality", "0"]
        case .wav: return source + ["-x", "--audio-format", "wav"]
        case .flac: return source + ["-x", "--audio-format", "flac"]
        }
    }

    /// WAV has no reliable place to store cover art.
    var embedsArtwork: Bool { self != .wav }
}

/// Song details from Apple's public music catalog, when a confident match exists.
struct CatalogMatch: Codable, Hashable {
    var trackName: String
    var artistName: String
    var albumName: String?
    var releaseDate: Date?
    var genre: String?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var explicit: Bool?
    var artworkURL: String?
    var storeURL: String?
    var artworkFile: String?
}

struct TrackMeta: Codable, Identifiable, Hashable {
    var id: String
    var index: Int
    var title: String
    var artist: String
    var album: String?
    var genre: String?
    var uploadDate: Date?
    var duration: Double?
    var description: String?
    var sourceURL: String?
    var uploaderURL: String?
    var license: String?
    var playCount: Int?
    var likeCount: Int?
    var repostCount: Int?
    var commentCount: Int?
    var sourceCodec: String?
    var sourceBitrate: Double?
    var fileName: String
    var artworkFile: String?
    var catalog: CatalogMatch?
    var catalogChecked: Bool?
    /// Detected tempo and key.
    var analysis: AudioAnalysis?
    var analysisVersion: Int?
    /// True once someone corrects the BPM or key by hand, so re-analysis never overwrites it.
    var analysisEdited: Bool?
    /// Sub-folder inside the playlist folder, or nil for the playlist's main folder.
    var folder: String?

    var displayArtist: String { catalog?.artistName ?? artist }
    var displayAlbum: String? { catalog?.albumName ?? album }
    var displayGenre: String? { genre?.nilIfBlank ?? catalog?.genre }
    var displayDate: Date? { catalog?.releaseDate ?? uploadDate }
    var bpm: Double? { analysis.flatMap { $0.bpm > 0 ? $0.bpm : nil } }
    var camelot: String? { analysis?.camelot }
    var needsAnalysis: Bool { analysisEdited != true && (analysisVersion ?? 0) < Analyzer.version }

    // Sort keys for the song table. Missing values sort last.
    var sortTitle: String { title.lowercased() }
    var sortArtist: String { displayArtist.lowercased() }
    var sortAlbum: String { displayAlbum?.lowercased() ?? "\u{10FFFF}" }
    var sortGenre: String { displayGenre?.lowercased() ?? "\u{10FFFF}" }
    var sortDate: Date { displayDate ?? .distantFuture }
    var sortDuration: Double { duration ?? .greatestFiniteMagnitude }
    var sortBPM: Double { bpm ?? .greatestFiniteMagnitude }
    var sortKey: Int { Analyzer.camelotOrder(camelot) }
    var sortFolder: String { folder?.lowercased() ?? "" }
    var sortPlays: Int { -(playCount ?? -1) }
}

struct PlaylistManifest: Codable, Hashable {
    var version = 1
    /// Stable identity, so a playlist keeps its place in the app when its folder is renamed.
    var uid: String?
    /// "set" for sets made in the app; nil for SoundCloud downloads.
    var kind: String?
    /// SoundCloud's own id for the playlist or song, used to recognise it when added again.
    var sourceID: String?
    var updatedAt: Date?
    /// Sub-folders, in the order they're shown.
    var folders: [String]?
    /// Songs the person deleted, so updates from SoundCloud don't bring them back.
    var removedIDs: [String]?
    var title: String
    var uploader: String?
    var sourceURL: String
    var description: String?
    var downloadedAt: Date
    var format: AudioFormat
    var isSingleTrack: Bool
    var tracks: [TrackMeta]

    var totalDuration: Double { tracks.compactMap(\.duration).reduce(0, +) }
    var isSet: Bool { kind == "set" }
    var folderList: [String] { folders ?? [] }
    var lastChanged: Date { updatedAt ?? downloadedAt }
    var formatLabel: String {
        if isSet {
            let formats = Set(tracks.map { ($0.fileName as NSString).pathExtension.lowercased() })
            return formats.count == 1 ? (formats.first ?? "").uppercased() : "Mixed"
        }
        return format.title
    }
    var orderedTracks: [TrackMeta] { tracks.sorted { $0.index < $1.index } }

    static let fileName = "playlist.json"

    static func load(from folder: URL) -> PlaylistManifest? {
        let url = folder.appendingPathComponent(".resonance/\(fileName)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder.decode(PlaylistManifest.self, from: data)
    }

    func save(to folder: URL) throws {
        let dir = folder.appendingPathComponent(".resonance", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSON.encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A downloaded playlist living on disk.
struct LibraryPlaylist: Identifiable, Hashable {
    var folder: URL
    var manifest: PlaylistManifest
    var id: String { manifest.uid ?? folder.path }

    var coverURL: URL? {
        let cover = folder.appendingPathComponent(".resonance/art/playlist.jpg")
        if FileManager.default.fileExists(atPath: cover.path) { return cover }
        return manifest.tracks.first.flatMap(artworkURL(for:))
    }

    func fileURL(for track: TrackMeta) -> URL { folder.appendingPathComponent(track.fileName) }

    func tracks(inFolder name: String?) -> [TrackMeta] {
        manifest.orderedTracks.filter { name == nil || $0.folder == name }
    }

    func artworkURL(for track: TrackMeta) -> URL? {
        track.artworkFile.map { folder.appendingPathComponent(".resonance/art/\($0)") }
    }

    /// Prefers the high-resolution catalog cover when one was found.
    func bestArtworkURL(for track: TrackMeta) -> URL? {
        if let file = track.catalog?.artworkFile {
            let url = folder.appendingPathComponent(".resonance/art/\(file)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return artworkURL(for: track)
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum Fmt {
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "—" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func longDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func bpm(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func count(_ n: Int?) -> String? {
        guard let n else { return nil }
        return n.formatted(.number.notation(.compactName))
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
