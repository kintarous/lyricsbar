// Cuaca saat ini di lokasi MacBook untuk wallpaper "Cuaca hari ini".
// Lokasi dari Location Services (atau kota yang diisi manual), cuaca dari Open-Meteo (gratis, tanpa API key).

import CoreLocation
import Foundation

enum WeatherCondition {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, snow, thunder

    /// Kode cuaca WMO dari Open-Meteo.
    init(code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57: self = .drizzle
        case 65, 67, 82: self = .heavyRain
        case 61, 63, 66, 80, 81: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunder
        default: self = .cloudy
        }
    }

    var label: String {
        switch self {
        case .clear: return L("Cerah", "Clear")
        case .partlyCloudy: return L("Cerah berawan", "Partly cloudy")
        case .cloudy: return L("Berawan", "Cloudy")
        case .fog: return L("Berkabut", "Foggy")
        case .drizzle: return L("Gerimis", "Drizzle")
        case .rain: return L("Hujan", "Rain")
        case .heavyRain: return L("Hujan lebat", "Heavy rain")
        case .snow: return L("Salju", "Snow")
        case .thunder: return L("Badai petir", "Thunderstorm")
        }
    }
}

struct Weather {
    var code: Int
    var isDay: Bool
    var temperature: Double
    var windSpeed: Double // km/jam
    var windDirection: Double // derajat, arah datangnya angin
    var place: String?
    var fetchedAt = Date()
    /// Jam terbit dan terbenam kemarin, hari ini, dan besok di lokasi itu (kosong = perkiraan 06:00–18:00).
    var sunTimes: [(rise: Date, set: Date)] = []

    var condition: WeatherCondition { WeatherCondition(code: code) }
}

/// Posisi matahari dan bulan di langit, cukup untuk wallpaper: seberapa jauh perjalanannya dari terbit ke
/// terbenam (0–1), dan fase bulan.
enum Sky {
    /// Fase bulan dari tanggal: 0 = bulan baru, 0,25 = separuh (membesar), 0,5 = purnama, 0,75 = separuh (mengecil).
    /// Satu siklus 29,53 hari, dihitung dari bulan baru 6 Januari 2000 pukul 18.14 UTC.
    static func moonPhase(at date: Date) -> Double {
        let days = date.timeIntervalSince(Date(timeIntervalSince1970: 947_182_440)) / 86_400
        let phase = (days / 29.530_588_853).truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }

    /// Perjalanan matahari: 0–1 dari terbit ke terbenam, atau nil saat malam (dengan kemajuan malam 0–1).
    static func sun(at date: Date, times: [(rise: Date, set: Date)]) -> (day: Double?, night: Double) {
        let days = times.isEmpty ? estimatedTimes(around: date) : times
        for (i, d) in days.enumerated() {
            if date >= d.rise && date <= d.set {
                return (date.timeIntervalSince(d.rise) / d.set.timeIntervalSince(d.rise), 0)
            }
            if i + 1 < days.count, date > d.set, date < days[i + 1].rise {
                return (nil, date.timeIntervalSince(d.set) / days[i + 1].rise.timeIntervalSince(d.set))
            }
        }
        // Di luar rentang data (data lama): pakai jam yang sama pada hari ini.
        return sun(at: date, times: estimatedTimes(around: date, like: days.first))
    }

    /// Perjalanan bulan di atas ufuk (0–1), atau nil kalau bulan sedang di bawah ufuk. Bulan terbit kira-kira
    /// fase × 24,8 jam setelah matahari: purnama terbit saat matahari terbenam, bulan baru bersama matahari.
    static func moon(at date: Date, times: [(rise: Date, set: Date)]) -> Double? {
        let lag = moonPhase(at: date) * 24.84 * 3600
        return sun(at: date.addingTimeInterval(-lag), times: times).day
    }

    private static func estimatedTimes(around date: Date, like sample: (rise: Date, set: Date)? = nil) -> [(rise: Date, set: Date)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let riseOffset = sample.map { $0.rise.timeIntervalSince(calendar.startOfDay(for: $0.rise)) } ?? 6 * 3600
        let setOffset = sample.map { $0.set.timeIntervalSince(calendar.startOfDay(for: $0.rise)) } ?? 18 * 3600
        return (-1...1).map { day in
            let base = start.addingTimeInterval(Double(day) * 86_400)
            return (base.addingTimeInterval(riseOffset), base.addingTimeInterval(setOffset))
        }
    }
}

@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    private(set) var current: Weather?
    /// Pesan saat cuaca belum ada (sedang mencari, izin ditolak, gagal).
    private(set) var status = L("Mencari lokasi…", "Finding your location…")

    private var manager: CLLocationManager?
    private var loading = false
    private var lastAttempt: Date?
    private let session = URLSession(configuration: .ephemeral)

    /// Kota yang diisi manual; nil = lokasi otomatis.
    var manualCity: (name: String, latitude: Double, longitude: Double)? {
        guard let saved = UserDefaults.standard.dictionary(forKey: "weatherCity"),
              let name = saved["name"] as? String, let lat = saved["lat"] as? Double, let lon = saved["lon"] as? Double else { return nil }
        return (name, lat, lon)
    }

    /// Diperbarui paling lama setiap 30 menit; kalau gagal, dicoba lagi setelah 2 menit.
    func refreshIfNeeded() {
        guard !loading else { return }
        if let current, Date().timeIntervalSince(current.fetchedAt) < 30 * 60 { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 120 { return }
        lastAttempt = Date()
        loading = true
        if let city = manualCity {
            fetch(latitude: city.latitude, longitude: city.longitude, place: city.name)
        } else {
            locate()
        }
    }

    /// Mengisi kota manual (misalnya "Yogyakarta"); string kosong = kembali ke lokasi otomatis.
    func setManualCity(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "weatherCity")
        } else {
            guard let placemark = try? await CLGeocoder().geocodeAddressString(trimmed).first,
                  let location = placemark.location else { return false }
            UserDefaults.standard.set(["name": placemark.locality ?? placemark.name ?? trimmed,
                                       "lat": location.coordinate.latitude, "lon": location.coordinate.longitude],
                                      forKey: "weatherCity")
        }
        current = nil
        lastAttempt = nil
        loading = false
        status = L("Mencari lokasi…", "Finding your location…")
        refreshIfNeeded()
        return true
    }

    private func fail(_ message: String) {
        status = message
        loading = false
    }

    // MARK: Lokasi

    private func locate() {
        let manager = self.manager ?? CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.manager = manager
        switch manager.authorizationStatus {
        case .notDetermined:
            status = L("Menunggu izin lokasi…", "Waiting for location permission…")
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            fail(L("Izinkan Lokasi untuk Lyricsbar, atau isi kota di menu ♪", "Allow Location for Lyricsbar, or set a city in the ♪ menu"))
        default:
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard loading, manualCity == nil else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: fail(L("Izinkan Lokasi untuk Lyricsbar, atau isi kota di menu ♪", "Allow Location for Lyricsbar, or set a city in the ♪ menu"))
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            guard loading else { return }
            fetch(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, place: nil)
            // Nama kota dari Apple, hanya untuk ditampilkan.
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let name = placemarks?.first?.locality ?? placemarks?.first?.administrativeArea
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if let name { WeatherService.shared.place = name } }
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard loading else { return }
            fail(L("Lokasi tidak ditemukan. Wi-Fi mati? Bisa juga isi kota di menu ♪", "Location not found. Is Wi-Fi off? You can also set a city in the ♪ menu"))
        }
    }

    /// Nama tempat datang belakangan dari reverse geocoding.
    private var place: String? {
        didSet { current?.place = place }
    }

    // MARK: Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
            let wind_speed_10m: Double
            let wind_direction_10m: Double
        }
        struct Daily: Decodable {
            let sunrise: [String]
            let sunset: [String]
        }
        let current: Current
        let daily: Daily?
        let utc_offset_seconds: Int?
    }

    /// Jam lokal dari Open-Meteo ("2026-10-25T05:12") menjadi Date, memakai zona waktu lokasi itu.
    private static func sunTimes(_ response: Response) -> [(rise: Date, set: Date)] {
        guard let daily = response.daily, let offset = response.utc_offset_seconds,
              let zone = TimeZone(secondsFromGMT: offset) else { return [] }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return zip(daily.sunrise, daily.sunset).compactMap { rise, set in
            guard let r = format.date(from: rise), let s = format.date(from: set) else { return nil }
            return (r, s)
        }
    }

    /// Koordinat dibulatkan ke 2 desimal (±1 km) sebelum dikirim.
    private func fetch(latitude: Double, longitude: Double, place: String?) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m"),
            // Terbit dan terbenam kemarin–besok, untuk posisi matahari dan bulan di wallpaper.
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "past_days", value: "1"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Lyricsbar/1.1", forHTTPHeaderField: "User-Agent")
        Task {
            guard let (data, _) = try? await session.data(for: request),
                  let response = try? JSONDecoder().decode(Response.self, from: data) else {
                return fail(L("Tidak bisa mengambil data cuaca", "Couldn't get the weather"))
            }
            let c = response.current
            current = Weather(code: c.weather_code, isDay: c.is_day == 1, temperature: c.temperature_2m,
                              windSpeed: c.wind_speed_10m, windDirection: c.wind_direction_10m, place: place ?? self.place,
                              sunTimes: Self.sunTimes(response))
            loading = false
        }
    }
}
