import Foundation

/// `ResonanceStudio --selftest <url> <format>` runs a real download without the window and prints the result.
/// Set RESONANCE_LIBRARY to keep test downloads out of the real library.
@MainActor
enum SelfTest {
    private static var library: Library!
    private static var center: DownloadCenter!
    private static var account: Account!

    static func run(url: String, format: String) {
        library = Library()
        center = DownloadCenter()
        account = Account()
        center.attach(library: library)
        center.start(url: url, format: AudioFormat(rawValue: format) ?? .original)
        guard let job = center.jobs.first else { exit(2) }

        var lastLine = ""
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let line = "[\(job.state)] \(job.title) — \(job.subtitle) — \(Int(job.fraction * 100))%"
                if line != lastLine { print(line); lastLine = line }
                guard !job.isActive else { return }
                if let id = job.playlistID, library.enriching.contains(id) || library.pendingAnalysisCount > 0 { return }
                timer.invalidate()
                report(job)
                exit(job.state == .done ? 0 : 1)
            }
        }
    }

    private static func report(_ job: DownloadJob) {
        print("failures:", job.failures)
        guard let id = job.playlistID, let p = library.playlist(id: id) else { print("no playlist in library"); return }
        print("folder:", p.folder.path)
        print("cover:", p.coverURL?.lastPathComponent ?? "none")
        for t in p.manifest.tracks {
            let art = p.artworkURL(for: t).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            print(" #\(t.index) bpm=\(t.bpm.map(Fmt.bpm) ?? "-") key=\(t.camelot ?? "-") \(t.title) | \(t.displayArtist) | genre=\(t.displayGenre ?? "-") | uploaded=\(t.uploadDate.map { "\($0)" } ?? "-") | plays=\(t.playCount ?? -1) | art=\(art) | catalog=\(t.catalog.map { "\($0.trackName) / \($0.albumName ?? "-") / \($0.releaseDate.map { "\($0)" } ?? "-")" } ?? "none") | file=\(t.fileName)")
        }
    }

    /// `ResonanceStudio --selftest-tools` runs the first-launch tool download and reports the result.
    static func installTools() {
        let installer = ToolInstaller()
        Task { @MainActor in
            let watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { print("phase:", installer.phase) }
            }
            await installer.install(force: true)
            watcher.invalidate()
            print("final:", installer.phase)
            if let t = Tools.locate() { print("yt-dlp:", t.ytdlp.path); print("ffmpeg:", t.ffmpeg.path) }
            exit(installer.phase == .ready ? 0 : 1)
        }
    }

    /// `ResonanceStudio --selftest-analyze <file>...` prints BPM and key for each audio file.
    static func analyze(files: [String]) {
        Task { @MainActor in
            guard let tools = Tools.locate() else { print("no ffmpeg"); exit(1) }
            for f in files {
                let start = Date()
                do {
                    let a = try await Analyzer.analyze(file: URL(fileURLWithPath: f), duration: nil, ffmpeg: tools.ffmpeg)
                    print(String(format: "%@ | BPM %.2f | %@ (%@) conf %.2f | %.1fs", (f as NSString).lastPathComponent, a.bpm, a.camelot, a.keyName, a.keyConfidence, Date().timeIntervalSince(start)))
                } catch { print(f, "ERROR", error.localizedDescription) }
            }
            exit(0)
        }
    }

    /// `ResonanceStudio --selftest-organize <url>`: download, update, folders, reorder, sets.
    static func organize(url: String) {
        library = Library()
        center = DownloadCenter()
        center.attach(library: library)
        Task { @MainActor in
            @MainActor func busy(_ job: DownloadJob) -> Bool {
                job.isActive || library.pendingAnalysisCount > 0 || !library.enriching.isEmpty
            }
            @MainActor func wait(_ job: DownloadJob) async {
                while busy(job) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            @MainActor func dump(_ label: String) {
                library.reload()
                print("\n== \(label)")
                for p in library.playlists {
                    print("[\(p.manifest.isSet ? "set" : "playlist")] \(p.folder.lastPathComponent)  folders=\(p.manifest.folderList)")
                    for t in p.manifest.orderedTracks {
                        let ok = FileManager.default.fileExists(atPath: p.fileURL(for: t).path)
                        print("   idx=\(t.index) bpm=\(t.bpm.map(Fmt.bpm) ?? "-") key=\(t.camelot ?? "-") \(ok ? "OK " : "MISSING ") \(t.fileName)")
                    }
                    let onDisk = (FileManager.default.enumerator(atPath: p.folder.path)?.compactMap { $0 as? String } ?? [])
                        .filter { !$0.hasPrefix(".resonance") && !$0.hasPrefix(".") && ["m4a","mp3","wav","flac","opus"].contains(($0 as NSString).pathExtension) }
                    let tracked = Set(p.manifest.tracks.map(\.fileName))
                    let stray = onDisk.filter { !tracked.contains($0) }
                    if !stray.isEmpty { print("   STRAY FILES:", stray) }
                }
            }

            center.start(url: url, format: .original)
            await wait(center.jobs[0])
            dump("1. first download")
            guard var p = library.playlists.first else { print("FAIL no playlist"); exit(1) }

            // Pretend this was downloaded on an earlier day and SoundCloud has since added the last song.
            let last = p.manifest.orderedTracks.last!
            try? FileManager.default.removeItem(at: p.fileURL(for: last))
            library.mutate(p.id) { m, _ in m.tracks.removeAll { $0.id == last.id } }
            library.renameFolder(of: p.id, to: Library.datedName(p.manifest.title, date: Date(timeIntervalSinceNow: -86_400 * 17)))
            library.reorder(p.id, moving: [p.manifest.orderedTracks[1].id], to: 0, within: p.manifest.orderedTracks.map(\.id))
            dump("2. made it look old, removed last song, swapped first two")

            center.start(url: url, format: .mp3)
            await wait(center.jobs[0])
            print("update job: isUpdate=\(center.jobs[0].isUpdate) format=\(center.jobs[0].format.title) state=\(center.jobs[0].state) — \(center.jobs[0].subtitle)")
            dump("3. same link again (should add 1 song at the end, keep custom order, rename to today)")

            center.start(url: url, format: .original)
            await wait(center.jobs[0])
            print("again: \(center.jobs[0].subtitle)")

            p = library.playlists.first { !$0.manifest.isSet }!
            let warm = library.createFolder(p.id, named: "Warm-up")!
            library.moveTracks(p.id, ids: [p.manifest.orderedTracks[0].id, p.manifest.orderedTracks[2].id], toFolder: warm)
            dump("4. folder Warm-up with songs 1 and 3")

            p = library.playlist(id: p.id)!
            let inFolder = p.tracks(inFolder: warm).map(\.id)
            library.reorder(p.id, moving: [inFolder.last!], to: 0, within: inFolder)
            dump("5. reordered inside Warm-up (last to first)")

            let setID = library.createSet(named: "Friday Set")!
            library.copyTracks(from: p.id, ids: p.manifest.orderedTracks.map(\.id), to: setID)
            library.applyOrder(setID, visible: library.mixOrder(library.playlist(id: setID)!.manifest.orderedTracks))
            dump("6. set with all songs, arranged for mixing")

            library.renameFolder(p.id, from: warm, to: "Opening")
            library.setBPM(p.id, ids: [p.manifest.orderedTracks[0].id]) { $0 * 2 }
            dump("7. renamed folder to Opening, doubled BPM of first song")

            library.deleteFolder(p.id, named: "Opening")
            library.trashTracks(setID, ids: [library.playlist(id: setID)!.manifest.orderedTracks[0].id])
            dump("8. removed folder (songs back to main), trashed one song from the set")
            exit(0)
        }
    }
}
