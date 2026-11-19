import Foundation

/// Organizing songs: order, folders inside a playlist, sets, and keeping the files on disk
/// named and placed to match, so the library looks the same in Finder and on a USB stick.
extension Library {

    /// Works out which playlist and song each dragged file belongs to.
    func locate(_ urls: [URL]) -> [(playlist: String, ids: [String])] {
        var result: [String: [String]] = [:]
        var order: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            for p in playlists where path.hasPrefix(p.folder.standardizedFileURL.path + "/") {
                if let t = p.manifest.tracks.first(where: { p.fileURL(for: $0).standardizedFileURL.path == path }) {
                    if result[p.id] == nil { order.append(p.id) }
                    result[p.id, default: []].append(t.id)
                }
            }
        }
        return order.map { ($0, result[$0] ?? []) }
    }

    /// Handles songs dropped on a playlist, set or folder in the sidebar.
    func receive(_ urls: [URL], into targetID: String, folder: String?) -> Bool {
        let groups = locate(urls)
        for (sourceID, ids) in groups {
            if sourceID == targetID { moveTracks(targetID, ids: ids, toFolder: folder) }
            else { copyTracks(from: sourceID, ids: ids, to: targetID, folder: folder) }
        }
        return !groups.isEmpty
    }

    // MARK: Order

    /// Moves `ids` to `destination` within the `visible` list (a folder, search result or the whole
    /// playlist). Songs that aren't visible keep their places.
    func reorder(_ pid: String, moving ids: [String], to destination: Int, within visible: [String]) {
        let moving = Set(ids)
        var newVisible = visible.filter { !moving.contains($0) }
        let before = visible.prefix(destination).filter { !moving.contains($0) }.count
        newVisible.insert(contentsOf: visible.filter { moving.contains($0) }, at: min(before, newVisible.count))
        applyOrder(pid, visible: newVisible)
    }

    /// Makes `visible` (already in the wanted order) the playlist order, keeping other songs in place.
    func applyOrder(_ pid: String, visible: [String]) {
        mutate(pid) { m, folder in
            let global = m.orderedTracks.map(\.id)
            let visibleSet = Set(visible)
            var queue = visible[...]
            let order = global.map { id -> String in
                guard visibleSet.contains(id), let next = queue.popFirst() else { return id }
                return next
            }
            for (position, id) in order.enumerated() {
                if let i = m.tracks.firstIndex(where: { $0.id == id }) { m.tracks[i].index = position + 1 }
            }
            renumberFiles(&m, folder: folder)
        }
    }

    /// Orders songs so each one mixes into the next: compatible keys first, then the closest tempo.
    func mixOrder(_ tracks: [TrackMeta]) -> [String] {
        var pool = tracks.filter { $0.bpm != nil }
        let unanalyzed = tracks.filter { $0.bpm == nil }
        guard var current = pool.min(by: { $0.sortBPM < $1.sortBPM }) else { return tracks.map(\.id) }
        var result = [current]
        pool.removeAll { $0.id == current.id }
        while !pool.isEmpty {
            let bpm = current.bpm ?? 0
            func distance(_ t: TrackMeta) -> Double {
                let tempo = abs((t.bpm ?? 0) - bpm)
                let harmonic = Analyzer.isCompatible(current.camelot, t.camelot) ? 0.0 : 8.0
                let backwards = (t.bpm ?? 0) < bpm - 2 ? 4.0 : 0.0   // keep energy building
                return tempo + harmonic + backwards
            }
            let next = pool.min { distance($0) < distance($1) }!
            result.append(next)
            pool.removeAll { $0.id == next.id }
            current = next
        }
        return result.map(\.id) + unanalyzed.map(\.id)
    }

    // MARK: Folders

    @discardableResult
    func createFolder(_ pid: String, named raw: String) -> String? {
        var created: String?
        mutate(pid) { m, folder in
            let name = Self.uniqueName(Paths.safeName(raw), taken: Set(m.folderList.map { $0.lowercased() }))
            do {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true),
                                                        withIntermediateDirectories: true)
                m.folders = m.folderList + [name]
                created = name
            } catch {
                lastError = "Couldn't create the folder: \(error.localizedDescription)"
            }
        }
        return created
    }

    func renameFolder(_ pid: String, from old: String, to raw: String) {
        mutate(pid) { m, folder in
            let name = Self.uniqueName(Paths.safeName(raw), taken: Set(m.folderList.filter { $0 != old }.map { $0.lowercased() }))
            guard name != old else { return }
            let src = folder.appendingPathComponent(old, isDirectory: true)
            let dst = folder.appendingPathComponent(name, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.moveItem(at: src, to: dst)
                } else {
                    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
                }
            } catch {
                lastError = "Couldn't rename the folder: \(error.localizedDescription)"
                return
            }
            var remap: [URL: URL] = [:]
            for i in m.tracks.indices where m.tracks[i].folder == old {
                let base = (m.tracks[i].fileName as NSString).lastPathComponent
                remap[folder.appendingPathComponent(m.tracks[i].fileName)] = folder.appendingPathComponent("\(name)/\(base)")
                m.tracks[i].folder = name
                m.tracks[i].fileName = "\(name)/\(base)"
            }
            m.folders = m.folderList.map { $0 == old ? name : $0 }
            player?.remap(remap)
        }
    }

    /// Removes a folder. Its songs move back to the playlist's main folder; nothing is deleted.
    func deleteFolder(_ pid: String, named name: String) {
        let ids = playlist(id: pid)?.manifest.tracks.filter { $0.folder == name }.map(\.id) ?? []
        moveTracks(pid, ids: ids, toFolder: nil)
        mutate(pid) { m, folder in
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            let fm = FileManager.default
            let leftovers = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
            if leftovers.isEmpty { try? fm.removeItem(at: dir) }
            m.folders = m.folderList.filter { $0 != name }
        }
    }

    func moveTracks(_ pid: String, ids: [String], toFolder target: String?) {
        guard !ids.isEmpty else { return }
        mutate(pid) { m, folder in
            let fm = FileManager.default
            if let target {
                try? fm.createDirectory(at: folder.appendingPathComponent(target, isDirectory: true), withIntermediateDirectories: true)
                if !m.folderList.contains(target) { m.folders = m.folderList + [target] }
            }
            var remap: [URL: URL] = [:]
            for i in m.tracks.indices where ids.contains(m.tracks[i].id) && m.tracks[i].folder != target {
                let base = (m.tracks[i].fileName as NSString).lastPathComponent
                let relative = Self.freeName(base, in: target, folder: folder)
                let src = folder.appendingPathComponent(m.tracks[i].fileName)
                let dst = folder.appendingPathComponent(relative)
                do {
                    try fm.moveItem(at: src, to: dst)
                    remap[src] = dst
                    m.tracks[i].fileName = relative
                    m.tracks[i].folder = target
                } catch {
                    lastError = "Couldn't move “\(m.tracks[i].title)”: \(error.localizedDescription)"
                }
            }
            player?.remap(remap)
            renumberFiles(&m, folder: folder)
        }
    }

    // MARK: Sets

    /// Creates an empty set: a playlist built by hand from songs in other playlists.
    @discardableResult
    func createSet(named raw: String) -> String? {
        let fm = FileManager.default
        let root = Paths.libraryRoot
        let taken = Set(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.lowercased() })
        let name = Self.uniqueName(Paths.safeName(raw), taken: taken)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let manifest = PlaylistManifest(uid: UUID().uuidString, kind: "set", updatedAt: Date(), title: name, uploader: nil,
                                        sourceURL: "", description: nil, downloadedAt: Date(), format: .original,
                                        isSingleTrack: false, tracks: [])
        do {
            try fm.createDirectory(at: folder.appendingPathComponent(".resonance/art"), withIntermediateDirectories: true)
            try fm.createDirectory(at: folder.appendingPathComponent(".resonance/info"), withIntermediateDirectories: true)
            try manifest.save(to: folder)
        } catch {
            lastError = "Couldn't create the set: \(error.localizedDescription)"
            return nil
        }
        reload()
        return manifest.uid
    }

    /// Copies songs into another playlist or set. On Mac drives the copy shares storage with the
    /// original (an APFS clone), so it takes up almost no extra space.
    func copyTracks(from sourceID: String, ids: [String], to targetID: String, folder targetFolder: String? = nil) {
        guard sourceID != targetID, let source = playlist(id: sourceID) else {
            if sourceID == targetID { moveTracks(sourceID, ids: ids, toFolder: targetFolder) }
            return
        }
        let songs = source.manifest.orderedTracks.filter { ids.contains($0.id) }
        mutate(targetID) { m, folder in
            let fm = FileManager.default
            if let targetFolder {
                try? fm.createDirectory(at: folder.appendingPathComponent(targetFolder, isDirectory: true), withIntermediateDirectories: true)
                if !m.folderList.contains(targetFolder) { m.folders = m.folderList + [targetFolder] }
            }
            var next = (m.tracks.map(\.index).max() ?? 0) + 1
            for song in songs where !m.tracks.contains(where: { $0.id == song.id }) {
                let base = Self.baseName(song.fileName)
                let relative = Self.freeName(base, in: targetFolder, folder: folder)
                do {
                    try fm.copyItem(at: source.fileURL(for: song), to: folder.appendingPathComponent(relative))
                } catch {
                    lastError = "Couldn't copy “\(song.title)”: \(error.localizedDescription)"
                    continue
                }
                for art in [song.artworkFile, song.catalog?.artworkFile].compactMap({ $0 }) {
                    let dst = folder.appendingPathComponent(".resonance/art/\(art)")
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.copyItem(at: source.folder.appendingPathComponent(".resonance/art/\(art)"), to: dst)
                    }
                }
                var copy = song
                copy.fileName = relative
                copy.folder = targetFolder
                copy.index = next
                next += 1
                m.tracks.append(copy)
                m.removedIDs = m.removedIDs?.filter { $0 != song.id }
            }
            m.updatedAt = Date()
            renumberFiles(&m, folder: folder)
        }
    }

    /// Moves songs to the Trash and remembers them, so updating from SoundCloud won't re-download them.
    func trashTracks(_ pid: String, ids: [String]) {
        mutate(pid) { m, folder in
            for t in m.tracks where ids.contains(t.id) {
                try? FileManager.default.trashItem(at: folder.appendingPathComponent(t.fileName), resultingItemURL: nil)
            }
            m.tracks.removeAll { ids.contains($0.id) }
            m.removedIDs = Array(Set((m.removedIDs ?? []) + ids))
            renumberFiles(&m, folder: folder)
        }
    }

    // MARK: Editing details

    /// Re-applies the BPM range setting to every song that wasn't edited by hand.
    func applyTempoRange() {
        let range = TempoRange.current
        for p in playlists {
            guard p.manifest.tracks.contains(where: { $0.analysis != nil && $0.analysisEdited != true }) else { continue }
            mutate(p.id) { m, _ in
                for i in m.tracks.indices where m.tracks[i].analysisEdited != true {
                    guard var a = m.tracks[i].analysis else { continue }
                    let base = a.autoBPM ?? a.bpm
                    if a.autoBPM == nil { a.autoBPM = base }
                    a.bpm = range.fold(base)
                    m.tracks[i].analysis = a
                }
            }
        }
    }

    func setBPM(_ pid: String, ids: [String], transform: (Double) -> Double) {
        mutate(pid) { m, _ in
            for i in m.tracks.indices where ids.contains(m.tracks[i].id) {
                guard var a = m.tracks[i].analysis, a.bpm > 0 else { continue }
                a.bpm = (transform(a.bpm) * 10).rounded() / 10
                m.tracks[i].analysis = a
                m.tracks[i].analysisEdited = true
            }
        }
    }

    func setKey(_ pid: String, ids: [String], camelot: String) {
        guard let c = Analyzer.parseCamelot(camelot) else { return }
        let pc = Analyzer.camelotMajor.firstIndex(of: c.number) ?? 0
        let name = c.minor ? "\(Analyzer.minorPitchNames[(pc + 9) % 12]) minor" : "\(Analyzer.pitchNames[pc]) major"
        mutate(pid) { m, _ in
            for i in m.tracks.indices where ids.contains(m.tracks[i].id) {
                var a = m.tracks[i].analysis ?? AudioAnalysis(bpm: 0, camelot: camelot, keyName: name, keyConfidence: 1)
                a.camelot = camelot
                a.keyName = name
                a.keyConfidence = 1
                m.tracks[i].analysis = a
                m.tracks[i].analysisEdited = true
                m.tracks[i].analysisVersion = Analyzer.version
            }
        }
    }

    /// Renames a set or playlist folder (and its title).
    func rename(_ pid: String, to raw: String) {
        guard let p = playlist(id: pid) else { return }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let folderName = p.manifest.isSet ? Paths.safeName(title) : Self.datedName(title, date: p.manifest.lastChanged)
        renameFolder(of: pid, to: folderName)
        mutate(pid) { m, _ in m.title = title }
    }

    /// Moves a playlist's folder to a new name in the library, keeping everything inside intact.
    func renameFolder(of pid: String, to wanted: String) {
        guard let p = playlist(id: pid) else { return }
        let root = p.folder.deletingLastPathComponent()
        guard wanted != p.folder.lastPathComponent else { return }
        let fm = FileManager.default
        let taken = Set(((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != p.folder.lastPathComponent }.map { $0.lowercased() })
        let name = Self.uniqueName(wanted, taken: taken)
        let dst = root.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.moveItem(at: p.folder, to: dst)
        } catch {
            lastError = "Couldn't rename the folder: \(error.localizedDescription)"
            return
        }
        var remap: [URL: URL] = [:]
        for t in p.manifest.tracks { remap[p.fileURL(for: t)] = dst.appendingPathComponent(t.fileName) }
        player?.remap(remap)
        relocate(pid, to: dst)
    }

    // MARK: Files on disk

    /// Renames files so their numbers follow the playlist order: "01 - …", "02 - …", counted
    /// separately in each folder. Uses a two-step rename so files never overwrite each other.
    func renumberFiles(_ m: inout PlaylistManifest, folder: URL) {
        if m.isSingleTrack && m.tracks.count <= 1 { return }
        let fm = FileManager.default
        let groups = Dictionary(grouping: m.tracks.indices, by: { m.tracks[$0].folder ?? "" })
        var plan: [(index: Int, from: String, to: String)] = []
        for (_, members) in groups {
            let sorted = members.sorted { m.tracks[$0].index < m.tracks[$1].index }
            let width = sorted.count >= 100 ? 3 : 2
            for (n, i) in sorted.enumerated() {
                let t = m.tracks[i]
                let prefix = String(format: "%0\(width)d - ", n + 1)
                let wanted = (t.folder.map { "\($0)/" } ?? "") + prefix + Self.baseName(t.fileName)
                if wanted != t.fileName { plan.append((i, t.fileName, wanted)) }
            }
        }
        guard !plan.isEmpty else { return }
        var staged: [(index: Int, temp: String, to: String, from: String)] = []
        for step in plan {
            let dir = (step.from as NSString).deletingLastPathComponent
            let temp = (dir.isEmpty ? "" : dir + "/") + ".renaming-\(UUID().uuidString)-" + (step.from as NSString).lastPathComponent
            do {
                try fm.moveItem(at: folder.appendingPathComponent(step.from), to: folder.appendingPathComponent(temp))
                staged.append((step.index, temp, step.to, step.from))
            } catch {
                continue   // file missing or locked: leave it as it is
            }
        }
        var remap: [URL: URL] = [:]
        for s in staged {
            var target = s.to
            if fm.fileExists(atPath: folder.appendingPathComponent(target).path) {
                let dir = (target as NSString).deletingLastPathComponent
                target = Self.freeName((target as NSString).lastPathComponent, in: dir.isEmpty ? nil : dir, folder: folder)
            }
            do {
                try fm.moveItem(at: folder.appendingPathComponent(s.temp), to: folder.appendingPathComponent(target))
                m.tracks[s.index].fileName = target
                remap[folder.appendingPathComponent(s.from)] = folder.appendingPathComponent(target)
            } catch {
                try? fm.moveItem(at: folder.appendingPathComponent(s.temp), to: folder.appendingPathComponent(s.from))
            }
        }
        player?.remap(remap)
    }

    /// File name without its folder and without a leading "07 - " track number.
    static func baseName(_ fileName: String) -> String {
        let last = (fileName as NSString).lastPathComponent
        if let r = last.range(of: #"^\d{1,3} - "#, options: .regularExpression) { return String(last[r.upperBound...]) }
        return last
    }

    /// A relative path for `base` inside `sub` that doesn't collide with an existing file.
    static func freeName(_ base: String, in sub: String?, folder: URL) -> String {
        let prefix = sub.map { "\($0)/" } ?? ""
        var candidate = prefix + base
        var n = 2
        let stem = (base as NSString).deletingPathExtension, ext = (base as NSString).pathExtension
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = prefix + "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        return candidate
    }

    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var name = base, n = 2
        while taken.contains(name.lowercased()) { name = "\(base) (\(n))"; n += 1 }
        return name
    }

    static func datedName(_ title: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(Paths.safeName(title)) — \(f.string(from: date))"
    }
}
