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

    var condition: WeatherCondition { WeatherCondition(code: code) }
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
        let current: Current
    }

    /// Koordinat dibulatkan ke 2 desimal (±1 km) sebelum dikirim.
    private func fetch(latitude: Double, longitude: Double, place: String?) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m"),
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
                              windSpeed: c.wind_speed_10m, windDirection: c.wind_direction_10m, place: place ?? self.place)
            loading = false
        }
    }
}
