import Foundation

/// Membaca Now Playing macOS untuk pemutar selain Spotify dan Music, misalnya Meiro (YouTube Music) atau browser.
///
/// Sejak macOS 15.4, data Now Playing hanya diberikan ke program milik Apple, jadi pembacanya (NowPlaying.dylib,
/// dari Helper/NowPlaying.m) dijalankan di dalam /usr/bin/perl bawaan macOS. Proses itu mengirim satu baris JSON
/// setiap kali lagu berubah dan menerima perintah putar/jeda lewat stdin. Kalau Apple menutup jalan ini,
/// pembacanya diam saja dan Spotify serta Music tetap berjalan seperti biasa.
final class NowPlayingSource {
    struct State {
        let bundleID: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let elapsed: Double
        let rate: Double
        let timestamp: TimeInterval
        let playing: Bool
    }

    /// Browser juga mengirim Now Playing untuk video biasa. YouTube Music di browser selalu mengisi album,
    /// video YouTube tidak, jadi dari browser hanya yang punya album yang dianggap lagu.
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var state: State?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0

    init() { start() }

    private static let script = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "lyricsbar_now_playing") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
    """

    private func start() {
        guard let library = Bundle.main.url(forResource: "NowPlaying", withExtension: "dylib") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script, library.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.state = nil }
            self.onChange?()
            // Coba lagi beberapa kali (misalnya setelah crash); kalau terus gagal, berhenti supaya tidak boros.
            self.failures += 1
            guard self.failures < 5 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { self.start() }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
        } catch {
            return
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            failures = 0
            let next: State?
            if let title = json["title"] as? String, let bundle = json["bundle"] as? String {
                next = State(bundleID: bundle, title: title, artist: json["artist"] as? String ?? "",
                             album: json["album"] as? String ?? "", duration: json["duration"] as? Double ?? 0,
                             elapsed: json["elapsed"] as? Double ?? 0, rate: json["rate"] as? Double ?? 0,
                             timestamp: json["timestamp"] as? Double ?? Date().timeIntervalSince1970,
                             playing: json["playing"] as? Bool ?? false)
            } else {
                next = nil
            }
            lock.withLock { state = next }
            onChange?()
        }
    }

    /// Pemutar dan statusnya, atau nil kalau tidak ada pemutar lain yang memutar lagu.
    func read() -> (Player, PlayerStatus)? {
        guard let state = lock.withLock({ state }) else { return nil }
        // Spotify dan Music dibaca lewat AppleScript, yang lebih lengkap.
        if Player.scripted.contains(where: { $0.bundleID == state.bundleID }) { return nil }
        if Self.browsers.contains(state.bundleID), state.album.isEmpty { return nil }

        let player = Player.other(state.bundleID)
        let playing = state.playing && state.rate > 0
        var position = state.elapsed
        if playing { position += (Date().timeIntervalSince1970 - state.timestamp) * state.rate }
        if state.duration > 0 { position = min(position, state.duration) }
        let (title, artist) = Self.clean(title: state.title, artist: state.artist)
        let track = Track(id: "\(state.bundleID):\(state.title):\(state.artist):\(Int(state.duration))",
                          title: title, artist: artist, album: state.album,
                          duration: state.duration, player: player)
        return (player, .active(track, playing: playing, position: position, sampledAt: ProcessInfo.processInfo.systemUptime))
    }

    /// Lagu dari video YouTube sering berjudul "Artis - Lagu (Official Video)" dengan artis "ArtisVEVO" atau
    /// "Artis - Topic". Dirapikan supaya tampil bersih dan liriknya ketemu.
    static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var artist = artist
            .replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*(VEVO|Official)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        var title = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|lirik|visuali[sz]er|m/?v|\bhd\b|4k)[^\)\]]*[\)\]]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        // "Artis - Lagu" atau "Lagu - Artis": buang bagian yang berisi nama artis. Kalau artisnya kosong,
        // anggap bagian depan sebagai artis.
        let parts = title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            func isArtist(_ part: String) -> Bool {
                !artist.isEmpty && (part.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(part))
            }
            if artist.isEmpty || isArtist(parts[0]) {
                if artist.isEmpty { artist = parts[0] }
                title = parts.dropFirst().joined(separator: " - ")
            } else if parts.count == 2, isArtist(parts[1]) {
                title = parts[0]
            }
        }
        return (title, artist)
    }

    func send(_ command: PlayerCommand) {
        let word: String
        switch command {
        case .playPause: word = "toggle"
        case .next: word = "next"
        case .previous: word = "previous"
        }
        try? input?.write(contentsOf: Data((word + "\n").utf8))
    }
}
