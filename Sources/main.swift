// Lyricsbar — menampilkan lirik lagu Spotify atau Apple Music yang sedang diputar di Touch Bar.
// Posisi lagu dibaca lewat AppleScript; lirik bersinkron dari file lokal, LRCLIB, atau NetEase.

import AudioToolbox
import Cocoa
import CoreAudio
import ServiceManagement

// MARK: - Bahasa (Indonesia / Inggris)

enum AppLanguage: String, CaseIterable {
    case system, indonesian = "id", english = "en"

    var title: String {
        switch self {
        case .system: return L("Ikuti sistem", "Same as system")
        case .indonesian: return "Bahasa Indonesia"
        case .english: return "English"
        }
    }

    /// Pilihan di menu ♪ (disimpan); bawaannya mengikuti bahasa utama macOS.
    static var selected: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "language")
            isIndonesian = resolveIndonesian()
        }
    }

    fileprivate static var isIndonesian = resolveIndonesian()

    private static func resolveIndonesian() -> Bool {
        switch selected {
        case .indonesian: return true
        case .english: return false
        case .system:
            // Banyak pengguna di Indonesia memakai macOS berbahasa Inggris, jadi wilayah Indonesia juga dihitung.
            return Locale.preferredLanguages.first?.hasPrefix("id") == true || Locale.current.region?.identifier == "ID"
        }
    }
}

/// Teks dalam bahasa yang dipakai: Indonesia untuk pengguna berbahasa atau berwilayah Indonesia, selain itu Inggris.
func L(_ indonesian: String, _ english: String) -> String {
    AppLanguage.isIndonesian ? indonesian : english
}

// MARK: - Pemutar musik (Spotify, Apple Music)

enum Player: String, CaseIterable {
    case spotify, music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// Nama untuk ditampilkan dan untuk `tell application` di AppleScript.
    var name: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Dicek lewat daftar proses, jadi tidak perlu mengirim Apple Event ke app yang belum siap
    /// (dan tidak membuka app yang sedang tertutup).
    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }
}

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double // detik
    var player: Player = .spotify
}

enum PlayerStatus {
    case notRunning
    /// Pemutar sedang dibuka atau belum menjawab (misalnya tepat setelah login).
    case starting
    case stopped
    case denied
    case failed(String)
    case active(Track, playing: Bool, position: Double, sampledAt: TimeInterval)

    var isPlaying: Bool {
        if case .active(_, playing: true, _, _) = self { return true }
        return false
    }

    var hasTrack: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Membaca Spotify dan Music. Kalau keduanya terbuka, yang dipakai adalah yang sedang memutar lagu;
/// kalau keduanya diam, tetap pemutar terakhir. Semua method dipanggil dari satu antrean yang sama.
/// Perintah tombol pemutar di Touch Bar.
enum PlayerCommand: String, CaseIterable {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

final class PlayerReader {
    private(set) var current: Player?
    private var scripts: [Player: NSAppleScript] = [:]
    private var commandScripts: [Player: [PlayerCommand: NSAppleScript]] = [:]

    init() {
        for player in Player.allCases {
            // Batas 3 detik: pemutar yang baru dibuka bisa belum menjawab, dan tanpa batas macOS menunggu
            // sampai 2 menit. Spotify memakai `id`, Music memakai `persistent ID`.
            let idExpression = player == .music ? "persistent ID of currentSong" : "id of currentSong"
            scripts[player] = NSAppleScript(source: """
            with timeout of 3 seconds
                tell application "\(player.name)"
                    set playerStatus to (player state as string)
                    if playerStatus is "stopped" then return "stopped"
                    set currentSong to current track
                    set sep to (character id 31)
                    return playerStatus & sep & (\(idExpression)) & sep & (name of currentSong) & sep & (artist of currentSong) & sep & (album of currentSong) & sep & ((duration of currentSong) as string) & sep & ((player position) as string)
                end tell
            end timeout
            """)
            for command in PlayerCommand.allCases {
                commandScripts[player, default: [:]][command] = NSAppleScript(source: """
                with timeout of 3 seconds
                    tell application "\(player.name)" to \(command.rawValue)
                end timeout
                """)
            }
        }
    }

    func send(_ command: PlayerCommand) {
        guard let player = current, player.runningApp?.isFinishedLaunching == true else { return }
        var error: NSDictionary?
        commandScripts[player]?[command]?.executeAndReturnError(&error)
    }

    func read() -> (PlayerStatus, Player?) {
        let running = Player.allCases.filter { $0.runningApp != nil }
        guard !running.isEmpty else {
            current = nil
            return (.notRunning, nil)
        }
        let results = running.map { ($0, read($0)) }

        // 1. Yang sedang memutar lagu (utamakan pemutar terakhir kalau keduanya memutar).
        let playing = results.filter { $0.1.isPlaying }
        if let pick = playing.first(where: { $0.0 == current }) ?? playing.first {
            current = pick.0
            return (pick.1, pick.0)
        }
        // 2. Pemutar terakhir, kalau masih terbuka.
        if let pick = results.first(where: { $0.0 == current }) { return (pick.1, pick.0) }
        // 3. Pemutar yang punya lagu (dijeda), lalu yang mana saja.
        let pick = results.first(where: { $0.1.hasTrack }) ?? results[0]
        current = pick.0
        return (pick.1, pick.0)
    }

    private func read(_ player: Player) -> PlayerStatus {
        guard let app = player.runningApp else { return .notRunning }
        guard app.isFinishedLaunching else { return .starting }
        guard let script = scripts[player] else { return .failed("AppleScript gagal dibuat") }

        var error: NSDictionary?
        let before = ProcessInfo.processInfo.systemUptime
        let result = script.executeAndReturnError(&error)
        let sampledAt = (before + ProcessInfo.processInfo.systemUptime) / 2

        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { return .denied }
            // -1712: waktu habis, -600/-609: app belum siap menerima perintah.
            if [-1712, -600, -609].contains(code) { return .starting }
            // -1728: Music tidak punya lagu aktif (misalnya baru dibuka).
            if code == -1728 { return .stopped }
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")
        }
        guard let text = result.stringValue else { return .failed("respons kosong") }
        if text == "stopped" { return .stopped }

        let parts = text.components(separatedBy: "\u{1F}")
        guard parts.count == 7 else { return .failed("format respons tidak dikenal") }
        let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        // Spotify memberi durasi dalam milidetik, Music dalam detik.
        let duration = number(parts[5]) / (player == .spotify ? 1000 : 1)
        let id = player == .music ? "music:\(parts[1])" : parts[1]
        let track = Track(id: id, title: parts[2], artist: parts[3], album: parts[4], duration: duration, player: player)
        return .active(track, playing: parts[0] == "playing", position: number(parts[6]), sampledAt: sampledAt)
    }
}

/// Memperkirakan posisi lagu di antara dua pembacaan AppleScript.
struct PlaybackClock {
    private(set) var position: Double = 0
    private(set) var sampledAt: TimeInterval = 0
    private(set) var playing = false

    var now: Double {
        playing ? position + (ProcessInfo.processInfo.systemUptime - sampledAt) : position
    }

    mutating func reset(position: Double, at time: TimeInterval, playing: Bool) {
        self.position = position
        self.sampledAt = time
        self.playing = playing
    }

    /// Posisi dari pemutar bisa sedikit tertinggal, jadi perkiraan hanya dikoreksi
    /// maju, kecuali lagunya jelas digeser mundur (seek).
    mutating func update(position sample: Double, at time: TimeInterval, playing: Bool) {
        guard playing, self.playing else {
            reset(position: sample, at: time, playing: playing)
            return
        }
        let predicted = position + (time - sampledAt)
        if sample > predicted || predicted - sample > 1.5 {
            reset(position: sample, at: time, playing: true)
        }
    }
}

// MARK: - Lirik (file lokal, LRCLIB, NetEase)

struct LyricLine {
    let time: Double
    let text: String
}

enum LRC {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
    /// Baris kredit di lirik NetEase ("作词 : …") bukan bagian lirik.
    private static let credit = try! NSRegularExpression(pattern: #"^(作词|作曲|编曲|制作人|词|曲|混音|母带|和声|吉他|贝斯|鼓)\s*[:：]"#)

    static func parse(_ source: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in source.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let first = matches.first, first.range.location == 0, let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            // File LyricsX (.lrcx) menyimpan terjemahan dan timing per kata sebagai "[waktu][tr:…]"; lewati.
            if text.hasPrefix("[") { continue }
            if credit.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil { continue }
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Tag "[re:…]" dipakai untuk mencatat sumber lirik di cache.
    static func sourceTag(_ source: String) -> String? {
        guard let range = source.range(of: #"(?m)^\[re:([^\]]+)\]"#, options: .regularExpression) else { return nil }
        return String(source[range].dropFirst(4).dropLast())
    }
}

struct Lyrics {
    let lines: [LyricLine]
    let source: String
}

enum LyricsResult {
    case found(Lyrics)
    case notFound
    /// Server tidak bisa dihubungi; jangan dianggap "tidak ada", coba lagi nanti.
    case failed
}

@MainActor
final class LyricsProvider {
    /// Folder untuk file .lrc buatanmu sendiri, dengan nama "Judul - Artis.lrc".
    static let userFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Lyricsbar", isDirectory: true)
    private static let lyricsXFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/LyricsX", isDirectory: true)

    private enum Lookup {
        case lrc(String)
        case none
        case failed
    }

    private enum Fetch<T> {
        case ok(T)
        case notFound
        case failed
    }

    private struct LrclibRecord: Decodable {
        let duration: Double?
        let syncedLyrics: String?
    }

    private struct NeteaseSearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String
            let duration: Int
            let artists: [Artist]
        }
        struct Artist: Decodable { let name: String }
        let result: Result?
    }

    private struct NeteaseLyric: Decodable {
        struct Part: Decodable { let lyric: String? }
        let lrc: Part?
    }

    /// Sumber online yang dipakai, berurutan (mode uji bisa membatasinya).
    var onlineSources = ["LRCLIB", "NetEase"]
    private var memory: [String: LyricsResult] = [:]
    /// Tanpa cookie: NetEase memberi hasil pencarian acak kalau request membawa cookie dari kunjungan sebelumnya.
    private let session = URLSession(configuration: .ephemeral)
    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.touchbarlyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func forget(_ track: Track) {
        memory[track.id] = nil
        try? FileManager.default.removeItem(at: cacheFile(track))
    }

    func lyrics(for track: Track) async -> LyricsResult {
        // File lokal selalu diperiksa dulu, supaya file yang baru kamu tambahkan langsung dipakai.
        if let local = localLyrics(track) { return .found(local) }
        if let cached = memory[track.id] { return cached }
        if let lrc = try? String(contentsOf: cacheFile(track), encoding: .utf8) {
            let result = LyricsResult.found(Lyrics(lines: LRC.parse(lrc), source: LRC.sourceTag(lrc) ?? "LRCLIB"))
            memory[track.id] = result
            return result
        }

        var failed = false
        for (name, source) in [("LRCLIB", lrclib), ("NetEase", netease)] where onlineSources.contains(name) {
            switch await source(track) {
            case .lrc(let lrc):
                let lines = LRC.parse(lrc)
                guard lines.count >= 3 else { continue }
                try? "[re:\(name)]\n\(lrc)".write(to: cacheFile(track), atomically: true, encoding: .utf8)
                let result = LyricsResult.found(Lyrics(lines: lines, source: name))
                memory[track.id] = result
                return result
            case .failed:
                failed = true
            case .none:
                continue
            }
        }
        if failed { return .failed }
        memory[track.id] = .notFound
        return .notFound
    }

    // MARK: File lokal

    private func localLyrics(_ track: Track) -> Lyrics? {
        let wanted = Set([track.title, Self.cleanTitle(track.title)].map { Self.normalize("\($0) - \(Self.primaryArtist(track))") })
        for (folder, name) in [(Self.userFolder, L("file lokal", "local file")), (Self.lyricsXFolder, "LyricsX")] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["lrc", "lrcx"].contains(file.pathExtension.lowercased()) {
                guard wanted.contains(Self.normalize(file.deletingPathExtension().lastPathComponent)),
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let lines = LRC.parse(text)
                if lines.count >= 3 { return Lyrics(lines: lines, source: name) }
            }
        }
        return nil
    }

    // MARK: LRCLIB

    private func lrclib(_ track: Track) async -> Lookup {
        var failed = false
        let exact: Fetch<LrclibRecord> = await getJSON("https://lrclib.net/api/get", [
            "track_name": track.title, "artist_name": track.artist,
            "album_name": track.album, "duration": String(Int(track.duration.rounded())),
        ])
        switch exact {
        case .ok(let record):
            if let lrc = record.syncedLyrics, !lrc.isEmpty { return .lrc(lrc) }
        case .failed:
            failed = true
        case .notFound:
            break
        }

        let title = Self.cleanTitle(track.title)
        let artist = Self.primaryArtist(track)
        var candidates: [LrclibRecord] = []
        for query in [["track_name": title, "artist_name": artist], ["q": "\(title) \(artist)"]] {
            let found: Fetch<[LrclibRecord]> = await getJSON("https://lrclib.net/api/search", query)
            switch found {
            case .ok(let records): candidates += records.filter { !($0.syncedLyrics ?? "").isEmpty }
            case .failed: failed = true
            case .notFound: break
            }
            if let lrc = Self.closest(candidates, to: track.duration, duration: { $0.duration ?? 0 })?.syncedLyrics {
                return .lrc(lrc)
            }
        }
        return failed ? .failed : .none
    }

    // MARK: NetEase

    private static let neteaseHeaders = ["User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"]

    private func netease(_ track: Track) async -> Lookup {
        let title = Self.cleanTitle(track.title)
        let artist = Self.primaryArtist(track)
        let search: Fetch<NeteaseSearch> = await getJSON("https://music.163.com/api/search/get",
                                                          ["s": "\(title) \(artist)", "type": "1", "limit": "10"],
                                                          headers: Self.neteaseHeaders)
        let response: NeteaseSearch
        switch search {
        case .ok(let value): response = value
        case .failed: return .failed
        case .notFound: return .none
        }

        // Judul (setelah dibersihkan) harus sama dan artisnya harus ada, supaya tidak salah lagu.
        let songs = (response.result?.songs ?? []).filter { song in
            Self.normalize(Self.cleanTitle(song.name)) == Self.normalize(title)
                && song.artists.contains { Self.normalize($0.name) == Self.normalize(artist) }
        }
        var remaining = songs
        while let song = Self.closest(remaining, to: track.duration, duration: { Double($0.duration) / 1000 }) {
            remaining.removeAll { $0.id == song.id }
            let lyric: Fetch<NeteaseLyric> = await getJSON("https://music.163.com/api/song/lyric",
                                                           ["id": String(song.id), "lv": "-1", "kv": "-1", "tv": "-1"],
                                                           headers: Self.neteaseHeaders)
            if case .ok(let result) = lyric, let lrc = result.lrc?.lyric, LRC.parse(lrc).count >= 3 {
                return .lrc(lrc)
            }
            if case .failed = lyric { return .failed }
        }
        return .none
    }

    // MARK: Bantuan

    /// Pilih versi dengan durasi terdekat: utamakan selisih ≤ 8 detik, kalau tidak ada terima sampai 25 detik
    /// (banyak lirik lagu Indonesia dibuat dari versi yang sedikit berbeda; sisanya bisa diatur dengan offset).
    private static func closest<T>(_ items: [T], to target: Double, duration: (T) -> Double) -> T? {
        let ranked = items.map { (item: $0, diff: abs(duration($0) - target)) }.sorted { $0.diff < $1.diff }
        guard let best = ranked.first, best.diff <= 25 else { return nil }
        return best.item
    }

    /// GET JSON dengan satu kali coba ulang untuk error server (5xx, 429, timeout).
    private func getJSON<T: Decodable>(_ base: String, _ query: [String: String],
                                       headers: [String: String] = ["User-Agent": "Lyricsbar/1.0"]) async -> Fetch<T> {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            guard let (data, response) = try? await session.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
                return .ok(value)
            }
            if status < 500 && status != 429 { return .notFound }
        }
        return .failed
    }

    private func cacheFile(_ track: Track) -> URL {
        let name = track.id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        return cacheDir.appendingPathComponent(name + ".lrc")
    }

    private static func primaryArtist(_ track: Track) -> String {
        track.artist.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
    }

    /// Untuk membandingkan judul/nama: huruf kecil, tanpa aksen dan tanda baca.
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// "Lagu (feat. X) - Remastered 2011" → "Lagu"
    static func cleanTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[\(\[](feat\.?|ft\.?|with|from|remaster)[^\)\]]*[\)\]]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Touch Bar (API privat DFRFoundation)

/// Touch Bar "system modal" supaya lirik tetap terlihat saat app lain sedang aktif.
/// Ini API privat Apple (dipakai juga oleh LyricsX, MTMR, Pock), jadi bisa berubah di macOS berikutnya.
enum SystemTouchBar {
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let dfr, let sym = dlsym(dfr, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ visible: Bool) {
        typealias Fn = @convention(c) (NSString, Bool) -> Void
        symbol("DFRElementSetControlStripPresenceForIdentifier", as: Fn.self)?(id.rawValue as NSString, visible)
    }

    static func showsCloseBox(_ show: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        symbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: Fn.self)?(show)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        let cls: AnyObject = NSTouchBarItem.self
        let sel = NSSelectorFromString("addSystemTrayItem:")
        if cls.responds(to: sel) { _ = cls.perform(sel, with: item) }
    }

    static func present(_ bar: NSTouchBar, trayItem id: NSTouchBarItem.Identifier) {
        let cls: AnyObject = NSTouchBar.self
        // Varian dengan "placement": nilai 1 menampilkan bar tanpa tombol X di kiri.
        let withPlacement = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        if cls.responds(to: withPlacement), let imp = (cls as? NSObject.Type)?.method(for: withPlacement) {
            typealias Fn = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void
            unsafeBitCast(imp, to: Fn.self)(cls, withPlacement, bar, 1, id.rawValue as NSString)
            return
        }
        for name in ["presentSystemModalTouchBar:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:systemTrayItemIdentifier:"] {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) {
                _ = cls.perform(sel, with: bar, with: id.rawValue as NSString)
                return
            }
        }
    }

    /// Menyembunyikan bar ke Control Strip (ikon ♪); Touch Bar app yang sedang aktif tampil lagi.
    static func minimize(_ bar: NSTouchBar) {
        let cls: AnyObject = NSTouchBar.self
        for name in ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:"] {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) {
                _ = cls.perform(sel, with: bar)
                return
            }
        }
    }

    /// Menutup bar sepenuhnya (tanpa menyisakan ikon di Control Strip).
    static func dismiss(_ bar: NSTouchBar) {
        let cls: AnyObject = NSTouchBar.self
        for name in ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
            let sel = NSSelectorFromString(name)
            if cls.responds(to: sel) {
                _ = cls.perform(sel, with: bar)
                return
            }
        }
        minimize(bar)
    }

    static var isAvailable: Bool {
        (NSTouchBar.self as AnyObject).responds(to: NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
    }
}

// MARK: - Kontrol sistem (pengganti Control Strip)

/// Kecerahan layar bawaan dan volume output, tanpa izin tambahan.
enum SystemControls {
    // Kecerahan lewat DisplayServices (framework privat yang juga dipakai Control Strip).
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    /// Layar bawaan MacBook. Layar utama bisa saja monitor eksternal yang tidak bisa diatur dari sini.
    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var brightness: Float? {
        get {
            typealias Fn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
            guard let display = builtInDisplay, let ds = displayServices,
                  let sym = dlsym(ds, "DisplayServicesGetBrightness") else { return nil }
            var value: Float = 0
            return unsafeBitCast(sym, to: Fn.self)(display, &value) == 0 ? value : nil
        }
        set {
            typealias Fn = @convention(c) (UInt32, Float) -> Int32
            guard let newValue, let display = builtInDisplay, let ds = displayServices,
                  let sym = dlsym(ds, "DisplayServicesSetBrightness") else { return }
            _ = unsafeBitCast(sym, to: Fn.self)(display, min(1, max(0, newValue)))
        }
    }

    static var volume: Float? {
        get { outputProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, as: Float32.self) }
        set { if let newValue { setOutputProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(min(1, max(0, newValue)))) } }
    }

    static var muted: Bool {
        get { (outputProperty(kAudioDevicePropertyMute, as: UInt32.self) ?? 0) != 0 }
        set { setOutputProperty(kAudioDevicePropertyMute, UInt32(newValue ? 1 : 0)) }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputProperty<T>(_ selector: AudioObjectPropertySelector, as _: T.Type) -> T? {
        guard let device = defaultOutput() else { return nil }
        var address = outputAddress(selector)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func setOutputProperty<T>(_ selector: AudioObjectPropertySelector, _ value: T) {
        guard let device = defaultOutput() else { return }
        var address = outputAddress(selector)
        var value = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}

// MARK: - Touch Bar lirik

enum LyricAlignment: String, CaseIterable {
    case left, center, right

    var title: String {
        switch self {
        case .left: return L("Rata kiri", "Left")
        case .center: return L("Rata tengah", "Center")
        case .right: return L("Rata kanan", "Right")
        }
    }

    var textAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum LyricAnimation: String, CaseIterable {
    case slideUp, fade, none

    var title: String {
        switch self {
        case .slideUp: return L("Geser ke atas", "Slide up")
        case .fade: return L("Pudar", "Fade")
        case .none: return L("Tanpa animasi", "No animation")
        }
    }
}

/// Slider bergaya Liquid Glass ala Apple: jalur tipis polos, isi warna aksen sistem (mengikuti tema di
/// System Settings › Appearance), dan knob kapsul "kaca" dengan garis tepi putih tipis dan bayangan lembut.
/// Touch Bar berlatar hitam tanpa apa pun di belakangnya untuk diburamkan, jadi efek kacanya digambar sendiri.
///
/// Saat disentuh, knob meniru perilaku Liquid Glass: membesar dengan pegas, berubah bening seperti lensa
/// (jalur di bawahnya tampak membesar), dan sedikit melar ke arah gerakan saat digeser cepat.
final class GlassSliderCell: NSSliderCell {
    private let trackHeight: CGFloat = 6
    private let knobWidth: CGFloat = 32
    private let knobHeight: CGFloat = 21

    /// 0 = diam, 1 = ditekan penuh (boleh sedikit lewat dari 1 karena pantulan pegas).
    private var press: CGFloat = 0
    private var pressVelocity: CGFloat = 0
    private var pressTarget: CGFloat = 0
    /// Seberapa melar knob karena kecepatan geser (0 = bulat normal).
    private var stretch: CGFloat = 0
    private var lastDrag: (x: CGFloat, time: TimeInterval)?
    private var animationTimer: Timer?

    private var progress: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((doubleValue - minValue) / (maxValue - minValue))
    }

    /// Titik tengah knob; jarak tempuhnya dihitung dari ukuran diam supaya posisi tidak bergeser saat membesar.
    private func knobCenter(flipped: Bool) -> NSPoint {
        let bar = barRect(flipped: flipped)
        return NSPoint(x: bar.minX + knobWidth / 2 + (bar.width - knobWidth) * progress, y: bar.midY)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let center = knobCenter(flipped: flipped)
        let grow = 1 + 0.32 * press
        let width = knobWidth * grow * (1 + stretch)
        let height = min(28, knobHeight * grow * (1 - stretch * 0.35))
        return NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    // MARK: Sentuhan

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        pressTarget = 1
        lastDrag = (startPoint.x, ProcessInfo.processInfo.systemUptime)
        startAnimating()
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastDrag, now > last.time {
            let speed = abs(currentPoint.x - last.x) / CGFloat(now - last.time) // pt per detik
            stretch = max(stretch, min(0.28, speed / 2500))
        }
        lastDrag = (currentPoint.x, now)
        startAnimating()
        return super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        pressTarget = 0
        lastDrag = nil
        startAnimating()
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    }

    /// Pegas sederhana 60 fps; berhenti sendiri begitu diam. Mode .common supaya tetap jalan selama slider digeser.
    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.pressVelocity = self.pressVelocity * 0.70 + (self.pressTarget - self.press) * 0.24
            self.press += self.pressVelocity
            self.stretch *= 0.84
            if abs(self.pressTarget - self.press) < 0.002, abs(self.pressVelocity) < 0.002, self.stretch < 0.002 {
                self.press = self.pressTarget
                self.pressVelocity = 0
                self.stretch = 0
                timer.invalidate()
                self.animationTimer = nil
            }
            self.controlView?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    // MARK: Gambar

    private func drawTrack(in rect: NSRect, height: CGFloat, fillUntil x: CGFloat) {
        let track = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let radius = height / 2
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let filled = NSRect(x: track.minX, y: track.minY, width: max(height, x - track.minX), height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // Isi warna aksen dari tepi kiri sampai tengah knob.
        drawTrack(in: rect, height: trackHeight, fillUntil: knobCenter(flipped: flipped).x)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let flipped = controlView?.isFlipped == true
        let p = max(0, min(1.1, press))
        let capsule = knobRect.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)

        // Bayangan: makin lebar dan samar saat ditekan, seperti kaca terangkat.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45 - 0.15 * p)
        shadow.shadowBlurRadius = 6 + 5 * p
        shadow.shadowOffset = NSSize(width: 0, height: -1.5 - 1.5 * p)
        shadow.set()
        NSColor(white: 0.86, alpha: 1 - 0.8 * p).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Lensa: jalur di bawah knob tampak lebih tebal (membesar) di dalam kaca saat ditekan.
        if p > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGraphicsContext.current?.cgContext.setAlpha(min(1, p))
            let bar = barRect(flipped: flipped)
            drawTrack(in: NSRect(x: bar.minX, y: bar.midY - 10, width: bar.width, height: 20),
                      height: trackHeight * (1 + 0.9 * p), fillUntil: knobCenter(flipped: flipped).x)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Badan kaca: gradasi putih pekat saat diam, memudar menjadi lapisan putih tipis yang rata saat ditekan
        // (gradasi abu-abu yang sangat tipis di atas hitam menimbulkan garis-garis, jadi tidak dipakai).
        let solid = max(0, 1 - p)
        if solid > 0.01 {
            NSGradient(starting: NSColor(white: 0.93, alpha: solid), ending: NSColor(white: 0.80, alpha: solid))!
                .draw(in: path, angle: flipped ? 90 : -90)
        }
        NSColor.white.withAlphaComponent(0.10 * min(1, p)).setFill()
        path.fill()

        // Pantulan cahaya: menutupi bagian atas saat diam, menjadi kilau tipis di tepi atas saat ditekan.
        let inner = capsule.insetBy(dx: 1.5, dy: 1.5)
        let shineHeight = inner.height * (0.9 - 0.45 * min(1, p))
        let shine = NSRect(x: inner.minX + inner.height * 0.15 * p, y: flipped ? inner.minY : inner.maxY - shineHeight,
                           width: inner.width - inner.height * 0.3 * p, height: shineHeight)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.55), ending: NSColor.white.withAlphaComponent(0))!
            .draw(in: NSBezierPath(roundedRect: shine, xRadius: shine.height / 2, yRadius: shine.height / 2),
                  angle: flipped ? 90 : -90)

        // Cahaya lembut di sepanjang tepi dalam, seperti cahaya yang terbias di pinggir kaca.
        if p > 0.01 {
            let glow = NSBezierPath(roundedRect: capsule.insetBy(dx: 2, dy: 2),
                                    xRadius: (capsule.height - 4) / 2, yRadius: (capsule.height - 4) / 2)
            NSColor.white.withAlphaComponent(0.28 * min(1, p)).setStroke()
            glow.lineWidth = 1.5
            glow.stroke()
        }

        // Garis tepi putih tipis; sedikit lebih tebal saat ditekan supaya bentuk kaca tetap terbaca.
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 1 + 0.4 * p
        path.stroke()
    }

}

/// Baris slider yang rapi: ikon kecil, slider, ikon besar, lalu persentase, tanpa kotak label abu-abu
/// bawaan NSSliderTouchBarItem.
@MainActor
final class SliderRowItem: NSCustomTouchBarItem {
    var onChange: ((Float) -> Void)?

    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "0%")

    init(identifier: NSTouchBarItem.Identifier, label: String, low: String, high: String) {
        super.init(identifier: identifier)
        customizationLabel = label

        slider.cell = GlassSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        // Setinggi Touch Bar supaya knob tidak terpotong; lebarnya mengisi sisa baris.
        slider.heightAnchor.constraint(equalToConstant: 30).isActive = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        percent.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stack = NSStackView(views: [Self.icon(low), slider, Self.icon(high), percent])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        // Selebar ruang di antara logo Spotify dan tombol Selesai (Touch Bar ±1000 pt).
        stack.widthAnchor.constraint(equalToConstant: 840).isActive = true
        view = stack
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            updatePercent()
        }
    }

    private static func icon(_ symbol: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        view.contentTintColor = .secondaryLabelColor
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private func updatePercent() {
        percent.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
    }

    @objc private func changed() {
        updatePercent()
        onChange?(Float(slider.doubleValue))
    }
}

@MainActor
final class LyricsTouchBar: NSObject, NSTouchBarDelegate {
    static let trayID = NSTouchBarItem.Identifier("local.touchbarlyrics.tray")
    static let logoID = NSTouchBarItem.Identifier("local.touchbarlyrics.logo")
    static let lyricID = NSTouchBarItem.Identifier("local.touchbarlyrics.lyric")
    static let brightnessID = NSTouchBarItem.Identifier("local.touchbarlyrics.brightness")
    static let volumeID = NSTouchBarItem.Identifier("local.touchbarlyrics.volume")
    static let muteID = NSTouchBarItem.Identifier("local.touchbarlyrics.mute")
    static let playPauseID = NSTouchBarItem.Identifier("local.touchbarlyrics.playpause")
    static let previousID = NSTouchBarItem.Identifier("local.touchbarlyrics.previous")
    static let nextID = NSTouchBarItem.Identifier("local.touchbarlyrics.next")
    static let doneID = NSTouchBarItem.Identifier("local.touchbarlyrics.done")
    static let emojiID = NSTouchBarItem.Identifier("local.touchbarlyrics.emoji")

    /// Isi Touch Bar: lirik + kontrol, atau satu slider lebar (kecerahan/volume).
    enum Mode {
        case lyrics, brightness, volume
    }

    var animation = LyricAnimation.slideUp
    var alignment = LyricAlignment.center {
        didSet { label.alignment = alignment.textAlignment }
    }
    var onCommand: ((PlayerCommand) -> Void)?
    /// Dipakai saat kembali dari mode emoji: bar lirik hanya muncul lagi kalau lagu sedang diputar.
    var canShow: () -> Bool = { true }
    /// Dipanggil tepat sebelum bar lirik tampil (untuk menutup wallpaper).
    var onPresent: (() -> Void)?
    /// Apakah bar lirik sedang tampil (bukan Touch Bar bawaan / Touch Bar app).
    private(set) var isShown = false
    /// Touch Bar app sedang ditampilkan sementara lewat tombol emoji.
    private(set) var isShowingAppBar = false

    private let bar = NSTouchBar()
    private let container = NSView()
    private let label = NSTextField(labelWithString: "♪")
    /// Touch Bar ±1000 pt; sisanya untuk logo dan 7 tombol kontrol (48 pt) di kanan.
    /// Item yang tidak muat akan disembunyikan sistem.
    private let width: CGFloat = 550
    private var shown: String?

    private let brightnessSlider = SliderRowItem(identifier: NSTouchBarItem.Identifier("local.touchbarlyrics.brightness.slider"),
                                                 label: L("Kecerahan", "Brightness"), low: "sun.min", high: "sun.max")
    private let volumeSlider = SliderRowItem(identifier: NSTouchBarItem.Identifier("local.touchbarlyrics.volume.slider"),
                                             label: "Volume", low: "speaker.fill", high: "speaker.wave.3.fill")
    private var muteButton: NSButton?
    private var playPauseButton: NSButton?
    private var isPlaying = false
    /// Simbol yang sedang tampil di tombol; nil = tombol baru dibuat dan belum diberi ikon yang benar.
    private var shownPlaySymbol: String?
    private var shownMuteSymbol: String?

    override init() {
        super.init()
        bar.delegate = self
        setMode(.lyrics)

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        brightnessSlider.onChange = { [weak self] in
            SystemControls.brightness = $0
            self?.scheduleReturnToLyrics()
        }
        volumeSlider.onChange = { [weak self] in
            SystemControls.volume = $0
            if $0 > 0, SystemControls.muted { SystemControls.muted = false }
            self?.scheduleReturnToLyrics()
        }

        let tray = NSCustomTouchBarItem(identifier: Self.trayID)
        let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: L("Lirik", "Lyrics"))!
        tray.view = NSButton(image: icon, target: self, action: #selector(present))
        SystemTouchBar.addSystemTrayItem(tray)
        SystemTouchBar.setControlStripPresence(Self.trayID, true)
    }

    @objc func present() {
        onPresent?()
        returnTimer?.invalidate()
        isShowingAppBar = false
        refreshControls()
        SystemTouchBar.present(bar, trayItem: Self.trayID)
        isShown = true
    }

    /// Kembali ke Touch Bar bawaan (Control Strip dan Touch Bar app yang aktif).
    func hide() {
        returnTimer?.invalidate()
        isShowingAppBar = false
        if isShown { SystemTouchBar.minimize(bar) }
        isShown = false
    }

    /// Ikon ♪ di Control Strip; disembunyikan saat Spotify dan Music tidak berjalan.
    func setTrayVisible(_ visible: Bool) {
        SystemTouchBar.setControlStripPresence(Self.trayID, visible)
    }

    // MARK: Item

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.logoID:
            // Ikon app pemutar yang sedang dipakai; ketuk untuk membuka app itu.
            let button = NSButton(image: Self.icon(for: player) ?? NSImage(), target: self, action: #selector(openPlayer))
            button.isBordered = false
            button.imagePosition = .imageOnly
            logoButton = button
            return custom(id, button)

        case Self.lyricID:
            container.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: width),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return custom(id, container)

        case Self.brightnessID:
            return custom(id, controlButton("sun.max.fill", L("Kecerahan", "Brightness"), #selector(showBrightness)))

        case Self.volumeID:
            let button = controlButton("speaker.wave.2.fill", "Volume", #selector(showVolume))
            volumeButton = button
            return custom(id, button)

        case brightnessSlider.identifier:
            return brightnessSlider

        case volumeSlider.identifier:
            return volumeSlider

        case Self.doneID:
            let button = NSButton(title: L("Selesai", "Done"), target: self, action: #selector(showLyrics))
            doneButton = button
            return custom(id, button)

        case Self.muteID:
            let button = controlButton("speaker.fill", L("Bisukan", "Mute"), #selector(toggleMute))
            muteButton = button
            shownMuteSymbol = nil
            return custom(id, button)

        case Self.emojiID:
            return custom(id, controlButton("face.smiling", "Emoji", #selector(showAppTouchBar)))

        case Self.previousID:
            return custom(id, controlButton("backward.fill", L("Lagu sebelumnya", "Previous track"), #selector(previousTrack)))

        case Self.nextID:
            return custom(id, controlButton("forward.fill", L("Lagu berikutnya", "Next track"), #selector(nextTrack)))

        case Self.playPauseID:
            let button = controlButton("play.fill", L("Putar/Jeda", "Play/Pause"), #selector(playPause))
            playPauseButton = button
            shownPlaySymbol = nil
            return custom(id, button)

        default:
            return nil
        }
    }

    private func custom(_ id: NSTouchBarItem.Identifier, _ view: NSView) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = view
        return item
    }

    private func controlButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: self, action: action)
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return button
    }

    private var volumeButton: NSButton?
    private var doneButton: NSButton?

    /// Tombol Touch Bar yang bertuliskan teks dibuat sekali, jadi teksnya diganti saat bahasa berubah.
    func languageChanged() {
        doneButton?.title = L("Selesai", "Done")
    }
    private var modeTimer: Timer?

    func setMode(_ mode: Mode) {
        refreshControls()
        switch mode {
        case .lyrics:
            modeTimer?.invalidate()
            bar.defaultItemIdentifiers = [Self.logoID, .fixedSpaceSmall, Self.lyricID, .flexibleSpace,
                                          Self.emojiID, Self.brightnessID, Self.volumeID, Self.muteID,
                                          Self.previousID, Self.playPauseID, Self.nextID]
        case .brightness:
            bar.defaultItemIdentifiers = [Self.logoID, .fixedSpaceSmall, brightnessSlider.identifier, .flexibleSpace, Self.doneID]
            scheduleReturnToLyrics()
        case .volume:
            bar.defaultItemIdentifiers = [Self.logoID, .fixedSpaceSmall, volumeSlider.identifier, .flexibleSpace, Self.doneID]
            scheduleReturnToLyrics()
        }
    }

    /// Kembali ke lirik setelah 4 detik slider tidak disentuh.
    private func scheduleReturnToLyrics() {
        modeTimer?.invalidate()
        modeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setMode(.lyrics) }
        }
    }

    @objc private func showBrightness() { setMode(.brightness) }
    @objc private func showVolume() { setMode(.volume) }
    @objc private func showLyrics() { setMode(.lyrics) }

    @objc private func toggleMute() {
        SystemControls.muted.toggle()
        refreshControls()
    }

    @objc private func playPause() { onCommand?(.playPause) }
    @objc private func previousTrack() { onCommand?(.previous) }
    @objc private func nextTrack() { onCommand?(.next) }

    private var returnTimer: Timer?

    /// Pemilih emoji (dan saran ketikan) adalah bagian dari Touch Bar app tempat kamu mengetik,
    /// jadi bar lirik disembunyikan sementara. Ikon ♪ tidak selalu tampil di Control Strip ringkas,
    /// jadi lirik kembali sendiri setelah 8 detik tanpa ketikan. Gerakan mouse/trackpad tidak dihitung:
    /// sensor bisa terus mengirim gerakan kecil sehingga Mac tidak pernah terhitung "diam".
    @objc func showAppTouchBar() {
        SystemTouchBar.minimize(bar)
        isShown = false
        isShowingAppBar = true
        let hiddenAt = Date()
        returnTimer?.invalidate()
        returnTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            // Waktu sejak tombol terakhir ditekan; tidak butuh izin apa pun.
            let sinceTyping = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            guard Date().timeIntervalSince(hiddenAt) > 8, sinceTyping > 8 else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isShowingAppBar = false
                if self.canShow() { self.present() }
            }
        }
    }

    // MARK: Pemutar aktif

    private var player = Player.spotify
    private var logoButton: NSButton?

    /// Mengganti logo di kiri ke pemutar yang sedang dipakai (Spotify atau Music).
    func setPlayer(_ newPlayer: Player) {
        guard newPlayer != player else { return }
        player = newPlayer
        logoButton?.image = Self.icon(for: newPlayer)
    }

    private static func icon(for player: Player) -> NSImage? {
        guard let url = player.appURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 26, height: 26)
        return icon
    }

    @objc private func openPlayer() {
        guard let url = player.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Status

    /// Menyamakan slider dan ikon dengan kondisi sistem (bisa berubah dari keyboard atau menu bar).
    func refreshControls(playing: Bool? = nil) {
        if let brightness = SystemControls.brightness { brightnessSlider.value = Double(brightness) }
        // Sebagian output (misalnya HDMI) tidak bisa diatur volumenya oleh macOS; tombolnya dinonaktifkan,
        // sama seperti Control Strip bawaan.
        let volume = SystemControls.volume
        if let volume { volumeSlider.value = Double(volume) }
        volumeButton?.isEnabled = volume != nil
        muteButton?.isEnabled = volume != nil

        let muted = volume != nil && SystemControls.muted
        let muteSymbol = muted ? "speaker.slash.fill" : "speaker.fill"
        if let muteButton, muteSymbol != shownMuteSymbol {
            shownMuteSymbol = muteSymbol
            muteButton.image = NSImage(systemSymbolName: muteSymbol, accessibilityDescription: L("Bisukan", "Mute"))
            muteButton.bezelColor = muted ? .systemRed : nil
        }

        if let playing { isPlaying = playing }
        let playSymbol = isPlaying ? "pause.fill" : "play.fill"
        if let playPauseButton, playSymbol != shownPlaySymbol {
            shownPlaySymbol = playSymbol
            playPauseButton.image = NSImage(systemSymbolName: playSymbol, accessibilityDescription: L("Putar/Jeda", "Play/Pause"))
        }
    }

    /// Menampilkan satu baris; font dikecilkan sampai muat, baru dipotong kalau masih terlalu panjang.
    func show(_ text: String, dimmed: Bool = false) {
        let key = (dimmed ? "0" : "1") + text
        guard key != shown else { return }
        shown = key

        var size: CGFloat = 16
        while size > 11,
              (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width > width {
            size -= 1
        }
        // Transisi dipasang di container (tidak flipped), jadi "fromBottom" memang dari bawah:
        // baris lama terdorong ke atas, baris baru naik dari bawah seperti lirik Spotify.
        let duration = UserDefaults.standard.double(forKey: "animationDuration")
        switch animation {
        case .slideUp:
            let push = CATransition()
            push.type = .push
            push.subtype = .fromBottom
            push.duration = duration > 0 ? duration : 0.32
            push.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.layer?.add(push, forKey: "lyric")
        case .fade:
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration > 0 ? duration : 0.2
            container.layer?.add(fade, forKey: "lyric")
        case .none:
            break
        }
        label.font = .systemFont(ofSize: size, weight: dimmed ? .regular : .medium)
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        label.stringValue = text
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = PlayerReader()
    /// Pemutar yang sedang dipakai (yang terakhir memutar lagu).
    private var player: Player?
    private let provider = LyricsProvider()
    private var touchBar: LyricsTouchBar!
    private var wallpaper: IdleWallpaper!
    private var statusItem: NSStatusItem!

    private var track: Track?
    private var lines: [LyricLine] = []
    private var loading = false
    private var lookupFailed = false
    private var lyricsSource = ""
    private var clock = PlaybackClock()
    private var message = L("Menunggu pemutar musik…", "Waiting for a music player…")

    private var alignment: LyricAlignment {
        get { LyricAlignment(rawValue: UserDefaults.standard.string(forKey: "alignment") ?? "") ?? .center }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "alignment")
            touchBar.alignment = newValue
        }
    }

    private var animation: LyricAnimation {
        get { LyricAnimation(rawValue: UserDefaults.standard.string(forKey: "animation") ?? "") ?? .slideUp }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "animation")
            touchBar.animation = newValue
        }
    }

    private var showInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: "showInMenuBar") }
        set { UserDefaults.standard.set(newValue, forKey: "showInMenuBar") }
    }

    /// Offset per lagu dalam detik; positif = lirik muncul lebih awal.
    private var offset: Double {
        get { track.flatMap { offsets[$0.id] } ?? 0 }
        set {
            guard let track else { return }
            var all = offsets
            all[track.id] = abs(newValue) < 0.01 ? nil : newValue
            UserDefaults.standard.set(all, forKey: "offsets")
        }
    }
    private var offsets: [String: Double] {
        UserDefaults.standard.dictionary(forKey: "offsets") as? [String: Double] ?? [:]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: L("Lirik", "Lyrics"))
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // `open -a Lyricsbar --args --enable-login-item` mengaktifkan "Buka saat login" tanpa lewat menu.
        // Daftar ulang supaya login item menunjuk ke lokasi app yang sedang jalan (misalnya /Applications),
        // bukan salinan lain dengan bundle ID yang sama.
        if CommandLine.arguments.contains("--enable-login-item") {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }

        touchBar = LyricsTouchBar()
        touchBar.animation = animation
        touchBar.alignment = alignment
        touchBar.onCommand = { [weak self] command in
            guard let self else { return }
            playerQueue.async { [reader] in
                reader.send(command)
                DispatchQueue.main.async { self.poll() }
            }
        }
        touchBar.show(message, dimmed: true)
        touchBar.canShow = { [weak self] in self?.wasPlaying == true }

        // Wallpaper hanya muncul sendiri saat lirik tidak tampil; setelah ditutup, lirik kembali kalau lagu masih diputar.
        wallpaper = IdleWallpaper()
        wallpaper.canShow = { [weak self] in
            guard let self else { return false }
            return self.wasPlaying != true && !self.touchBar.isShown && !self.touchBar.isShowingAppBar
        }
        wallpaper.onDismiss = { [weak self] in
            guard let self, self.wasPlaying == true, !self.touchBar.isShown, !self.touchBar.isShowingAppBar else { return }
            self.touchBar.present()
        }
        touchBar.onPresent = { [weak self] in self?.wallpaper.hide() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Untuk uji tampilan: Lyricsbar --show-wallpaper <tema> [--wallpaper-text <teks>]
            if let i = CommandLine.arguments.firstIndex(of: "--show-wallpaper") {
                let args = CommandLine.arguments
                if let j = args.firstIndex(of: "--wallpaper-text"), args.count > j + 1 { WallpaperTheme.customText = args[j + 1] }
                if args.count > i + 1, let theme = WallpaperTheme(rawValue: args[i + 1]) { self.wallpaper.theme = theme }
                self.wallpaper.preview()
            }
            // Untuk uji tampilan: buka langsung mode slider.
            let testArgs = ["--show-brightness", "--show-volume", "--show-app-bar"]
            if testArgs.contains(where: CommandLine.arguments.contains) { self.touchBar.present() }
            if CommandLine.arguments.contains("--show-brightness") { self.touchBar.setMode(.brightness) }
            if CommandLine.arguments.contains("--show-volume") { self.touchBar.setMode(.volume) }
            if CommandLine.arguments.contains("--show-app-bar") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.touchBar.showAppTouchBar() }
            }
        }

        schedule(every: 0.5) { $0.poll() }
        schedule(every: 1.0 / 30) { $0.render() }
        poll()
    }

    private func schedule(every interval: TimeInterval, _ body: @escaping (AppDelegate) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Status pemutaran

    /// AppleScript dijalankan di antrean sendiri supaya Touch Bar tidak macet
    /// (misalnya saat dialog izin Automation sedang terbuka).
    private let playerQueue = DispatchQueue(label: "local.touchbarlyrics.player")
    private var polling = false

    private func poll() {
        guard !polling else { return }
        polling = true
        playerQueue.async { [reader] in
            let (status, player) = reader.read()
            DispatchQueue.main.async {
                self.polling = false
                if player != self.player, let player {
                    self.player = player
                    self.touchBar.setPlayer(player)
                }
                self.apply(status)
                self.touchBar.refreshControls(playing: self.track != nil && self.clock.playing)
                self.updateVisibility(for: status)
            }
        }
    }

    // MARK: Tampil / sembunyi

    /// nil = belum diketahui (baru dibuka atau baru bangun dari mode tidur).
    private var wasPlaying: Bool?
    private var dormant = false
    private var hideWork: DispatchWorkItem?

    /// Spotify dan Music ditutup → mode tidur (Touch Bar bawaan, ikon menu bar hilang). Pemutar terbuka tapi tidak
    /// memutar lagu selama 5 detik → Touch Bar bawaan. Lagu diputar → bar lirik tampil.
    private func updateVisibility(for status: PlayerStatus) {
        if case .notRunning = status {
            if !dormant { enterDormant() }
            return
        }
        if dormant { leaveDormant() }

        let playing = track != nil && clock.playing
        guard playing != wasPlaying else { return }
        wasPlaying = playing
        hideWork?.cancel()
        if playing {
            if !touchBar.isShown, !touchBar.isShowingAppBar { touchBar.present() }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.wasPlaying == false else { return }
                self.touchBar.hide()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    /// Terlihat seperti app keluar, tapi tetap berjalan supaya bisa aktif lagi sendiri saat pemutar dibuka
    /// (login item hanya dijalankan sekali saat login).
    private func enterDormant() {
        dormant = true
        wasPlaying = nil
        hideWork?.cancel()
        touchBar.hide()
        touchBar.setTrayVisible(false)
        statusItem.menu?.cancelTracking()
        statusItem.isVisible = false
    }

    private func leaveDormant() {
        dormant = false
        statusItem.isVisible = true
        touchBar.setTrayVisible(true)
    }

    private var playerName: String { player?.name ?? L("Pemutar musik", "Music player") }

    private func apply(_ status: PlayerStatus) {
        switch status {
        case .notRunning:
            setTrack(nil, message: L("Spotify dan Music tidak berjalan", "Spotify and Music aren't running"))
        case .starting:
            setTrack(nil, message: L("\(playerName) sedang dibuka…", "\(playerName) is opening…"))
        case .stopped:
            setTrack(nil, message: L("\(playerName) berhenti", "\(playerName) is stopped"))
        case .denied:
            setTrack(nil, message: L("Izinkan akses ke \(playerName): System Settings › Privacy & Security › Automation", "Allow access to \(playerName): System Settings › Privacy & Security › Automation"))
        case .failed(let reason):
            setTrack(nil, message: L("Gagal membaca \(playerName): \(reason)", "Couldn't read \(playerName): \(reason)"))
        case let .active(current, playing, position, sampledAt):
            if UserDefaults.standard.bool(forKey: "debug") {
                let entry = String(format: "%@ playing=%d pos=%.2f clock=%.2f lines=%d loading=%d first=%.2f\n",
                                   current.id, playing ? 1 : 0, position, clock.now, lines.count, loading ? 1 : 0, lines.first?.time ?? -1)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("touchbarlyrics-debug.log")
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(entry.data(using: .utf8)!)
                    try? handle.close()
                } else {
                    try? entry.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            if current != track {
                setTrack(current, message: "")
                clock.reset(position: position, at: sampledAt, playing: playing)
            } else {
                clock.update(position: position, at: sampledAt, playing: playing)
            }
        }
    }

    private func setTrack(_ newTrack: Track?, message: String) {
        self.message = message
        guard newTrack != track else { return }
        track = newTrack
        lines = []
        guard let newTrack else { return }
        loadLyrics(for: newTrack)
    }

    private func loadLyrics(for target: Track) {
        loading = true
        Task {
            let result = await provider.lyrics(for: target)
            guard target == track else { return }
            loading = false
            switch result {
            case .found(let lyrics):
                lines = lyrics.lines
                lyricsSource = lyrics.source
                lookupFailed = false
            case .notFound:
                lines = []
                lookupFailed = false
            case .failed:
                // Server lirik sedang bermasalah: coba lagi sebentar lagi, jangan dianggap tidak ada.
                lines = []
                lookupFailed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    if self.track == target, self.lines.isEmpty, !self.loading { self.loadLyrics(for: target) }
                }
            }
        }
    }

    // MARK: Tampilan

    private func currentLine() -> (text: String, dimmed: Bool) {
        guard let track else { return (message, true) }
        let nowPlaying = "♪  \(track.title) — \(track.artist)"
        if loading { return (nowPlaying, true) }
        if lines.isEmpty { return (nowPlaying + (lookupFailed ? "" : L("  ·  lirik tidak ditemukan", "  ·  lyrics not found")), true) }

        let t = clock.now + offset
        // Pencarian biner: baris terakhir yang waktunya <= t.
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return (nowPlaying, true) }
        let text = lines[lo - 1].text
        return text.isEmpty ? ("♪", true) : (text, false)
    }

    private func render() {
        let line = currentLine()
        touchBar.show(line.text, dimmed: line.dimmed)
        renderMenuBar(line.text)
    }

    private var menuBarKey: String?
    private let menuBarLabel = NSTextField(labelWithString: "")
    private let menuBarIcon = NSImageView()
    private static let noteIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: L("Lirik", "Lyrics"))
        image?.isTemplate = true
        return image
    }()

    /// Lirik di menu bar memakai area selebar tetap supaya perataan kiri/tengah/kanan terlihat;
    /// ikon ♪ tetap di kiri, teks yang terlalu panjang dipotong dengan "…".
    private func renderMenuBar(_ text: String) {
        guard let button = statusItem.button else { return }
        let key = showInMenuBar ? alignment.rawValue + text : ""
        guard key != menuBarKey else { return }
        menuBarKey = key

        guard showInMenuBar else {
            statusItem.length = NSStatusItem.variableLength
            menuBarLabel.isHidden = true
            menuBarIcon.isHidden = true
            button.image = Self.noteIcon
            return
        }
        // Judul dan ikon tombol menu bar selalu ditaruh di tengah oleh macOS, jadi ikon ♪ dan lirik
        // memakai view sendiri: ikon terkunci di kiri, lirik di sebelahnya dengan perataan pilihan.
        if menuBarLabel.superview == nil {
            menuBarIcon.image = Self.noteIcon
            menuBarIcon.translatesAutoresizingMaskIntoConstraints = false
            menuBarLabel.font = .menuBarFont(ofSize: 0)
            menuBarLabel.lineBreakMode = .byTruncatingTail
            menuBarLabel.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(menuBarIcon)
            button.addSubview(menuBarLabel)
            NSLayoutConstraint.activate([
                menuBarIcon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
                menuBarIcon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                // Ukuran ikon dikunci supaya tidak ikut melebar dan mendorong lirik ke kanan.
                menuBarIcon.widthAnchor.constraint(equalToConstant: 16),
                menuBarIcon.heightAnchor.constraint(equalToConstant: 16),
                menuBarLabel.leadingAnchor.constraint(equalTo: menuBarIcon.trailingAnchor, constant: 6),
                menuBarLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
                menuBarLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        statusItem.length = 320
        button.image = nil
        menuBarIcon.isHidden = false
        menuBarLabel.isHidden = false
        menuBarLabel.alignment = alignment.textAlignment
        menuBarLabel.stringValue = text
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, key: String = "", on: Bool = false) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }

        if let track {
            info("\(track.title) — \(track.artist)")
            info(loading ? L("Mencari lirik…", "Searching for lyrics…")
                 : !lines.isEmpty ? L("Lirik dari \(lyricsSource) · \(lines.count) baris", "Lyrics from \(lyricsSource) · \(lines.count) lines")
                 : lookupFailed ? L("Server lirik tidak merespons, mencoba lagi…", "Lyrics server not responding, retrying…")
                 : L("Lirik bersinkron tidak ditemukan", "No synced lyrics found"))
            menu.addItem(.separator())
            menu.addItem(offsetMenuItem())
            menu.addItem(.separator())
            action(L("Cari ulang lirik", "Search lyrics again"), #selector(reload))
            action(L("Buka folder lirik sendiri…", "Open your lyrics folder…"), #selector(openLyricsFolder))
        } else {
            info(message)
        }
        menu.addItem(.separator())
        action(L("Tampilkan di Touch Bar", "Show on Touch Bar"), #selector(showTouchBar))
        let animationMenu = NSMenu()
        for option in LyricAnimation.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(chooseAnimation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == animation ? .on : .off
            animationMenu.addItem(item)
        }
        let animationItem = NSMenuItem(title: L("Animasi lirik", "Lyrics animation"), action: nil, keyEquivalent: "")
        animationItem.submenu = animationMenu
        menu.addItem(animationItem)
        let alignmentMenu = NSMenu()
        for option in LyricAlignment.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(chooseAlignment(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == alignment ? .on : .off
            alignmentMenu.addItem(item)
        }
        let alignmentItem = NSMenuItem(title: L("Perataan lirik", "Lyrics alignment"), action: nil, keyEquivalent: "")
        alignmentItem.submenu = alignmentMenu
        menu.addItem(alignmentItem)
        menu.addItem(wallpaperMenuItem())
        let languageMenu = NSMenu()
        for option in AppLanguage.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == AppLanguage.selected ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: L("Bahasa", "Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        action(L("Lirik juga di menu bar", "Also show lyrics in menu bar"), #selector(toggleMenuBar), on: showInMenuBar)
        action(L("Buka saat login", "Open at login"), #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        if !SystemTouchBar.isAvailable { info(L("⚠︎ API Touch Bar sistem tidak tersedia di macOS ini", "⚠︎ The system Touch Bar API isn't available on this macOS")) }
        menu.addItem(.separator())
        action(L("Keluar", "Quit"), #selector(NSApplication.terminate(_:)), key: "q")
        menu.items.last?.target = NSApp
    }

    // MARK: Wallpaper

    /// Submenu "Wallpaper saat idle": pilih tema (langsung dipratinjau di Touch Bar) dan jedanya.
    private func wallpaperMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        func add(_ title: String, _ selector: Selector, _ value: Any?, on: Bool) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
            submenu.addItem(item)
        }
        add(L("Mati", "Off"), #selector(chooseWallpaper(_:)), nil, on: wallpaper.theme == nil)
        submenu.addItem(.separator())
        for theme in WallpaperTheme.allCases {
            add(theme.title, #selector(chooseWallpaper(_:)), theme.rawValue, on: wallpaper.theme == theme)
        }
        add(L("Ubah teks (\(WallpaperTheme.customText))…", "Edit text (\(WallpaperTheme.customText))…"), #selector(editWallpaperText), nil, on: false)
        add(L("Lokasi cuaca (\(WeatherService.shared.manualCity?.name ?? "otomatis"))…", "Weather location (\(WeatherService.shared.manualCity?.name ?? "automatic"))…"), #selector(editWeatherCity), nil, on: false)
        submenu.addItem(.separator())
        let header = NSMenuItem(title: L("Muncul setelah Mac tidak dipakai", "Show after the Mac is idle for"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        for seconds in IdleWallpaper.delays {
            let title = seconds < 60 ? L("\(Int(seconds)) detik", "\(Int(seconds)) seconds")
                : L("\(Int(seconds / 60)) menit", seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes")
            add(title, #selector(chooseWallpaperDelay(_:)), seconds, on: wallpaper.delay == seconds)
        }
        submenu.addItem(.separator())
        let closeHeader = NSMenuItem(title: L("Tutup saat", "Close when"), action: nil, keyEquivalent: "")
        closeHeader.isEnabled = false
        submenu.addItem(closeHeader)
        add(L("Touch Bar disentuh saja", "The Touch Bar is touched"), #selector(chooseWallpaperClose(_:)), false, on: !wallpaper.closesOnInput)
        add(L("Disentuh, mengetik, atau klik", "Touched, typing, or clicking"), #selector(chooseWallpaperClose(_:)), true,
            on: wallpaper.closesOnInput)
        submenu.addItem(.separator())
        let previewItem = NSMenuItem(title: L("Pratinjau sekarang", "Preview now"), action: #selector(previewWallpaper), keyEquivalent: "")
        previewItem.target = self
        previewItem.isEnabled = wallpaper.theme != nil
        submenu.addItem(previewItem)

        let item = NSMenuItem(title: L("Wallpaper saat idle", "Idle wallpaper"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseWallpaper(_ sender: NSMenuItem) {
        wallpaper.theme = (sender.representedObject as? String).flatMap(WallpaperTheme.init(rawValue:))
        if wallpaper.theme != nil { previewWallpaper() }
    }

    /// Teks untuk tema "Teks sendiri" (nama, inisial, apa saja); setelah disimpan, tema itu langsung dipratinjau.
    @objc private func editWallpaperText() {
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "wallpaperText") ?? "")
        field.placeholderString = L("Misalnya nama atau inisial", "For example your name or initials")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = L("Teks wallpaper Touch Bar", "Touch Bar wallpaper text")
        alert.informativeText = L("Tampil sebagai huruf dot-matrix saat Touch Bar idle. Teks panjang akan berjalan seperti running text.",
                                  "Shown in dot-matrix letters while the Touch Bar is idle. Long text scrolls like a ticker.")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Simpan", "Save"))
        alert.addButton(withTitle: L("Batal", "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WallpaperTheme.customText = field.stringValue
        wallpaper.theme = .text
        previewWallpaper()
    }

    /// Kota untuk tema "Cuaca hari ini"; dikosongkan = lokasi otomatis dari Location Services.
    @objc private func editWeatherCity() {
        let field = NSTextField(string: WeatherService.shared.manualCity?.name ?? "")
        field.placeholderString = L("Kosongkan untuk lokasi otomatis", "Leave empty for automatic location")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = L("Lokasi cuaca", "Weather location")
        alert.informativeText = L("Isi nama kota, misalnya Yogyakarta. Kosongkan untuk memakai lokasi MacBook (perlu izin Lokasi).",
                                  "Enter a city, for example London. Leave empty to use the MacBook's location (needs Location permission).")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Simpan", "Save"))
        alert.addButton(withTitle: L("Batal", "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task {
            guard await WeatherService.shared.setManualCity(name) else {
                let error = NSAlert()
                error.messageText = L("Kota \"\(name)\" tidak ditemukan", "City \"\(name)\" not found")
                error.runModal()
                return
            }
            wallpaper.theme = .weather
            previewWallpaper()
        }
    }

    @objc private func chooseWallpaperDelay(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? TimeInterval { wallpaper.delay = seconds }
    }

    @objc private func chooseWallpaperClose(_ sender: NSMenuItem) {
        if let onInput = sender.representedObject as? Bool { wallpaper.closesOnInput = onInput }
    }

    /// Ditampilkan sampai Touch Bar disentuh; kalau lagu sedang diputar, lirik kembali sesudahnya.
    @objc private func previewWallpaper() {
        if touchBar.isShown { touchBar.hide() }
        wallpaper.preview()
    }

    // MARK: Offset

    private let offsetLabel = NSTextField(labelWithString: "")

    /// Baris "Offset" dengan tombol −0,5 / +0,5 / Reset. Tombol di dalam view tidak menutup menu,
    /// jadi bisa diklik beberapa kali sambil melihat Touch Bar.
    private func offsetMenuItem() -> NSMenuItem {
        offsetLabel.font = .menuFont(ofSize: 0)
        offsetLabel.textColor = .labelColor
        offsetLabel.toolTip = L("Positif: lirik muncul lebih awal. Negatif: lirik muncul lebih lambat.", "Positive: lyrics appear earlier. Negative: lyrics appear later.")
        updateOffsetLabel()

        func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.toolTip = tip
            return button
        }
        let stack = NSStackView(views: [
            offsetLabel,
            button(L("−0,5", "−0.5"), #selector(later), L("Lirik muncul 0,5 detik lebih lambat", "Lyrics appear 0.5 s later")),
            button(L("+0,5", "+0.5"), #selector(earlier), L("Lirik muncul 0,5 detik lebih awal", "Lyrics appear 0.5 s earlier")),
            button("Reset", #selector(resetOffset), L("Kembalikan offset ke 0", "Set the offset back to 0")),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        offsetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: 30)

        let item = NSMenuItem()
        item.view = stack
        return item
    }

    private func updateOffsetLabel() {
        let value = offset
        let hint = value > 0 ? L(" (lebih awal)", " (earlier)") : value < 0 ? L(" (lebih lambat)", " (later)") : ""
        offsetLabel.stringValue = L(String(format: "Offset %+.1f dtk", value).replacingOccurrences(of: ".", with: ","),
                                    String(format: "Offset %+.1f s", value)) + hint
    }

    @objc private func earlier() { offset += 0.5; updateOffsetLabel() }
    @objc private func later() { offset -= 0.5; updateOffsetLabel() }
    @objc private func resetOffset() { offset = 0; updateOffsetLabel() }
    @objc private func showTouchBar() { touchBar.present() }

    @objc private func chooseAlignment(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let option = LyricAlignment(rawValue: raw) {
            alignment = option
        }
    }

    @objc private func chooseAnimation(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let option = LyricAnimation(rawValue: raw) {
            animation = option
        }
    }
    @objc private func toggleMenuBar() { showInMenuBar.toggle() }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = AppLanguage(rawValue: raw) else { return }
        AppLanguage.selected = option
        touchBar.languageChanged()
        // Pesan status diisi ulang pada pembacaan pemutar berikutnya; minta sekarang supaya langsung berganti.
        message = L("Menunggu pemutar musik…", "Waiting for a music player…")
        poll()
    }

    /// File .lrc di folder ini (nama "Judul - Artis.lrc") dipakai sebelum mencari online.
    @objc private func openLyricsFolder() {
        try? FileManager.default.createDirectory(at: LyricsProvider.userFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LyricsProvider.userFolder)
    }

    @objc private func reload() {
        guard let track else { return }
        provider.forget(track)
        lines = []
        loadLyrics(for: track)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = L("Gagal mengubah pengaturan buka saat login", "Couldn't change the open at login setting")
            alert.runModal()
        }
    }
}

// Uji pencarian lirik tanpa pemutar: Lyricsbar --lookup "Judul" "Artis" <durasi detik> [NetEase]
// Argumen kelima membatasi ke satu sumber online. Hanya mencetak sumber dan jumlah baris.
if let i = CommandLine.arguments.firstIndex(of: "--lookup"), CommandLine.arguments.count > i + 3 {
    let a = CommandLine.arguments
    let track = Track(id: "test:\(a[i + 1]):\(a[i + 2])", title: a[i + 1], artist: a[i + 2], album: "",
                      duration: Double(a[i + 3]) ?? 0)
    Task { @MainActor in
        let provider = LyricsProvider()
        if a.count > i + 4 { provider.onlineSources = [a[i + 4]] }
        switch await provider.lyrics(for: track) {
        case .found(let lyrics): print("ketemu  \(lyrics.source), \(lyrics.lines.count) baris")
        case .notFound: print("tidak ditemukan")
        case .failed: print("server gagal")
        }
        provider.forget(track)
        exit(0)
    }
    dispatchMain()
}

// Uji wallpaper tanpa Touch Bar: Lyricsbar --render-wallpaper <tema> <detik mulai> <jumlah frame> <jarak detik> <file.png> [teks]
if let i = CommandLine.arguments.firstIndex(of: "--render-wallpaper"), CommandLine.arguments.count > i + 5 {
    let a = CommandLine.arguments
    guard let theme = WallpaperTheme(rawValue: a[i + 1]) else {
        print("tema tidak dikenal: \(WallpaperTheme.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }
    MainActor.assumeIsolated {
        let ok = WallpaperRenderer.render(theme, text: a.count > i + 6 ? a[i + 6] : nil, start: Double(a[i + 2]) ?? 0, frames: Int(a[i + 3]) ?? 1,
                                          interval: Double(a[i + 4]) ?? 0.5, to: a[i + 5])
        exit(ok ? 0 : 1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
