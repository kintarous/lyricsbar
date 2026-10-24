// Wallpaper Touch Bar: animasi yang muncul saat Mac lama tidak disentuh dan tidak ada lagu yang diputar.
// Sentuh Touch Bar (atau ketik, klik, scroll) untuk kembali ke Touch Bar bawaan.

import Cocoa

// MARK: - Bantuan gambar

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

private func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a < b ? .random(in: a...b) : a }
private func chance(_ p: CGFloat) -> Bool { CGFloat.random(in: 0..<1) < p }

/// Angka acak 0..<1 yang selalu sama untuk `k` yang sama (untuk pemandangan yang bergulir tanpa batas).
private func hash(_ k: Int) -> CGFloat {
    let v = sin(CGFloat(k) * 12.9898) * 43758.5453
    return v - floor(v)
}

/// Sisa bagi yang selalu positif.
private func wrap(_ x: CGFloat, _ length: CGFloat) -> CGFloat {
    let r = x.truncatingRemainder(dividingBy: length)
    return r < 0 ? r + length : r
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Gradien cahaya per warna; warnanya dibulatkan supaya cahaya yang kecerahannya berubah halus (berkedip) tetap
/// memakai beberapa gradien saja.
private var glowGradients: [UInt64: CGGradient] = [:]

private func glowGradient(_ c: CGColor) -> CGGradient? {
    guard let rgba = c.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components, rgba.count == 4 else { return nil }
    let q = rgba.map { UInt64(max(0, min(1, $0)) * 63) }
    let key = q[0] << 18 | q[1] << 12 | q[2] << 6 | q[3]
    if let cached = glowGradients[key] { return cached }
    let start = CGColor(srgbRed: CGFloat(q[0]) / 63, green: CGFloat(q[1]) / 63, blue: CGFloat(q[2]) / 63, alpha: CGFloat(q[3]) / 63)
    guard let gradient = CGGradient(colorsSpace: sRGB, colors: [start, start.copy(alpha: 0)!] as CFArray, locations: nil) else { return nil }
    glowGradients[key] = gradient
    return gradient
}

private extension CGContext {
    func fill(_ c: CGColor, _ rect: CGRect) {
        setFillColor(c)
        fill(rect)
    }

    func fillEllipse(_ c: CGColor, _ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat) {
        setFillColor(c)
        fillEllipse(in: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
    }

    /// Gradasi dari atas (warna pertama) ke bawah.
    func verticalGradient(_ colors: [CGColor], _ rect: CGRect) {
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil) else { return }
        saveGState()
        clip(to: rect)
        drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        restoreGState()
    }

    /// Cahaya bulat yang memudar ke tepi.
    /// Cahaya bulat yang memudar ke tepi. Gradiennya dibuat sekali per warna lalu dipakai ulang: membuatnya setiap
    /// frame (misalnya 45 kunang-kunang × 20 fps) memakan banyak CPU.
    func glow(_ c: CGColor, _ center: CGPoint, _ radius: CGFloat) {
        guard radius > 0, let gradient = glowGradient(c) else { return }
        drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    func line(_ c: CGColor, _ width: CGFloat, _ points: [CGPoint]) {
        guard points.count > 1 else { return }
        setStrokeColor(c)
        setLineWidth(width)
        setLineCap(.round)
        setLineJoin(.round)
        beginPath()
        addLines(between: points)
        strokePath()
    }

    /// Siluet bukit/gunung dari tepi bawah sampai `height(x)`.
    func fillTerrain(_ c: CGColor, width: CGFloat, step: CGFloat = 6, _ height: (CGFloat) -> CGFloat) {
        setFillColor(c)
        beginPath()
        move(to: .zero)
        var x: CGFloat = 0
        while x <= width + step {
            addLine(to: CGPoint(x: x, y: height(x)))
            x += step
        }
        addLine(to: CGPoint(x: width + step, y: 0))
        closePath()
        fillPath()
    }

    /// Pixel art: baris pertama paling atas, '#' = piksel terisi.
    func pixels(_ rows: [String], at origin: CGPoint, scale: CGFloat, color c: CGColor, mirrored: Bool = false) {
        setFillColor(c)
        for (i, row) in rows.enumerated() {
            let y = origin.y + CGFloat(rows.count - 1 - i) * scale
            let chars = Array(row)
            for (j, ch) in chars.enumerated() where ch == "#" {
                let col = mirrored ? chars.count - 1 - j : j
                fill(CGRect(x: origin.x + CGFloat(col) * scale, y: y, width: scale, height: scale))
            }
        }
    }
}

private func text(_ string: String, at point: CGPoint, size: CGFloat, color c: CGColor, mono: Bool = false) {
    let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size, weight: .semibold)
    (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: c) ?? .white])
}

// MARK: - Adegan

/// Satu animasi. `layout()` dipanggil setiap ukuran berubah, `update(_:)` setiap frame, lalu `draw(_:)`.
@MainActor
class WallpaperScene {
    private(set) var size = CGSize.zero
    private(set) var time: CGFloat = 0
    var w: CGFloat { size.width }
    var h: CGFloat { size.height }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func resize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize != size else { return }
        size = newSize
        layout()
    }

    func step(_ dt: CGFloat) {
        guard size.width > 0 else { return }
        time += dt
        update(dt)
    }

    func layout() {}
    func update(_ dt: CGFloat) {}
    func draw(_ ctx: CGContext) {}

    /// Frame per detik yang cukup untuk adegan ini. Adegan yang bergerak pelan tidak perlu 30 fps, dan setiap frame
    /// digambar ulang oleh CPU, jadi frame rate rendah langsung menghemat baterai.
    var frameRate: Double { 30 }

    /// Adegan interaktif bisa digeser jari; ketukan singkat tetap menutup wallpaper.
    var isInteractive: Bool { false }
    func touchBegan(at x: CGFloat) {}
    func touchMoved(to x: CGFloat) {}
    func touchEnded() {}
}

enum WallpaperTheme: String, CaseIterable {
    case text, weather, fish, train, rain, sky, city, flow, aurora, fireflies, matrix, life, cat, ants, snake, dino

    var title: String {
        switch self {
        case .fish: return L("Ikan berenang", "Swimming fish")
        case .train: return L("Kereta lewat", "Passing train")
        case .rain: return L("Hujan dan kilat", "Rain and lightning")
        case .sky: return L("Awan dan burung", "Clouds and birds")
        case .city: return L("Kota malam", "City at night")
        case .flow: return L("Partikel mengalir", "Flowing particles")
        case .aurora: return "Aurora"
        case .fireflies: return L("Kunang-kunang", "Fireflies")
        case .matrix: return "Matrix rain"
        case .life: return "Game of Life"
        case .cat: return L("Kucing jalan-jalan", "Wandering cat")
        case .ants: return L("Semut berbaris", "Marching ants")
        case .snake: return L("Ular (main sendiri)", "Snake (autoplay)")
        case .dino: return L("Dino runner (main sendiri)", "Dino runner (autoplay)")
        case .text: return L("Teks sendiri", "Your own text")
        case .weather: return L("Cuaca hari ini", "Today's weather")
        }
    }

    @MainActor
    func makeScene() -> WallpaperScene {
        switch self {
        case .fish: return FishScene()
        case .train: return TrainScene()
        case .rain: return RainScene()
        case .sky: return SkyScene()
        case .city: return CityScene()
        case .flow: return FlowScene()
        case .aurora: return AuroraScene()
        case .fireflies: return FirefliesScene()
        case .matrix: return MatrixScene()
        case .life: return LifeScene()
        case .cat: return CatScene()
        case .ants: return AntsScene()
        case .snake: return SnakeScene()
        case .dino: return DinoScene()
        case .text: return TextScene(text: WallpaperTheme.customText)
        case .weather: return WeatherScene()
        }
    }
}

// MARK: Ikan berenang

final class FishScene: WallpaperScene {
    override var frameRate: Double { 20 }

    private struct Fish {
        var x, y, targetY, speed, dir, size, phase: CGFloat
        var body, fin: CGColor
    }

    private struct Bubble { var x, y, r, speed, phase: CGFloat }

    private static let palettes: [(UInt32, UInt32)] = [
        (0xF4A340, 0xE0702A), (0x4FC3F7, 0x1E88E5), (0xFF6F91, 0xD94A6E),
        (0xFFE066, 0xF2B705), (0x9CCC65, 0x558B2F), (0xCE93D8, 0x8E24AA),
    ]

    private var fish: [Fish] = []
    private var bubbles: [Bubble] = []
    private var weeds: [(x: CGFloat, height: CGFloat, phase: CGFloat)] = []

    override func layout() {
        fish = (0..<9).map { _ in newFish(anywhere: true) }
        weeds = stride(from: CGFloat(20), to: w, by: 64).map { ($0 + rnd(-18, 18), rnd(8, 18), rnd(0, 6)) }
    }

    private func newFish(anywhere: Bool) -> Fish {
        let dir: CGFloat = chance(0.5) ? 1 : -1
        let palette = Self.palettes.randomElement()!
        let y = rnd(7, h - 7)
        return Fish(x: anywhere ? rnd(0, w) : (dir > 0 ? -20 : w + 20), y: y, targetY: y,
                    speed: rnd(12, 35), dir: dir, size: rnd(4, 7.5), phase: rnd(0, 6),
                    body: color(palette.0), fin: color(palette.1))
    }

    override func update(_ dt: CGFloat) {
        for i in fish.indices {
            fish[i].x += fish[i].dir * fish[i].speed * dt
            fish[i].phase += dt * (4 + fish[i].speed / 6)
            if chance(dt * 0.3) { fish[i].targetY = rnd(7, h - 7) }
            fish[i].y += (fish[i].targetY - fish[i].y) * min(1, dt * 0.8)
            if fish[i].x < -30 || fish[i].x > w + 30 {
                fish[i] = newFish(anywhere: false)
            } else if chance(dt * 0.03) {
                fish[i].dir *= -1
            }
        }
        if chance(dt * 3) { bubbles.append(Bubble(x: rnd(0, w), y: -2, r: rnd(0.8, 1.8), speed: rnd(6, 14), phase: rnd(0, 6))) }
        for i in bubbles.indices {
            bubbles[i].y += bubbles[i].speed * dt
            bubbles[i].phase += dt * 3
        }
        bubbles.removeAll { $0.y > h + 3 }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x06283D), color(0x020B14)], bounds)

        // Berkas cahaya dari permukaan, bergeser pelan.
        ctx.setFillColor(color(0x8FD3FF, 0.05))
        for k in 0..<6 {
            let x = wrap(CGFloat(k) * 210 + time * 7, w + 200) - 100
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: h))
            ctx.addLine(to: CGPoint(x: x + 22, y: h))
            ctx.addLine(to: CGPoint(x: x + 50, y: 0))
            ctx.addLine(to: CGPoint(x: x + 8, y: 0))
            ctx.closePath()
            ctx.fillPath()
        }

        ctx.fill(color(0x1E1A10), CGRect(x: 0, y: 0, width: w, height: 1.5))
        for weed in weeds {
            let sway = sin(time * 1.2 + weed.phase) * 4
            ctx.setStrokeColor(color(0x2E7D32, 0.8))
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: weed.x, y: 0))
            ctx.addQuadCurve(to: CGPoint(x: weed.x + sway, y: weed.height),
                             control: CGPoint(x: weed.x - sway * 0.5, y: weed.height * 0.5))
            ctx.strokePath()
        }

        ctx.setStrokeColor(color(0xFFFFFF, 0.45))
        ctx.setLineWidth(0.6)
        for b in bubbles {
            ctx.strokeEllipse(in: CGRect(x: b.x + sin(b.phase) * 1.5 - b.r, y: b.y - b.r, width: b.r * 2, height: b.r * 2))
        }

        for f in fish { drawFish(ctx, f) }
    }

    private func drawFish(_ ctx: CGContext, _ f: Fish) {
        let s = f.size, d = f.dir
        let wag = sin(f.phase) * s * 0.35
        ctx.setFillColor(f.fin)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: f.x - d * s * 0.8, y: f.y))
        ctx.addLine(to: CGPoint(x: f.x - d * s * 1.8, y: f.y + s * 0.6 + wag))
        ctx.addLine(to: CGPoint(x: f.x - d * s * 1.8, y: f.y - s * 0.6 + wag))
        ctx.closePath()
        ctx.fillPath()
        // Sirip atas.
        ctx.beginPath()
        ctx.move(to: CGPoint(x: f.x - d * s * 0.4, y: f.y + s * 0.4))
        ctx.addLine(to: CGPoint(x: f.x - d * s * 0.1, y: f.y + s * 0.85))
        ctx.addLine(to: CGPoint(x: f.x + d * s * 0.3, y: f.y + s * 0.4))
        ctx.closePath()
        ctx.fillPath()

        ctx.fillEllipse(f.body, CGPoint(x: f.x, y: f.y), s * 1.1, s * 0.55)
        let eye = CGPoint(x: f.x + d * s * 0.6, y: f.y + s * 0.12)
        ctx.fillEllipse(color(0xFFFFFF), eye, max(0.8, s * 0.14), max(0.8, s * 0.14))
        ctx.fillEllipse(color(0x000000), eye, max(0.45, s * 0.07), max(0.45, s * 0.07))
    }
}

// MARK: Kereta lewat

final class TrainScene: WallpaperScene {
    override var frameRate: Double { 24 }

    private var scroll: CGFloat = 0
    /// Posisi ujung depan lokomotif; nil = sedang menunggu kereta berikutnya.
    private var trainX: CGFloat?
    private var wait: CGFloat = 1
    private var stars: [CGPoint] = []
    private let carLength: CGFloat = 46
    private let cars = 7

    override func layout() {
        stars = (0..<70).map { _ in CGPoint(x: rnd(0, w), y: rnd(12, h - 1)) }
    }

    override func update(_ dt: CGFloat) {
        scroll += dt * 40
        if let x = trainX {
            trainX = x + dt * 110
            if x - CGFloat(cars) * (carLength + 2) > w {
                trainX = nil
                wait = rnd(3, 8)
            }
        } else {
            wait -= dt
            if wait <= 0 { trainX = -5 }
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x0B1026), color(0x2B1E3F)], bounds)
        for (i, star) in stars.enumerated() {
            let twinkle = 0.35 + 0.35 * sin(time * 2 + CGFloat(i))
            ctx.fill(color(0xFFFFFF, twinkle), CGRect(x: star.x, y: star.y, width: 0.8, height: 0.8))
        }
        // Bulan bergeser pelan supaya tidak membekas di layar OLED.
        let moon = CGPoint(x: w * 0.82 + 40 * sin(time / 170), y: h - 8)
        ctx.glow(color(0xF5F3CE, 0.25), moon, 14)
        ctx.fillEllipse(color(0xF5F3CE), moon, 4.5, 4.5)

        // Tiga lapis pemandangan: makin dekat, makin cepat bergeser.
        let far = scroll * 0.15
        ctx.fillTerrain(color(0x221C3A), width: w) { x in
            let u = x + far
            return 10 + 5 * sin(u * 0.012) + 3 * sin(u * 0.031 + 1.3)
        }
        let mid = scroll * 0.4
        let hill = { (x: CGFloat) -> CGFloat in
            let u = x + mid
            return 6 + 3 * sin(u * 0.02 + 2) + 2 * sin(u * 0.05)
        }
        ctx.fillTerrain(color(0x16122A), width: w, hill)
        ctx.setFillColor(color(0x16122A))
        let firstTree = Int(floor(mid / 22))
        for k in firstTree...(firstTree + Int(w / 22) + 1) where hash(k) < 0.45 {
            let x = CGFloat(k) * 22 - mid
            let base = hill(x) - 1, height = 5 + hash(k + 99) * 5
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x - 2.5, y: base))
            ctx.addLine(to: CGPoint(x: x, y: base + height))
            ctx.addLine(to: CGPoint(x: x + 2.5, y: base))
            ctx.closePath()
            ctx.fillPath()
        }

        ctx.fill(color(0x0B0914), CGRect(x: 0, y: 0, width: w, height: 4))
        for k in 0...Int(w / 9) + 1 {
            let x = CGFloat(k) * 9 - wrap(scroll, 9)
            ctx.fill(color(0x2C2838), CGRect(x: x, y: 2, width: 3, height: 1))
        }
        ctx.fill(color(0x6C6880), CGRect(x: 0, y: 3, width: w, height: 0.6))

        if let front = trainX { drawTrain(ctx, front: front) }

        // Tiang listrik di latar paling depan.
        let near = scroll * 1.3
        var tops: [CGPoint] = []
        for k in Int(floor(near / 160))...(Int(near / 160) + Int(w / 160) + 2) {
            let x = CGFloat(k) * 160 - near
            ctx.fill(color(0x090711), CGRect(x: x, y: 0, width: 1.4, height: 26))
            ctx.fill(color(0x090711), CGRect(x: x - 3, y: 24, width: 7.4, height: 1))
            tops.append(CGPoint(x: x + 0.7, y: 25))
        }
        ctx.setStrokeColor(color(0x090711))
        ctx.setLineWidth(0.5)
        for (a, b) in zip(tops, tops.dropFirst()) {
            ctx.beginPath()
            ctx.move(to: a)
            ctx.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: 20))
            ctx.strokePath()
        }
    }

    private func drawTrain(_ ctx: CGContext, front: CGFloat) {
        ctx.setFillColor(color(0xFFE9A8, 0.12))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: front, y: 9))
        ctx.addLine(to: CGPoint(x: front + 90, y: 15))
        ctx.addLine(to: CGPoint(x: front + 90, y: 3))
        ctx.closePath()
        ctx.fillPath()

        for i in 0..<cars {
            let right = front - CGFloat(i) * (carLength + 2)
            let car = CGRect(x: right - carLength, y: 4.5, width: carLength, height: 11)
            guard car.maxX > 0, car.minX < w else { continue }
            let path = CGPath(roundedRect: car, cornerWidth: i == 0 ? 4 : 1.5, cornerHeight: i == 0 ? 4 : 1.5, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color(0x3A4A5E))
            ctx.fillPath()
            ctx.fill(color(0xC0392B), CGRect(x: car.minX, y: 7, width: car.width, height: 1.2))
            let windows = i == 0 ? 2 : 5
            for j in 0..<windows {
                let x = car.minX + 4 + CGFloat(j) * 8.5 + (i == 0 ? 22 : 0)
                ctx.fill(color(0xFFD86B, 0.9), CGRect(x: x, y: 10, width: 5.5, height: 3.5))
            }
            for wx in [car.minX + 6, car.minX + 13, car.maxX - 13, car.maxX - 6] {
                ctx.fillEllipse(color(0x15151F), CGPoint(x: wx, y: 4.5), 2, 2)
            }
        }
        ctx.glow(color(0xFFF2C0, 0.9), CGPoint(x: front - 1, y: 9), 4)
    }
}

// MARK: Hujan dan kilat

final class RainScene: WallpaperScene {
    override var frameRate: Double { 30 }

    private struct Drop { var x, y, speed, length: CGFloat }

    private var drops: [Drop] = []
    private var splashes: [(x: CGFloat, age: CGFloat)] = []
    private var flash: CGFloat = 0
    private var bolt: [CGPoint] = []
    private var branch: [CGPoint] = []
    private var boltLife: CGFloat = 0
    private var nextStrike: CGFloat = 3
    private var echo: CGFloat = 0

    override func layout() {
        drops = (0..<Int(w / 6)).map { _ in newDrop(anywhere: true) }
    }

    private func newDrop(anywhere: Bool) -> Drop {
        Drop(x: rnd(-10, w + 20), y: anywhere ? rnd(0, h) : h + rnd(0, 10), speed: rnd(90, 150), length: rnd(3, 6))
    }

    override func update(_ dt: CGFloat) {
        for i in drops.indices {
            drops[i].y -= drops[i].speed * dt
            drops[i].x -= drops[i].speed * dt * 0.15
            if drops[i].y < 1 {
                if chance(0.5) { splashes.append((drops[i].x, 0)) }
                drops[i] = newDrop(anywhere: false)
            }
        }
        for i in splashes.indices { splashes[i].age += dt }
        splashes.removeAll { $0.age > 0.3 }

        flash = max(0, flash - dt * 3)
        boltLife = max(0, boltLife - dt)
        if echo > 0 {
            echo -= dt
            if echo <= 0 { flash = 0.6 }
        }
        nextStrike -= dt
        if nextStrike <= 0 { strike() }
    }

    private func strike() {
        flash = 1
        boltLife = 0.25
        nextStrike = rnd(5, 12)
        echo = chance(0.5) ? 0.15 : 0
        var x = rnd(60, w - 60)
        bolt = [CGPoint(x: x, y: h)]
        branch = []
        for k in 1...7 {
            x += rnd(-7, 7)
            let point = CGPoint(x: x, y: h - CGFloat(k) * h / 7)
            bolt.append(point)
            if k == 3 {
                branch = [point, CGPoint(x: x + rnd(6, 12), y: point.y - 5), CGPoint(x: x + rnd(10, 18), y: point.y - 9)]
            }
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x0D1320), color(0x05070C)], bounds)
        if flash > 0 { ctx.fill(color(0xB8C7FF, 0.35 * flash), bounds) }
        // Siluet kota jauh yang ikut terang saat kilat.
        ctx.fillTerrain(color(0x0A0E18), width: w, step: 14) { x in
            let k = Int(x / 14)
            return 4 + hash(k) * 9
        }
        if boltLife > 0 {
            let a = boltLife / 0.25
            ctx.line(color(0xB8C7FF, 0.35 * a), 3, bolt)
            ctx.line(color(0xFFFFFF, a), 1.1, bolt)
            ctx.line(color(0xFFFFFF, 0.7 * a), 0.7, branch)
        }

        ctx.setStrokeColor(color(0x9FB6D9, 0.55))
        ctx.setLineWidth(0.7)
        ctx.beginPath()
        for d in drops {
            ctx.move(to: CGPoint(x: d.x, y: d.y))
            ctx.addLine(to: CGPoint(x: d.x + d.length * 0.15, y: d.y + d.length))
        }
        ctx.strokePath()

        ctx.fill(color(0x1A2233), CGRect(x: 0, y: 0, width: w, height: 1.2))
        for s in splashes {
            let r = s.age * 18, y = 1 + s.age * 9 - s.age * s.age * 35
            let a = 1 - s.age / 0.3
            ctx.fill(color(0xC9D8F0, 0.6 * a), CGRect(x: s.x - r, y: y, width: 0.8, height: 0.8))
            ctx.fill(color(0xC9D8F0, 0.6 * a), CGRect(x: s.x + r, y: y, width: 0.8, height: 0.8))
        }
    }
}

// MARK: Awan dan burung

final class SkyScene: WallpaperScene {
    override var frameRate: Double { 20 }

    private struct Cloud {
        var x, y, speed, scale: CGFloat
        var puffs: [(dx: CGFloat, dy: CGFloat, r: CGFloat)]
    }

    private struct Flock {
        var x, y, speed, dir: CGFloat
        var birds: [(dx: CGFloat, dy: CGFloat, phase: CGFloat)]
    }

    private var clouds: [Cloud] = []
    private var flocks: [Flock] = []
    private var nextFlock: CGFloat = 1

    override func layout() {
        clouds = (0..<Int(w / 90)).map { _ in newCloud(x: rnd(-40, w)) }
    }

    private func newCloud(x: CGFloat) -> Cloud {
        let scale = rnd(0.6, 1.2)
        let puffs = (0..<Int.random(in: 4...7)).map { _ in (dx: rnd(-14, 14), dy: rnd(-2, 3), r: rnd(4, 8)) }
        return Cloud(x: x, y: rnd(10, h - 6), speed: 4 + scale * 8, scale: scale, puffs: puffs)
    }

    override func update(_ dt: CGFloat) {
        for i in clouds.indices {
            clouds[i].x += clouds[i].speed * dt
            if clouds[i].x > w + 40 { clouds[i] = newCloud(x: -40) }
        }
        nextFlock -= dt
        if nextFlock <= 0 {
            nextFlock = rnd(6, 14)
            let dir: CGFloat = chance(0.5) ? 1 : -1
            let birds = (0..<Int.random(in: 3...9)).map { i -> (dx: CGFloat, dy: CGFloat, phase: CGFloat) in
                let rank = CGFloat((i + 1) / 2)
                return (-dir * rank * 7 + rnd(-1, 1), (i % 2 == 0 ? 1 : -1) * rank * 2 + rnd(-0.5, 0.5), rnd(0, 6))
            }
            flocks.append(Flock(x: dir > 0 ? -10 : w + 10, y: rnd(12, h - 8), speed: rnd(35, 55), dir: dir, birds: birds))
        }
        for i in flocks.indices {
            flocks[i].x += flocks[i].dir * flocks[i].speed * dt
            for j in flocks[i].birds.indices { flocks[i].birds[j].phase += dt * 9 }
        }
        flocks.removeAll { $0.x < -80 || $0.x > w + 80 }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x1B2A4A), color(0x4A3558), color(0x7A4A4F)], bounds)
        let sun = CGPoint(x: w * 0.3 + 60 * sin(time / 200), y: 0)
        ctx.glow(color(0xFFB36B, 0.45), sun, 60)
        ctx.fillEllipse(color(0xFFC983), sun, 9, 9)

        for c in clouds {
            for p in c.puffs {
                ctx.fillEllipse(color(0xF2E6F0, 0.10 + 0.08 * c.scale), CGPoint(x: c.x + p.dx * c.scale, y: c.y + p.dy * c.scale),
                                p.r * c.scale * 1.4, p.r * c.scale)
            }
        }

        for f in flocks {
            for b in f.birds {
                let x = f.x + b.dx, y = f.y + b.dy, flap = sin(b.phase) * 1.8
                ctx.line(color(0x120E1C), 0.9, [CGPoint(x: x - 2.6, y: y + flap), CGPoint(x: x, y: y), CGPoint(x: x + 2.6, y: y + flap)])
            }
        }
        ctx.fillTerrain(color(0x150F1C), width: w, step: 10) { x in 2 + 2 * sin(x * 0.02) + 1.5 * sin(x * 0.07) }
    }
}

// MARK: Kota malam

final class CityScene: WallpaperScene {
    override var frameRate: Double { 15 }

    private struct Building {
        var x, width, height: CGFloat
        var cols, rows: Int
        var lights: [Bool]
        var antenna: Bool
    }

    private struct Car { var x, speed, dir: CGFloat }

    private var near: [Building] = []
    private var far: [Building] = []
    private var cars: [Car] = []
    private var stars: [CGPoint] = []
    private var scroll: CGFloat = 0
    private var span: CGFloat { w + 200 }

    override func layout() {
        near = makeRow(heights: 10...26, widths: 18...44)
        far = makeRow(heights: 14...28, widths: 14...30)
        stars = (0..<50).map { _ in CGPoint(x: rnd(0, w), y: rnd(18, h - 1)) }
    }

    private func makeRow(heights: ClosedRange<CGFloat>, widths: ClosedRange<CGFloat>) -> [Building] {
        var x: CGFloat = 0
        var row: [Building] = []
        while x < span {
            let width = CGFloat.random(in: widths), height = CGFloat.random(in: heights)
            let cols = max(1, Int((width - 4) / 4)), rows = max(1, Int((height - 5) / 4))
            row.append(Building(x: x, width: width, height: height, cols: cols, rows: rows,
                                lights: (0..<cols * rows).map { _ in chance(0.3) }, antenna: height > 22 && chance(0.5)))
            x += width + rnd(1, 4)
        }
        return row
    }

    override func update(_ dt: CGFloat) {
        scroll += dt * 5
        // Lampu jendela menyala dan mati satu per satu.
        if !near.isEmpty, chance(dt * 6) {
            let b = Int.random(in: near.indices)
            if !near[b].lights.isEmpty { near[b].lights[Int.random(in: near[b].lights.indices)].toggle() }
        }
        if chance(dt * 0.6) {
            let dir: CGFloat = chance(0.5) ? 1 : -1
            cars.append(Car(x: dir > 0 ? -10 : w + 10, speed: rnd(40, 70), dir: dir))
        }
        for i in cars.indices { cars[i].x += cars[i].dir * cars[i].speed * dt }
        cars.removeAll { $0.x < -20 || $0.x > w + 20 }
    }

    private func screenX(_ x: CGFloat, parallax: CGFloat) -> CGFloat {
        wrap(x - scroll * parallax, span) - 100
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x070B1A), color(0x1A1430)], bounds)
        for (i, star) in stars.enumerated() {
            ctx.fill(color(0xFFFFFF, 0.25 + 0.2 * sin(time + CGFloat(i))), CGRect(x: star.x, y: star.y, width: 0.7, height: 0.7))
        }
        let moon = CGPoint(x: w * 0.12 + 40 * sin(time / 170), y: h - 8)
        ctx.glow(color(0xE8EEFF, 0.25), moon, 12)
        ctx.fillEllipse(color(0xE8EEFF), moon, 4, 4)
        ctx.fillEllipse(color(0x0B0F20), CGPoint(x: moon.x + 1.8, y: moon.y + 1), 3.4, 3.4)

        for b in far {
            let x = screenX(b.x, parallax: 0.4)
            ctx.fill(color(0x141A2E), CGRect(x: x, y: 3, width: b.width, height: b.height))
        }
        for b in near {
            let x = screenX(b.x, parallax: 1)
            ctx.fill(color(0x0C0F1C), CGRect(x: x, y: 3, width: b.width, height: b.height))
            for r in 0..<b.rows {
                for c in 0..<b.cols where b.lights[r * b.cols + c] {
                    ctx.fill(color(0xFFD27A, 0.85), CGRect(x: x + 3 + CGFloat(c) * 4, y: 6 + CGFloat(r) * 4, width: 2, height: 2))
                }
            }
            if b.antenna {
                ctx.fill(color(0x0C0F1C), CGRect(x: x + b.width / 2, y: 3 + b.height, width: 0.8, height: 4))
                if sin(time * 3 + b.x) > 0.6 {
                    ctx.glow(color(0xFF3B3B, 0.8), CGPoint(x: x + b.width / 2 + 0.4, y: 7 + b.height), 2.5)
                }
            }
        }

        ctx.fill(color(0x05060C), CGRect(x: 0, y: 0, width: w, height: 3))
        for car in cars {
            ctx.fill(color(0x2A2E3E), CGRect(x: car.x - 4, y: 0.6, width: 8, height: 2.2))
            let front = car.x + car.dir * 4, back = car.x - car.dir * 4
            ctx.glow(color(0xFFF1B8, 0.7), CGPoint(x: front, y: 1.6), 3.5)
            ctx.glow(color(0xFF3030, 0.6), CGPoint(x: back, y: 1.6), 2)
        }
    }
}

// MARK: Partikel mengalir

final class FlowScene: WallpaperScene {
    override var frameRate: Double { 24 }

    private struct Particle { var x, y, life: CGFloat }

    private var particles: [Particle] = []
    /// Kanvas jejak: setiap frame sedikit digelapkan, jadi gerakan partikel meninggalkan ekor. Tetap 2x seperti Touch Bar;
    /// versi 1x memang lebih hemat (~14% vs ~20% CPU) tapi jejaknya jadi kasar dan bergaris.
    private var trail: CGContext?
    /// Warna pelangi yang disiapkan sekali, supaya tidak membuat objek warna baru untuk setiap partikel setiap frame.
    private static let palette: [CGColor] = (0..<64).map { NSColor(hue: CGFloat($0) / 64, saturation: 0.7, brightness: 1, alpha: 0.75).cgColor }

    override func layout() {
        particles = (0..<Int(w / 3.2)).map { _ in Particle(x: rnd(0, w), y: rnd(0, h), life: rnd(2, 8)) }
        trail = CGContext(data: nil, width: Int(w * 2), height: Int(h * 2), bitsPerComponent: 8, bytesPerRow: 0,
                          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        trail?.scaleBy(x: 2, y: 2)
        trail?.fill(color(0x000000), bounds)
    }

    private func angle(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        (sin(x * 0.008 + time * 0.2) + cos(y * 0.25 - time * 0.3) + sin((x + y) * 0.004 - time * 0.1)) * .pi * 0.6
    }

    override func update(_ dt: CGFloat) {
        guard let trail else { return }
        // Pudar 8% per 1/30 detik, berapa pun frame rate-nya, supaya panjang ekor tetap sama.
        trail.fill(color(0x000000, 1 - pow(0.92, dt * 30)), bounds)
        trail.setLineWidth(0.9)
        trail.setLineCap(.round)
        for i in particles.indices {
            var p = particles[i]
            let a = angle(p.x, p.y)
            let nx = p.x + cos(a) * 32 * dt, ny = p.y + sin(a) * 14 * dt
            let hue = wrap(p.x / w * 0.45 + time * 0.02, 1)
            trail.setStrokeColor(Self.palette[Int(hue * 64) % 64])
            trail.beginPath()
            trail.move(to: CGPoint(x: p.x, y: p.y))
            trail.addLine(to: CGPoint(x: nx, y: ny))
            trail.strokePath()
            p.x = nx
            p.y = ny
            p.life -= dt
            if p.life <= 0 || p.x < 0 || p.x > w || p.y < 0 || p.y > h {
                p = Particle(x: rnd(0, w), y: rnd(0, h), life: rnd(2, 8))
            }
            particles[i] = p
        }
    }

    override func draw(_ ctx: CGContext) {
        guard let image = trail?.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }
}

// MARK: Aurora

final class AuroraScene: WallpaperScene {
    override var frameRate: Double { 15 }

    private var stars: [CGPoint] = []
    private let ribbons: [(base: CGFloat, amp: CGFloat, freq: CGFloat, speed: CGFloat, color: UInt32)] = [
        (18, 5, 0.006, 0.25, 0x3DFFB0), (14, 4, 0.009, -0.18, 0x37E0FF),
        (20, 3, 0.012, 0.32, 0x9B6BFF), (12, 3, 0.004, 0.15, 0x5CFF7A),
    ]
    /// Langit dan aurora digambar di kanvas beresolusi rendah (1 piksel = 2 pt) lalu diperbesar: cahaya aurora memang
    /// lembut, jadi tidak terlihat bedanya, tapi piksel yang dihitung tinggal 1/16 dari resolusi Touch Bar.
    private let skyScale: CGFloat = 0.5
    private var sky: CGContext?
    /// Siluet gunung tidak bergerak, jadi cukup digambar sekali.
    private var mountains: CGImage?

    override func layout() {
        stars = (0..<90).map { _ in CGPoint(x: rnd(0, w), y: rnd(4, h - 1)) }
        sky = CGContext(data: nil, width: Int(ceil(w * skyScale)), height: Int(ceil(h * skyScale)), bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        sky?.scaleBy(x: skyScale, y: skyScale)
        if let ctx = CGContext(data: nil, width: Int(w * 2), height: Int(h * 2), bitsPerComponent: 8, bytesPerRow: 0,
                               space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: 2, y: 2)
            ctx.fillTerrain(color(0x010307), width: w, step: 8) { x in
                3 + 3 * sin(x * 0.015) + 2 * sin(x * 0.043 + 1) + (hash(Int(x / 8)) > 0.8 ? 2 : 0)
            }
            mountains = ctx.makeImage()
        }
    }

    override func draw(_ ctx: CGContext) {
        if let sky {
            sky.setBlendMode(.normal)
            sky.verticalGradient([color(0x020814), color(0x06121C)], bounds)
            sky.setBlendMode(.screen)
            for (i, r) in ribbons.enumerated() {
                let phase = CGFloat(i) * 2
                let center = { (x: CGFloat) -> CGFloat in
                    r.base + r.amp * sin(x * r.freq + self.time * r.speed + phase)
                        + r.amp * 0.5 * sin(x * r.freq * 2.3 - self.time * r.speed * 1.4)
                }
                let thickness = { (x: CGFloat) -> CGFloat in
                    5 + 4 * (0.5 + 0.5 * sin(x * 0.01 + self.time * 0.5 + phase))
                }
                // Beberapa lapisan dengan ketebalan berbeda: tepinya terlihat lembut.
                for (spread, alpha) in [(1.6, 0.06), (1.0, 0.10), (0.5, 0.16)] as [(CGFloat, CGFloat)] {
                    sky.setFillColor(color(r.color, alpha))
                    sky.beginPath()
                    var x: CGFloat = 0
                    sky.move(to: CGPoint(x: 0, y: center(0) + thickness(0) * spread))
                    while x <= w + 8 {
                        sky.addLine(to: CGPoint(x: x, y: center(x) + thickness(x) * spread))
                        x += 8
                    }
                    while x >= -8 {
                        sky.addLine(to: CGPoint(x: x, y: center(x) - thickness(x) * spread * 0.6))
                        x -= 8
                    }
                    sky.closePath()
                    sky.fillPath()
                }
            }
            if let image = sky.makeImage() {
                ctx.saveGState()
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: bounds)
                ctx.restoreGState()
            }
        }
        for (i, star) in stars.enumerated() {
            ctx.fill(color(0xFFFFFF, 0.2 + 0.2 * sin(time * 1.5 + CGFloat(i) * 1.7)), CGRect(x: star.x, y: star.y, width: 0.7, height: 0.7))
        }
        if let mountains { ctx.draw(mountains, in: bounds) }
    }
}

// MARK: Kunang-kunang

final class FirefliesScene: WallpaperScene {
    override var frameRate: Double { 20 }

    private struct Fly { var x, y, vx, vy, phase, blink: CGFloat }

    private var flies: [Fly] = []
    private var grass: [(x: CGFloat, height: CGFloat, lean: CGFloat)] = []

    override func layout() {
        flies = (0..<Int(w / 22)).map { _ in
            Fly(x: rnd(0, w), y: rnd(4, h - 3), vx: rnd(-6, 6), vy: rnd(-3, 3), phase: rnd(0, 6), blink: rnd(0.8, 2))
        }
        grass = stride(from: CGFloat(0), to: w, by: 2.5).map { ($0 + rnd(-1, 1), rnd(2, 8), rnd(-2, 2)) }
    }

    override func update(_ dt: CGFloat) {
        for i in flies.indices {
            var f = flies[i]
            f.vx = max(-8, min(8, f.vx + rnd(-1, 1) * 20 * dt))
            f.vy = max(-4, min(4, f.vy + rnd(-1, 1) * 12 * dt))
            f.x = wrap(f.x + f.vx * dt, w)
            f.y += f.vy * dt
            if f.y < 4 || f.y > h - 3 { f.vy = -f.vy }
            f.phase += dt * f.blink
            flies[i] = f
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x030A10), color(0x07140C)], bounds)
        for f in flies {
            let b = pow(max(0, sin(f.phase)), 2)
            if b > 0.02 { ctx.glow(color(0xD4FF6A, 0.55 * b), CGPoint(x: f.x, y: f.y), 2 + 5 * b) }
            ctx.fillEllipse(color(0xEFFFA0, 0.25 + 0.75 * b), CGPoint(x: f.x, y: f.y), 0.7, 0.7)
        }
        if grassImage == nil || time - grassDrawnAt > 0.2 { redrawGrass() }
        if let grassImage { ctx.draw(grassImage, in: CGRect(x: 0, y: 0, width: w, height: 10)) }
    }

    /// Ratusan helai rumput yang dihaluskan tepinya mahal digambar; goyangannya pelan, jadi cukup digambar ulang
    /// 5 kali per detik ke gambar tersendiri yang ditempel di setiap frame.
    private var grassImage: CGImage?
    private var grassDrawnAt: CGFloat = 0

    private func redrawGrass() {
        grassDrawnAt = time
        guard let ctx = CGContext(data: nil, width: Int(w * 2), height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setStrokeColor(color(0x0F2A16))
        ctx.setLineWidth(0.9)
        ctx.beginPath()
        for g in grass {
            let sway = sin(time * 1.3 + g.x * 0.05) * 0.8
            ctx.move(to: CGPoint(x: g.x, y: 0))
            ctx.addLine(to: CGPoint(x: g.x + g.lean + sway, y: g.height))
        }
        ctx.strokePath()
        grassImage = ctx.makeImage()
    }
}

// MARK: Matrix rain

final class MatrixScene: WallpaperScene {
    override var frameRate: Double { 15 }

    private struct Column { var head, speed, trail: CGFloat; var glyphs: [Int] }

    private static let charset = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789Z:=+<>")
    private let cell: CGFloat = 6
    private var rows = 5
    private var columns: [Column] = []
    private var green: [CGImage] = []
    private var white: [CGImage] = []

    override func layout() {
        rows = Int(h / cell)
        columns = (0..<Int(w / cell)).map { _ in newColumn(head: rnd(-12, CGFloat(rows))) }
        if green.isEmpty {
            green = Self.charset.compactMap { render($0, color(0x3CFF6E)) }
            white = Self.charset.compactMap { render($0, color(0xE2FFE8)) }
        }
    }

    private func newColumn(head: CGFloat) -> Column {
        Column(head: head, speed: rnd(4, 11), trail: rnd(3, 9), glyphs: (0..<rows).map { _ in Int.random(in: Self.charset.indices) })
    }

    /// Setiap karakter digambar sekali ke gambar kecil, lalu dipakai ulang setiap frame.
    private func render(_ char: Character, _ c: CGColor) -> CGImage? {
        let px = Int(cell * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.monospacedSystemFont(ofSize: cell, weight: .medium)
        let string = String(char) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: c) ?? .green]
        let size = string.size(withAttributes: attributes)
        string.draw(at: CGPoint(x: (cell - size.width) / 2, y: (cell - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    override func update(_ dt: CGFloat) {
        for i in columns.indices {
            columns[i].head += columns[i].speed * dt
            if chance(dt * 2) { columns[i].glyphs[Int.random(in: 0..<rows)] = Int.random(in: Self.charset.indices) }
            if columns[i].head - columns[i].trail > CGFloat(rows) { columns[i] = newColumn(head: -rnd(0, 10)) }
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.fill(color(0x000300), bounds)
        // Gambar huruf sudah seukuran piksel tujuannya, jadi tidak perlu dihaluskan saat ditempel.
        ctx.interpolationQuality = .none
        let top = h - (h - CGFloat(rows) * cell) / 2
        for (c, column) in columns.enumerated() {
            for r in 0..<rows {
                let distance = column.head - CGFloat(r)
                guard distance >= 0, distance < column.trail else { continue }
                let images = distance < 1 ? white : green
                let glyph = column.glyphs[r] % images.count
                ctx.setAlpha(distance < 1 ? 1 : 0.9 * (1 - distance / column.trail))
                ctx.draw(images[glyph], in: CGRect(x: CGFloat(c) * cell, y: top - CGFloat(r + 1) * cell, width: cell, height: cell))
            }
        }
        ctx.setAlpha(1)
    }
}

// MARK: Game of Life

final class LifeScene: WallpaperScene {
    override var frameRate: Double { 10 }

    private let cell: CGFloat = 3
    private var cols = 0, rows = 0
    private var alive: [Bool] = []
    private var age: [Int] = []
    private var fade: [CGFloat] = []
    private var clock: CGFloat = 0
    private var history: [Int] = []

    override func layout() {
        cols = Int(w / cell)
        rows = Int(h / cell)
        alive = (0..<cols * rows).map { _ in chance(0.3) }
        age = Array(repeating: 0, count: cols * rows)
        fade = Array(repeating: 0, count: cols * rows)
        history = []
    }

    override func update(_ dt: CGFloat) {
        for i in fade.indices where !alive[i] && fade[i] > 0 { fade[i] = max(0, fade[i] - dt * 3) }
        clock += dt
        guard clock >= 0.12 else { return }
        clock = 0

        var next = alive
        for y in 0..<rows {
            for x in 0..<cols {
                var n = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        // Dunia melingkar: tepi kiri bersambung dengan kanan, atas dengan bawah.
                        if alive[((y + dy + rows) % rows) * cols + (x + dx + cols) % cols] { n += 1 }
                    }
                }
                let i = y * cols + x
                next[i] = alive[i] ? (n == 2 || n == 3) : n == 3
            }
        }
        for i in next.indices {
            if next[i] {
                age[i] = alive[i] ? age[i] + 1 : 0
                fade[i] = 1
            }
        }
        alive = next

        // Kalau dunia mulai diam (jumlah sel nyaris tidak berubah), taburkan sel baru di satu area.
        let population = alive.filter { $0 }.count
        history.append(population)
        if history.count > 40 { history.removeFirst() }
        if population < cols / 2 || (history.count == 40 && history.max()! - history.min()! <= 4) || chance(0.01) {
            let cx = Int.random(in: 0..<cols)
            for y in 0..<rows {
                for x in cx..<min(cols, cx + 24) where chance(0.4) { alive[y * cols + x] = true }
            }
            history = []
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.fill(color(0x04060C), bounds)
        let top = h - (h - CGFloat(rows) * cell) / 2
        for y in 0..<rows {
            for x in 0..<cols {
                let i = y * cols + x
                guard fade[i] > 0 else { continue }
                let t = min(1, CGFloat(age[i]) / 12)
                let c = NSColor(hue: 0.52 + 0.22 * t, saturation: 0.65, brightness: alive[i] ? 0.95 : 0.6,
                                alpha: alive[i] ? 0.9 : 0.5 * fade[i])
                ctx.fill(c.cgColor, CGRect(x: CGFloat(x) * cell + 0.3, y: top - CGFloat(y + 1) * cell + 0.3,
                                           width: cell - 0.6, height: cell - 0.6))
            }
        }
    }
}

// MARK: Kucing jalan-jalan

final class CatScene: WallpaperScene {
    override var frameRate: Double { 20 }

    private enum State { case walk, chase, sit, sleep }

    private var x: CGFloat = 100
    private var dir: CGFloat = 1
    private var target: CGFloat = 300
    private var state = State.walk
    private var timer: CGFloat = 0
    private var stride: CGFloat = 0
    private var fly = CGPoint(x: 400, y: 20)
    private var flyVelocity = CGVector(dx: 15, dy: 0)

    private let fur = color(0xE59A4B)
    private let stripe = color(0xB86E2C)

    override func layout() {
        x = min(x, w - 30)
        fly = CGPoint(x: rnd(40, w - 40), y: 20)
    }

    override func update(_ dt: CGFloat) {
        timer -= dt
        switch state {
        case .walk, .chase:
            if state == .chase { target = fly.x }
            let speed: CGFloat = state == .chase ? 42 : 18
            let distance = target - x
            if abs(distance) > 1 { dir = distance > 0 ? 1 : -1 }
            x += dir * min(abs(distance), speed * dt)
            stride += dt * (state == .chase ? 16 : 9)
            if abs(distance) < 2 || (state == .chase && (abs(fly.x - x) < 14 || timer <= 0)) { decide() }
        case .sit, .sleep:
            if timer <= 0 { walk(to: rnd(30, w - 30)) }
        }

        // Kupu-kupu terbang ke sana kemari dan menjauh kalau kucing mendekat.
        flyVelocity.dx += rnd(-1, 1) * 40 * dt
        flyVelocity.dy += rnd(-1, 1) * 30 * dt
        if state == .chase, abs(fly.x - x) < 40 { flyVelocity.dx += (fly.x > x ? 1 : -1) * 60 * dt }
        flyVelocity.dx = max(-30, min(30, flyVelocity.dx))
        flyVelocity.dy = max(-8, min(8, flyVelocity.dy))
        fly.x += flyVelocity.dx * dt
        fly.y += flyVelocity.dy * dt
        if fly.x < 20 || fly.x > w - 20 { flyVelocity.dx = -flyVelocity.dx; fly.x = max(20, min(w - 20, fly.x)) }
        if fly.y < 16 || fly.y > h - 4 { flyVelocity.dy = -flyVelocity.dy; fly.y = max(16, min(h - 4, fly.y)) }
    }

    private func walk(to newTarget: CGFloat) {
        state = .walk
        target = newTarget
    }

    private func decide() {
        let roll = CGFloat.random(in: 0..<1)
        if state != .chase, abs(fly.x - x) < 200, roll < 0.35 {
            state = .chase
            timer = 6
        } else if roll < 0.55 {
            state = .sit
            timer = rnd(3, 6)
        } else if roll < 0.75 {
            state = .sleep
            timer = rnd(8, 15)
        } else {
            walk(to: rnd(30, w - 30))
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.verticalGradient([color(0x120E1E), color(0x1C1424)], bounds)
        ctx.fill(color(0x2A2233), CGRect(x: 0, y: 0, width: w, height: 3))
        ctx.fill(color(0x3A3046), CGRect(x: 0, y: 3, width: w, height: 0.5))
        drawButterfly(ctx)
        switch state {
        case .walk, .chase: drawWalking(ctx)
        case .sit: drawSitting(ctx)
        case .sleep: drawSleeping(ctx)
        }
    }

    private func ears(_ ctx: CGContext, head: CGPoint, r: CGFloat) {
        ctx.setFillColor(fur)
        for side: CGFloat in [-1, 1] {
            let base = head.x + side * r * 0.55
            ctx.beginPath()
            ctx.move(to: CGPoint(x: base - r * 0.4, y: head.y + r * 0.6))
            ctx.addLine(to: CGPoint(x: base + side * r * 0.1, y: head.y + r * 1.45))
            ctx.addLine(to: CGPoint(x: base + r * 0.4, y: head.y + r * 0.6))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    private func face(_ ctx: CGContext, head: CGPoint, eyesClosed: Bool = false) {
        let eye = CGPoint(x: head.x + dir * 2.4, y: head.y + 0.8)
        let blinking = wrap(time, 4) < 0.15
        if eyesClosed || blinking {
            ctx.line(color(0x3A2410), 0.6, [CGPoint(x: eye.x - 1, y: eye.y), CGPoint(x: eye.x + 1, y: eye.y)])
        } else {
            ctx.fillEllipse(color(0x9BE564), eye, 1.1, 1.1)
            ctx.fillEllipse(color(0x101010), eye, 0.4, 0.8)
        }
        ctx.fillEllipse(color(0xFF9CB0), CGPoint(x: head.x + dir * 4.6, y: head.y - 0.6), 0.6, 0.5)
    }

    private func drawWalking(_ ctx: CGContext) {
        let bob = abs(sin(stride)) * 0.6
        // Ekor.
        ctx.setStrokeColor(fur)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x - dir * 9, y: 11 + bob))
        ctx.addQuadCurve(to: CGPoint(x: x - dir * 16, y: 19 + sin(time * 3) * 2), control: CGPoint(x: x - dir * 17, y: 10))
        ctx.strokePath()
        // Kaki: pasangan depan dan belakang melangkah bergantian.
        for (offset, phase) in [(-6.0, 0.0), (-3.5, CGFloat.pi), (4.0, CGFloat.pi), (6.5, 0.0)] as [(CGFloat, CGFloat)] {
            let hip = CGPoint(x: x + dir * offset, y: 8 + bob)
            ctx.line(offset == -3.5 || offset == 4 ? stripe : fur, 2, [hip, CGPoint(x: hip.x + dir * sin(stride + phase) * 2.5, y: 3.6)])
        }
        ctx.fillEllipse(fur, CGPoint(x: x, y: 10 + bob), 10, 4.6)
        for k in 0..<3 { ctx.fill(stripe, CGRect(x: x - 5 + CGFloat(k) * 3.5, y: 12 + bob, width: 1.2, height: 2.4)) }
        let head = CGPoint(x: x + dir * 10, y: 15 + bob)
        ears(ctx, head: head, r: 5)
        ctx.fillEllipse(fur, head, 5, 4.6)
        face(ctx, head: head)
    }

    private func drawSitting(_ ctx: CGContext) {
        ctx.setStrokeColor(fur)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x - dir * 5, y: 5))
        ctx.addQuadCurve(to: CGPoint(x: x + dir * 7, y: 4), control: CGPoint(x: x - dir * 13, y: 1 + sin(time * 2)))
        ctx.strokePath()
        ctx.fillEllipse(fur, CGPoint(x: x, y: 9.5), 6, 6.2)
        ctx.line(fur, 2, [CGPoint(x: x + dir * 3.5, y: 8), CGPoint(x: x + dir * 3.5, y: 3.6)])
        ctx.line(stripe, 2, [CGPoint(x: x + dir * 1, y: 8), CGPoint(x: x + dir * 1, y: 3.6)])
        let head = CGPoint(x: x + dir * 2, y: 18.5)
        ears(ctx, head: head, r: 5)
        ctx.fillEllipse(fur, head, 5, 4.6)
        face(ctx, head: head)
    }

    private func drawSleeping(_ ctx: CGContext) {
        let breath = sin(time * 1.6) * 0.4
        ctx.fillEllipse(fur, CGPoint(x: x, y: 7), 11, 3.8 + breath)
        ctx.line(fur, 2, [CGPoint(x: x - dir * 10, y: 5), CGPoint(x: x - dir * 4, y: 3.8), CGPoint(x: x + dir * 6, y: 3.8)])
        for k in 0..<3 { ctx.fill(stripe, CGRect(x: x - 6 + CGFloat(k) * 3.5, y: 8 + breath, width: 1.2, height: 2.2)) }
        let head = CGPoint(x: x + dir * 9, y: 8)
        ears(ctx, head: head, r: 4.4)
        ctx.fillEllipse(fur, head, 4.4, 4)
        face(ctx, head: head, eyesClosed: true)
        for k in 0..<3 {
            let t = wrap(time * 0.8 + CGFloat(k) * 0.33, 1)
            text("z", at: CGPoint(x: x + dir * 12 + CGFloat(k) * 3 + t * 4, y: 9 + t * 12), size: 5 + CGFloat(k) * 1.5,
                 color: color(0xC8C2FF, 0.8 * (1 - t)))
        }
    }

    private func drawButterfly(_ ctx: CGContext) {
        let flap = abs(sin(time * 14))
        for side: CGFloat in [-1, 1] {
            ctx.fillEllipse(color(0x7FD6FF, 0.9), CGPoint(x: fly.x + side * 1.6 * flap, y: fly.y + 0.8), 1.8 * flap + 0.3, 1.8)
            ctx.fillEllipse(color(0xFFB3E6, 0.9), CGPoint(x: fly.x + side * 1.2 * flap, y: fly.y - 1), 1.2 * flap + 0.2, 1.2)
        }
        ctx.fill(color(0x302030), CGRect(x: fly.x - 0.3, y: fly.y - 1.6, width: 0.6, height: 3))
    }
}

// MARK: Semut berbaris

final class AntsScene: WallpaperScene {
    override var frameRate: Double { 15 }

    private struct Ant {
        var x, speed, phase: CGFloat
        var lane: Int
        var load: CGColor?
    }

    private var ants: [Ant] = []
    private var specks: [CGPoint] = []
    // Kue dan sarang bergeser sedikit bolak-balik supaya tidak diam di piksel yang sama.
    private var cookieX: CGFloat { 26 + 8 * sin(time / 120) }
    private var hillX: CGFloat { w - 30 - 8 * sin(time / 140) }

    override func layout() {
        specks = (0..<Int(w / 4)).map { _ in CGPoint(x: rnd(0, w), y: rnd(0, h)) }
        ants = []
        for x in Swift.stride(from: cookieX + 20, to: hillX - 20, by: 26) {
            ants.append(newAnt(lane: 0, x: x + rnd(-6, 6)))
            ants.append(newAnt(lane: 1, x: x + rnd(-6, 6)))
        }
    }

    /// Jalur 0: membawa remah dari kue ke sarang (ke kanan). Jalur 1: kembali ke kue tanpa bawaan.
    private func newAnt(lane: Int, x: CGFloat? = nil) -> Ant {
        var load: CGColor?
        if lane == 0 { load = chance(0.12) ? color(0x5DBB4A) : color(0xE9C27A) }
        return Ant(x: x ?? (lane == 0 ? cookieX + 8 : hillX - 10), speed: rnd(14, 20), phase: rnd(0, 6), lane: lane, load: load)
    }

    private func laneY(_ lane: Int, _ x: CGFloat) -> CGFloat {
        (lane == 0 ? 9 : 19) + 2 * sin(x * 0.03 + CGFloat(lane) * 2)
    }

    override func update(_ dt: CGFloat) {
        for i in ants.indices {
            let dir: CGFloat = ants[i].lane == 0 ? 1 : -1
            ants[i].x += dir * ants[i].speed * dt
            ants[i].phase += dt * 22
        }
        ants.removeAll { ($0.lane == 0 && $0.x > hillX - 6) || ($0.lane == 1 && $0.x < cookieX + 6) }
        for lane in 0...1 where chance(dt * 1.6) {
            let start = lane == 0 ? cookieX + 8 : hillX - 10
            if !ants.contains(where: { $0.lane == lane && abs($0.x - start) < 9 }) { ants.append(newAnt(lane: lane)) }
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.fill(color(0x17110B), bounds)
        for (i, s) in specks.enumerated() {
            ctx.fill(color(i % 3 == 0 ? 0x3A2D1F : 0x251B12), CGRect(x: s.x, y: s.y, width: 1, height: 1))
        }

        // Kue di kiri, sudah digigit.
        let cookie = CGPoint(x: cookieX, y: 13)
        ctx.fillEllipse(color(0xC8945A), cookie, 10, 10)
        ctx.fillEllipse(color(0x17110B), CGPoint(x: cookie.x + 9, y: cookie.y + 6), 4, 4)
        for (dx, dy) in [(-4, 3), (2, -4), (-1, 5), (4, 1), (-5, -3)] as [(CGFloat, CGFloat)] {
            ctx.fillEllipse(color(0x4A2C17), CGPoint(x: cookie.x + dx, y: cookie.y + dy), 1.2, 1)
        }

        // Sarang di kanan.
        ctx.fillEllipse(color(0x6D4C33), CGPoint(x: hillX, y: 0), 22, 14)
        ctx.fillEllipse(color(0x0A0705), CGPoint(x: hillX - 2, y: 11), 3.2, 1.6)

        for ant in ants { drawAnt(ctx, ant) }
    }

    private func drawAnt(_ ctx: CGContext, _ ant: Ant) {
        let d: CGFloat = ant.lane == 0 ? 1 : -1
        let y = laneY(ant.lane, ant.x)
        let body = color(0x9A3B1C)
        let legs = color(0x7A3018)
        for k in [-1, 0, 1] as [CGFloat] {
            let swing = sin(ant.phase + k * 2) * 0.9
            let base = CGPoint(x: ant.x + k * 0.8, y: y)
            ctx.line(legs, 0.5, [base, CGPoint(x: base.x + k * 1.4 + swing, y: y + 2.4)])
            ctx.line(legs, 0.5, [base, CGPoint(x: base.x + k * 1.4 - swing, y: y - 2.4)])
        }
        ctx.line(legs, 0.4, [CGPoint(x: ant.x + d * 2.6, y: y + 0.4), CGPoint(x: ant.x + d * 4.2, y: y + 2)])
        ctx.line(legs, 0.4, [CGPoint(x: ant.x + d * 2.6, y: y - 0.2), CGPoint(x: ant.x + d * 4.2, y: y - 1.6)])
        ctx.fillEllipse(body, CGPoint(x: ant.x - d * 3, y: y), 2.1, 1.5)
        ctx.fillEllipse(body, CGPoint(x: ant.x, y: y), 1.2, 0.9)
        ctx.fillEllipse(body, CGPoint(x: ant.x + d * 2.3, y: y), 1.2, 1.1)
        if let load = ant.load {
            if load == color(0x5DBB4A) {
                // Kadang ada yang membawa daun, jauh lebih besar dari badannya.
                ctx.fillEllipse(load, CGPoint(x: ant.x + d * 1, y: y + 4), 4.5, 2.2)
                ctx.line(color(0x3C8A2E), 0.4, [CGPoint(x: ant.x - d * 3, y: y + 4), CGPoint(x: ant.x + d * 5, y: y + 4)])
            } else {
                ctx.fillEllipse(load, CGPoint(x: ant.x + d * 4, y: y + 0.5), 1.4, 1.2)
            }
        }
    }
}

// MARK: Ular (main sendiri)

final class SnakeScene: WallpaperScene {
    override var frameRate: Double { 15 }

    private struct Cell: Hashable { var x, y: Int }

    private let size5: CGFloat = 5
    private var cols = 0, rows = 0
    private var body: [Cell] = []
    private var food = Cell(x: 0, y: 0)
    private var clock: CGFloat = 0
    private var resetting: CGFloat = 0

    override func layout() {
        cols = Int(w / size5)
        rows = Int(h / size5)
        restart()
    }

    private func restart() {
        let y = rows / 2
        body = (0..<4).map { Cell(x: 10 - $0, y: y) }
        placeFood()
    }

    private func placeFood() {
        let occupied = Set(body)
        var cell: Cell
        repeat { cell = Cell(x: Int.random(in: 0..<cols), y: Int.random(in: 0..<rows)) } while occupied.contains(cell)
        food = cell
    }

    private func neighbors(_ c: Cell) -> [Cell] {
        [Cell(x: c.x + 1, y: c.y), Cell(x: c.x - 1, y: c.y), Cell(x: c.x, y: c.y + 1), Cell(x: c.x, y: c.y - 1)]
            .filter { $0.x >= 0 && $0.x < cols && $0.y >= 0 && $0.y < rows }
    }

    /// Langkah pertama jalur terpendek ke makanan (BFS), menghindari badan sendiri.
    private func pathStep(blocked: Set<Cell>) -> Cell? {
        guard let head = body.first else { return nil }
        var previous: [Cell: Cell] = [:]
        var queue = [head]
        var index = 0
        var seen: Set<Cell> = [head]
        while index < queue.count {
            let cur = queue[index]
            index += 1
            if cur == food {
                var step = cur
                while let p = previous[step], p != head { step = p }
                return step
            }
            for n in neighbors(cur) where !seen.contains(n) && !blocked.contains(n) {
                seen.insert(n)
                previous[n] = cur
                queue.append(n)
            }
        }
        return nil
    }

    /// Luas ruang kosong yang bisa dicapai dari sel ini.
    private func space(from start: Cell, blocked: Set<Cell>) -> Int {
        var seen: Set<Cell> = [start]
        var stack = [start]
        while let c = stack.popLast(), seen.count < 200 {
            for n in neighbors(c) where !seen.contains(n) && !blocked.contains(n) {
                seen.insert(n)
                stack.append(n)
            }
        }
        return seen.count
    }

    override func update(_ dt: CGFloat) {
        if resetting > 0 {
            resetting -= dt
            if resetting <= 0 { restart() }
            return
        }
        clock += dt
        guard clock >= 0.08 else { return }
        clock = 0
        guard let head = body.first else { return restart() }

        let blocked = Set(body.dropLast())
        var next = pathStep(blocked: blocked)
        // Jalur ke makanan tertutup, atau terlalu sempit: pilih arah dengan ruang kosong terluas.
        if next == nil || space(from: next!, blocked: blocked) < body.count {
            next = neighbors(head).filter { !blocked.contains($0) }.max { space(from: $0, blocked: blocked) < space(from: $1, blocked: blocked) } ?? next
        }
        guard let step = next else {
            resetting = 1.2
            return
        }
        body.insert(step, at: 0)
        if step == food {
            if body.count >= 80 {
                resetting = 1.2
            } else {
                placeFood()
            }
        } else {
            body.removeLast()
        }
    }

    private func rect(_ c: Cell, inset: CGFloat) -> CGRect {
        let top = h - (h - CGFloat(rows) * size5) / 2
        return CGRect(x: CGFloat(c.x) * size5, y: top - CGFloat(c.y + 1) * size5, width: size5, height: size5).insetBy(dx: inset, dy: inset)
    }

    override func draw(_ ctx: CGContext) {
        ctx.fill(color(0x050D07), bounds)
        let pulse = 0.6 + 0.4 * sin(time * 6)
        let f = rect(food, inset: 0)
        ctx.glow(color(0xFF4D5E, 0.6 * pulse), CGPoint(x: f.midX, y: f.midY), 6)
        ctx.fillEllipse(color(0xFF4D5E), CGPoint(x: f.midX, y: f.midY), 1.8, 1.8)

        let alpha = resetting > 0 ? max(0, resetting / 1.2) : 1
        for (i, c) in body.enumerated().reversed() {
            let t = CGFloat(i) / CGFloat(max(1, body.count - 1))
            let r = rect(c, inset: 0.5)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            ctx.setFillColor(NSColor(hue: 0.38 - 0.06 * t, saturation: 0.75, brightness: 0.95 - 0.5 * t, alpha: alpha).cgColor)
            ctx.fillPath()
        }
        if let head = body.first {
            let r = rect(head, inset: 0)
            ctx.fillEllipse(color(0x000000, alpha), CGPoint(x: r.midX + 0.8, y: r.midY + 0.9), 0.6, 0.6)
            ctx.fillEllipse(color(0x000000, alpha), CGPoint(x: r.midX + 0.8, y: r.midY - 0.9), 0.6, 0.6)
        }
    }
}

// MARK: Dino runner (main sendiri)

/// Dino berlari masuk dari kiri sampai ke tengah bar, lalu terus berlari di tengah sementara rintangan ala
/// Chrome Dino datang dari kanan: kaktus kecil (1–3) dan kaktus besar (1–2) dilompati; setelah skor 450 muncul
/// burung di tiga ketinggian: rendah dilompati, tengah ditunduki, tinggi lewat di atas kepala.
/// Posisi "tengah" bergeser pelan supaya dino tidak diam di piksel yang sama (layar OLED).
final class DinoScene: WallpaperScene {
    override var frameRate: Double { 30 }

    private static let body = [
        ".........########",
        "........##.######",
        "........#########",
        "........#########",
        "........#####....",
        "........#######..",
        "#......#####.....",
        "#.....#######.#..",
        "##...########....",
        "###.#########....",
        "#############....",
        ".###########.....",
        "..#########......",
        "...#######.......",
    ]
    private static let legs = [
        ["...###.##........", "...##....#......."],
        ["...##..###.......", "....#...##......."],
    ]
    private static let legsAir = ["...##..##........", "...##..##........"]
    private static let duck = [
        "............#######.",
        "#..........##.######",
        "##.........#########",
        "###################.",
        ".#################..",
        "..###########.......",
        "...#########........",
    ]
    private static let duckLegs = [
        ["...##..##...........", "...#....#..........."],
        ["....##.##...........", "........##.........."],
    ]
    private static let smallCactus = [
        "..#..", "..#.#", "#.#.#", "#.#.#", "#.###", "###..", "..#..", "..#..", "..#..", "..#..",
    ]
    private static let largeCactus = [
        "...#...", "..###..", "..###.#", "#.###.#", "#.###.#", "#.#####",
        "#.###..", "#####..", "..###..", "..###..", "..###..", "..###..",
    ]
    private static let bird = [
        ["....#.......", "....##......", "..#.###.....", ".##########.", "....#####..."],
        ["..#.........", ".##########.", "....#####...", "....##......", "....#......."],
    ]
    private static let cloud = ["....######....", "..##......##..", "##..........##", "##############"]

    private enum Kind {
        case smallCactus(count: Int)
        case largeCactus(count: Int)
        case bird(Altitude)
    }

    /// Ketinggian burung: rendah dilompati, tengah ditunduki, tinggi dibiarkan lewat.
    private enum Altitude: CaseIterable {
        case low, middle, high

        var y: CGFloat {
            switch self {
            case .low: return 1.8
            case .middle: return 11
            case .high: return 19.5
            }
        }
    }

    private struct Obstacle {
        var x: CGFloat
        var kind: Kind
        var passed = false

        var width: CGFloat {
            switch kind {
            case .smallCactus(let count): return CGFloat(count) * 5.5 - 0.5
            case .largeCactus(let count): return CGFloat(count) * 7.5 - 0.5
            case .bird: return 12
            }
        }

        /// Rintangan yang harus dilompati.
        var mustJump: Bool {
            switch kind {
            case .smallCactus, .largeCactus, .bird(.low): return true
            case .bird: return false
            }
        }
    }

    private let dinoWidth: CGFloat = 17
    /// Tanah sengaja rendah supaya kaktus besar tetap bisa dilompati di Touch Bar setinggi 30 pt.
    private let ground: CGFloat = 0.5
    /// Lompatan setinggi 12,7 pt; puncaknya dicapai 0,29 detik setelah melompat.
    private let jumpSpeed: CGFloat = 87.3
    private let gravity: CGFloat = 300
    private var apexTime: CGFloat { jumpSpeed / gravity }

    /// Tepi kiri dino; mulai di luar layar kiri, lalu berlari masuk sampai ke tengah.
    private var dinoX: CGFloat = -24
    private var arrived = false
    private var jump: CGFloat = 0
    private var jumpVelocity: CGFloat = 0
    private var ducking = false
    private var speed: CGFloat = 130
    private var distance: CGFloat = 0
    /// Jarak tempuh sejak dino sampai di tengah; skor ala Chrome sekitar 10 poin per detik di awal.
    private var run: CGFloat = 0
    private var score: Int { Int(run / 13) }
    private var obstacles: [Obstacle] = []
    private var clouds: [CGPoint] = []

    /// Titik tengah tempat dino berlari, bergeser ±40 pt dalam hitungan menit.
    private var home: CGFloat { (w - dinoWidth) / 2 + 40 * sin(time / 90) }

    override func layout() {
        clouds = (0..<Int(w / 200) + 1).map { _ in CGPoint(x: rnd(0, w), y: rnd(20, 25)) }
    }

    private func randomObstacle() -> Kind {
        let roll = CGFloat.random(in: 0..<1)
        // Burung baru muncul setelah skor 450, seperti di Chrome.
        if score >= 450, roll < 0.25 { return .bird(Altitude.allCases.randomElement()!) }
        return roll < 0.65 ? .smallCactus(count: [1, 1, 2, 3].randomElement()!) : .largeCactus(count: [1, 1, 2].randomElement()!)
    }

    override func update(_ dt: CGFloat) {
        distance += speed * dt
        for i in clouds.indices {
            clouds[i].x -= speed * 0.08 * dt
            if clouds[i].x < -20 { clouds[i] = CGPoint(x: w + rnd(0, 100), y: rnd(20, 25)) }
        }

        // Masuk dari kiri lebih cepat dari jalannya dunia, lalu mengikuti titik tengah yang bergeser pelan.
        if arrived {
            dinoX += (home - dinoX) * min(1, dt * 2)
        } else {
            dinoX += 90 * dt
            if dinoX >= home { arrived = true }
        }

        // Rintangan baru muncul dari kanan setelah dino sampai di tengah.
        if arrived {
            run += speed * dt
            speed = min(210, speed + dt * 0.4)
            for i in obstacles.indices { obstacles[i].x -= speed * dt }
            obstacles.removeAll { $0.x < -30 }
            if (obstacles.last?.x ?? -.infinity) < w - rnd(170, 360) {
                obstacles.append(Obstacle(x: w + 10, kind: randomObstacle()))
            }
            for i in obstacles.indices where !obstacles[i].passed && obstacles[i].x + obstacles[i].width < dinoX {
                obstacles[i].passed = true
            }
        }

        let feet = dinoX + 6.5
        ducking = false
        for o in obstacles where o.x + o.width > dinoX - 2 {
            if o.mustJump {
                // Puncak lompatan tepat saat kaki di atas tengah rintangan.
                let center = o.x + o.width / 2
                if jump == 0, jumpVelocity == 0, center - feet <= speed * apexTime, center > feet { jumpVelocity = jumpSpeed }
            } else if case .bird(.middle) = o.kind, o.x - (dinoX + 20) < speed * 0.25 {
                ducking = true
            }
        }
        if jumpVelocity != 0 || jump > 0 {
            jump += jumpVelocity * dt
            jumpVelocity -= gravity * dt
            if jump <= 0 {
                jump = 0
                jumpVelocity = 0
            }
        }
    }

    override func draw(_ ctx: CGContext) {
        let ink = color(0xBDBDBD)
        ctx.fill(color(0x000000), bounds)
        for c in clouds { ctx.pixels(Self.cloud, at: c, scale: 1, color: color(0x3A3A3A)) }

        // Garis tanah selebar bar selalu ada, jadi dibuat lebih redup dari dino dan rintangan.
        ctx.fill(color(0x6E6E6E), CGRect(x: 0, y: ground, width: w, height: 0.8))
        let first = Int(floor(distance / 7))
        for k in first...(first + Int(w / 7) + 1) where hash(k) < 0.35 {
            let x = CGFloat(k) * 7 - distance
            ctx.fill(color(0x4A4A4A), CGRect(x: x, y: 0, width: hash(k + 3) < 0.5 ? 1 : 2, height: 0.4))
        }

        for o in obstacles {
            switch o.kind {
            case .smallCactus(let count):
                for j in 0..<count {
                    ctx.pixels(Self.smallCactus, at: CGPoint(x: o.x + CGFloat(j) * 5.5, y: ground), scale: 1, color: ink)
                }
            case .largeCactus(let count):
                for j in 0..<count {
                    ctx.pixels(Self.largeCactus, at: CGPoint(x: o.x + CGFloat(j) * 7.5, y: ground), scale: 1, color: ink)
                }
            case .bird(let altitude):
                ctx.pixels(Self.bird[Int(time * 6) % 2], at: CGPoint(x: o.x, y: altitude.y), scale: 1, color: ink)
            }
        }

        let step = Int(distance / 12) % 2
        let base = CGPoint(x: dinoX, y: ground + 0.8 + jump)
        if ducking, jump == 0 {
            ctx.pixels(Self.duck + Self.duckLegs[step], at: base, scale: 1, color: ink)
        } else {
            ctx.pixels(Self.body + (jump > 0 ? Self.legsAir : Self.legs[step]), at: base, scale: 1, color: ink)
        }

        text(String(format: "%05d", score % 100_000), at: CGPoint(x: w - 40 - 30 * (1 + sin(time / 150)), y: h - 10), size: 8,
             color: color(0x5A5A5A), mono: true)
    }
}

// MARK: Teks sendiri

extension WallpaperTheme {
    /// Teks untuk tema "Teks sendiri", misalnya nama atau inisial.
    static var customText: String {
        get {
            let value = UserDefaults.standard.string(forKey: "wallpaperText")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "Lyricsbar" : value
        }
        set { UserDefaults.standard.set(newValue, forKey: "wallpaperText") }
    }
}

/// Teks dot-matrix hitam putih ala Nothing: huruf tersusun dari titik bulat di atas kisi titik redup.
/// Muncul (pindai, berkelip, atau jatuh), diam sambil disapu kilau, lalu hilang dan muncul lagi di posisi
/// lain supaya layar OLED tidak burn-in. Teks yang terlalu panjang berjalan seperti papan running text.
final class TextScene: WallpaperScene {
    override var frameRate: Double { 30 }

    private struct Dot {
        /// Kolom (relatif ke awal teks) dan baris (0 = paling atas).
        var col, row: Int
        var enterDelay, exitDelay: CGFloat
    }

    private enum Phase { case enter, hold, exit, pause }
    private enum Enter: CaseIterable { case scan, sparkle, drop }
    private enum Exit: CaseIterable { case dissolve, scan, fall }

    private let string: String
    private let rows = 8
    private var cols = 0
    private var pitch: CGFloat = 3.75
    private var inset: CGFloat = 0
    private var dots: [Dot] = []
    private var textWidth = 0
    private var offset = 0
    private var marquee = false
    private var marqueeClock: CGFloat = 0
    private var phase = Phase.enter
    private var phaseTime: CGFloat = 0
    private var enter = Enter.scan
    private var exit = Exit.dissolve
    private var grid: CGImage?

    init(text: String) {
        string = text
    }

    override func layout() {
        pitch = h / CGFloat(rows)
        cols = Int(w / pitch)
        inset = (w - CGFloat(cols) * pitch) / 2

        var col = 0
        dots = []
        for glyph in Self.glyphs(for: string) {
            for (r, line) in glyph.enumerated() {
                for (c, ch) in line.enumerated() where ch == "#" {
                    dots.append(Dot(col: col + c, row: r, enterDelay: 0, exitDelay: 0))
                }
            }
            col += (glyph.first?.count ?? 0) + 1
        }
        textWidth = max(0, col - 1)
        marquee = textWidth > cols - 6
        offset = marquee ? cols : 0
        grid = makeGrid()
        startEnter()
    }

    /// Kisi titik redup selebar Touch Bar, digambar sekali.
    private func makeGrid() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(w * 2), height: Int(h * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(color(0xFFFFFF, 0.07))
        for r in 0..<rows {
            for c in 0..<cols { ctx.fillEllipse(in: dotRect(col: c, row: r, scale: 1)) }
        }
        return ctx.makeImage()
    }

    private func dotRect(col: Int, row: Int, scale: CGFloat) -> CGRect {
        let d = pitch * 0.66 * scale
        let cx = inset + (CGFloat(col) + 0.5) * pitch, cy = (CGFloat(rows - 1 - row) + 0.5) * pitch
        return CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
    }

    private func startEnter() {
        phase = .enter
        phaseTime = 0
        enter = Enter.allCases.randomElement()!
        exit = Exit.allCases.randomElement()!
        if !marquee { offset = Int.random(in: 2...max(2, cols - textWidth - 2)) }
        for i in dots.indices {
            let along = CGFloat(dots[i].col)
            switch enter {
            case .scan: dots[i].enterDelay = along * 0.03
            case .sparkle: dots[i].enterDelay = rnd(0, 1.2)
            case .drop: dots[i].enterDelay = along * 0.02 + rnd(0, 0.3)
            }
            switch exit {
            case .dissolve: dots[i].exitDelay = rnd(0, 1)
            case .scan: dots[i].exitDelay = along * 0.03
            case .fall: dots[i].exitDelay = along * 0.015 + rnd(0, 0.4)
            }
        }
    }

    private var enterDuration: CGFloat { (dots.map(\.enterDelay).max() ?? 0) + (enter == .drop ? 0.6 : 0.2) }
    private var exitDuration: CGFloat { (dots.map(\.exitDelay).max() ?? 0) + (exit == .fall ? 0.6 : 0.2) }

    override func update(_ dt: CGFloat) {
        phaseTime += dt
        if marquee {
            // Bergeser satu kolom setiap langkah, seperti papan running text.
            marqueeClock += dt
            while marqueeClock >= 1.0 / 14 {
                marqueeClock -= 1.0 / 14
                offset -= 1
                if offset < -textWidth { offset = cols }
            }
            return
        }
        switch phase {
        case .enter: if phaseTime > enterDuration { phase = .hold; phaseTime = 0 }
        case .hold: if phaseTime > 5 { phase = .exit; phaseTime = 0 }
        case .exit: if phaseTime > exitDuration { phase = .pause; phaseTime = 0 }
        case .pause: if phaseTime > 0.8 { startEnter() }
        }
    }

    /// Posisi baris dan kecerahan satu titik saat ini; nil = tidak tampil.
    private func state(_ dot: Dot) -> (row: Int, alpha: CGFloat)? {
        let t = phaseTime
        if marquee { return (dot.row, 0.92) }
        switch phase {
        case .enter:
            let local = t - dot.enterDelay
            guard local >= 0 else { return nil }
            if enter == .drop {
                // Jatuh dari atas, melompat per baris kisi.
                return (min(dot.row, -1 + Int(local * 18)), 0.92)
            }
            return (dot.row, 0.92 * min(1, local / (enter == .sparkle ? 0.08 : 0.12)))
        case .hold:
            return (dot.row, 0.92)
        case .exit:
            let local = t - dot.exitDelay
            guard local >= 0 else { return (dot.row, 0.92) }
            if exit == .fall {
                let row = dot.row + Int(local * 18)
                return row < rows ? (row, 0.92) : nil
            }
            let alpha = 0.92 * (1 - min(1, local / 0.1))
            return alpha > 0 ? (dot.row, alpha) : nil
        case .pause:
            return nil
        }
    }

    override func draw(_ ctx: CGContext) {
        ctx.fill(color(0x000000), bounds)
        if let grid { ctx.draw(grid, in: bounds) }

        // Kilau: satu kolom terang yang menyapu teks, dan sesekali titik berkedip seperti glitch.
        let sweep = phase == .hold || marquee ? wrap(time * 22, CGFloat(textWidth + 30)) - 10 : -100
        let tick = Int(time * 8)
        for (i, dot) in dots.enumerated() {
            guard let s = state(dot), s.row >= 0 else { continue }
            let col = offset + dot.col
            guard col >= 0, col < cols else { continue }
            let shine = max(0, 1 - abs(CGFloat(dot.col) - sweep) / 3)
            var alpha = min(1, s.alpha + shine * 0.08)
            if phase == .hold, hash(i * 31 + tick) < 0.006 { alpha *= 0.25 }
            ctx.setFillColor(color(0xFFFFFF, alpha))
            ctx.fillEllipse(in: dotRect(col: col, row: s.row, scale: 1 + shine * 0.15))
        }
    }

    // MARK: Huruf dot-matrix 5×7 (huruf kecil memakai baris ke-8 untuk ekor g, j, p, q, y)

    private static func glyphs(for text: String) -> [[String]] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.map { ch -> [String] in
            let upper = ch.uppercased()
            let rows = font[ch] ?? (upper.count == 1 ? font[Character(upper)] : nil) ?? font["?"]!
            let width = rows.first?.count ?? 0
            return rows + Array(repeating: String(repeating: ".", count: width), count: max(0, 8 - rows.count))
        }
    }

    private static let font: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": ["###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"],
        "J": ["..###", "...#.", "...#.", "...#.", "#..#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],

        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####", "....."],
        "b": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####.", "....."],
        "c": [".....", ".....", ".###.", "#....", "#....", "#....", ".###.", "....."],
        "d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####", "....."],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###.", "....."],
        "f": ["..##", ".#..", "###.", ".#..", ".#..", ".#..", ".#..", "...."],
        "g": [".....", ".....", ".####", "#...#", "#...#", ".####", "....#", ".###."],
        "h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#", "....."],
        "i": [".#.", "...", "##.", ".#.", ".#.", ".#.", "###", "..."],
        "j": ["..#", "...", ".##", "..#", "..#", "..#", "..#", "##."],
        "k": ["#...", "#...", "#..#", "#.#.", "##..", "#.#.", "#..#", "...."],
        "l": ["##.", ".#.", ".#.", ".#.", ".#.", ".#.", "###", "..."],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#", "....."],
        "n": [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#", "....."],
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###.", "....."],
        "p": [".....", ".....", "####.", "#...#", "#...#", "####.", "#....", "#...."],
        "q": [".....", ".....", ".####", "#...#", "#...#", ".####", "....#", "....#"],
        "r": ["....", "....", "#.##", "##..", "#...", "#...", "#...", "...."],
        "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####.", "....."],
        "t": [".#..", ".#..", "###.", ".#..", ".#..", ".#..", "..##", "...."],
        "u": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####", "....."],
        "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#..", "....."],
        "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#.", "....."],
        "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
        "y": [".....", ".....", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
        "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####", "....."],

        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": [".#.", "##.", ".#.", ".#.", ".#.", ".#.", "###"],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],

        " ": ["...", "...", "...", "...", "...", "...", "..."],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        ",": ["..", "..", "..", "..", "..", ".#", ".#", "#."],
        "!": ["#", "#", "#", "#", "#", ".", "#"],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "-": ["....", "....", "....", "####", "....", "....", "...."],
        "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
        ":": [".", ".", "#", ".", ".", "#", "."],
        "'": ["#", "#", ".", ".", ".", ".", "."],
        "\"": ["#.#", "#.#", "...", "...", "...", "...", "..."],
        "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
        "/": ["....#", "...#.", "...#.", "..#..", ".#...", ".#...", "#...."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        "(": [".#", "#.", "#.", "#.", "#.", "#.", ".#"],
        ")": ["#.", ".#", ".#", ".#", ".#", ".#", "#."],
        "#": [".#.#.", "#####", ".#.#.", ".#.#.", ".#.#.", "#####", ".#.#."],
        "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
        "*": [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],
        "♥": [".#.#.", "#####", "#####", "#####", ".###.", "..#..", "....."],
        "♪": ["..##", "..#.", "..#.", "..#.", ".##.", "###.", ".#.."],
    ]
}

// MARK: Cuaca hari ini

/// Langit hitam putih yang mengikuti cuaca saat ini di lokasi MacBook: matahari atau bulan, awan, hujan, salju,
/// kabut, atau petir, bergerak searah angin. Suhu dan nama kota tampil di kanan.
///
/// Bisa dimainkan dengan menggeser jari: awan ikut terdorong, payung muncul menahan hujan, salju menyingkir,
/// kabut tersapu, matahari/bulan bisa dipindah, dan saat badai kilat menyambar di bawah jari.
final class WeatherScene: WallpaperScene {
    override var frameRate: Double { 24 }

    private struct Cloud {
        var x, y, scale: CGFloat
        var puffs: [(dx: CGFloat, dy: CGFloat, r: CGFloat)]
    }

    private struct Drop { var x, y, speed, length: CGFloat }
    private struct Flake { var x, y, r, speed, phase: CGFloat }

    /// Cuaca tetap untuk uji tampilan; nil = cuaca asli dari WeatherService.
    var override: Weather?

    private var clouds: [Cloud] = []
    private var drops: [Drop] = []
    private var splashes: [(x: CGFloat, y: CGFloat, age: CGFloat)] = []
    private var flakes: [Flake] = []
    private var stars: [CGPoint] = []
    private var shown: (WeatherCondition, Bool)?
    private var refreshClock: CGFloat = 0
    private var flash: CGFloat = 0
    private var bolt: [CGPoint] = []
    private var boltLife: CGFloat = 0
    private var nextStrike: CGFloat = 2

    private var bodyX: CGFloat = 0
    /// Posisi matahari/bulan yang tampil: titik pilihan (bodyX) ditambah geseran pelan supaya tidak membekas di OLED.
    private var bodyCenterX: CGFloat { bodyX + 50 * sin(time / 200) }
    private var touchX: CGFloat?
    private var lastTouchX: CGFloat = 0
    private var holdingBody = false
    /// Bekas sapuan jari di kabut, perlahan tertutup lagi.
    private var fogHoles: [(x: CGFloat, life: CGFloat)] = []

    private let umbrellaRadius: CGFloat = 13
    private let umbrellaTop: CGFloat = 20

    private var weather: Weather? { override ?? WeatherService.shared.current }
    private var condition: WeatherCondition { weather?.condition ?? .clear }
    private var isDay: Bool { weather?.isDay ?? false }
    private var showsBody: Bool { [.clear, .partlyCloudy, .snow, .fog].contains(condition) }
    private var isRainy: Bool { [.drizzle, .rain, .heavyRain, .thunder].contains(condition) }

    /// Angin dalam pt/detik ke kanan (+) atau kiri (−). Arah angin = arah datangnya, jadi angin dari barat bertiup ke kanan.
    private var wind: CGFloat {
        guard let weather else { return 6 }
        let toward = (weather.windDirection + 180) * .pi / 180
        let direction: CGFloat = sin(toward) >= 0 ? 1 : -1
        return direction * (4 + CGFloat(min(weather.windSpeed, 60)) * 0.8)
    }

    override func layout() {
        stars = (0..<80).map { _ in CGPoint(x: rnd(0, w), y: rnd(6, h - 1)) }
        bodyX = w * 0.16
        rebuild()
    }

    private func rebuild() {
        shown = (condition, isDay)
        let cloudCount: Int
        switch condition {
        case .clear: cloudCount = 1
        case .partlyCloudy: cloudCount = Int(w / 160)
        case .fog: cloudCount = 0
        case .snow: cloudCount = Int(w / 110)
        case .cloudy, .drizzle, .rain, .heavyRain, .thunder: cloudCount = Int(w / 70)
        }
        clouds = (0..<cloudCount).map { _ in newCloud(x: rnd(-40, w + 40)) }

        let dropCount: Int
        switch condition {
        case .drizzle: dropCount = Int(w / 9)
        case .rain: dropCount = Int(w / 5)
        case .heavyRain, .thunder: dropCount = Int(w / 3)
        default: dropCount = 0
        }
        drops = (0..<dropCount).map { _ in newDrop(anywhere: true) }
        flakes = condition == .snow ? (0..<Int(w / 7)).map { _ in newFlake(anywhere: true) } : []
    }

    private func newCloud(x: CGFloat) -> Cloud {
        let scale = rnd(0.6, 1.25)
        let puffs = (0..<Int.random(in: 4...7)).map { _ in (dx: rnd(-14, 14), dy: rnd(-2, 3), r: rnd(4, 8)) }
        let heavy = [.rain, .heavyRain, .thunder, .cloudy, .drizzle].contains(condition)
        return Cloud(x: x, y: heavy ? rnd(h - 8, h + 2) : rnd(12, h - 4), scale: scale, puffs: puffs)
    }

    private func newDrop(anywhere: Bool) -> Drop {
        let heavy = condition == .heavyRain || condition == .thunder
        return Drop(x: rnd(-20, w + 20), y: anywhere ? rnd(0, h) : h + rnd(0, 10),
                    speed: condition == .drizzle ? rnd(50, 75) : rnd(95, heavy ? 170 : 140),
                    length: condition == .drizzle ? rnd(1.5, 2.5) : rnd(3, heavy ? 7 : 5))
    }

    private func newFlake(anywhere: Bool) -> Flake {
        Flake(x: rnd(0, w), y: anywhere ? rnd(0, h) : h + 2, r: rnd(0.5, 1.3), speed: rnd(5, 12), phase: rnd(0, 6))
    }

    private func strike(at x: CGFloat) {
        flash = 1
        boltLife = 0.25
        var bx = x
        bolt = (0...7).map { k in
            if k > 0 { bx += rnd(-7, 7) }
            return CGPoint(x: bx, y: h - CGFloat(k) * h / 7)
        }
    }

    // MARK: Sentuhan

    override var isInteractive: Bool { true }

    override func touchBegan(at x: CGFloat) {
        touchX = x
        lastTouchX = x
        holdingBody = showsBody && abs(x - bodyCenterX) < 30
        if condition == .thunder { strike(at: x) }
    }

    override func touchMoved(to x: CGFloat) {
        let dx = x - lastTouchX
        lastTouchX = x
        touchX = x
        if holdingBody { bodyX = max(12, min(w - 160, x)) - (bodyCenterX - bodyX) }
        // Awan di dekat jari ikut terdorong.
        for i in clouds.indices where abs(clouds[i].x - x) < 45 { clouds[i].x += dx * 0.8 }
        if condition == .fog { fogHoles.append((x, 1)) }
    }

    override func touchEnded() {
        touchX = nil
        holdingBody = false
    }

    /// Ketinggian atap payung di posisi x (nil = di luar payung).
    private func umbrella(at x: CGFloat) -> CGFloat? {
        guard isRainy, let tx = touchX, abs(x - tx) < umbrellaRadius else { return nil }
        let t = (x - tx) / umbrellaRadius
        return umbrellaTop - 5 + 5 * sqrt(max(0, 1 - t * t))
    }

    // MARK: Gerak

    override func update(_ dt: CGFloat) {
        refreshClock -= dt
        if refreshClock <= 0, override == nil {
            refreshClock = 30
            WeatherService.shared.refreshIfNeeded()
        }
        if let shown, shown.0 != condition || shown.1 != isDay { rebuild() }

        let wind = self.wind
        for i in clouds.indices {
            clouds[i].x += wind * (0.5 + clouds[i].scale * 0.4) * dt
            if clouds[i].x > w + 50 { clouds[i] = newCloud(x: -50) }
            if clouds[i].x < -50 { clouds[i] = newCloud(x: w + 50) }
        }
        for i in drops.indices {
            drops[i].y -= drops[i].speed * dt
            drops[i].x += wind * 0.6 * dt
            if let roof = umbrella(at: drops[i].x), drops[i].y <= roof, drops[i].y > roof - 6 {
                // Tertahan payung: memercik di atapnya.
                if chance(0.5) { splashes.append((drops[i].x, roof, 0)) }
                drops[i] = newDrop(anywhere: false)
            } else if drops[i].y < 1 {
                if chance(0.4) { splashes.append((drops[i].x, 0, 0)) }
                drops[i] = newDrop(anywhere: false)
            }
        }
        for i in splashes.indices { splashes[i].age += dt }
        splashes.removeAll { $0.age > 0.25 }
        for i in flakes.indices {
            var f = flakes[i]
            f.y -= f.speed * dt
            f.phase += dt * 1.5
            var push: CGFloat = 0
            if let tx = touchX, abs(f.x - tx) < 32 { push = (f.x >= tx ? 1 : -1) * 140 * (1 - abs(f.x - tx) / 32) }
            f.x = wrap(f.x + (wind * 0.5 + sin(f.phase) * 6 + push) * dt, w)
            if f.y < 0.5 { f = newFlake(anywhere: false) }
            flakes[i] = f
        }
        for i in fogHoles.indices { fogHoles[i].life -= dt * 0.3 }
        fogHoles.removeAll { $0.life <= 0 }
        if fogHoles.count > 300 { fogHoles.removeFirst(fogHoles.count - 300) }

        flash = max(0, flash - dt * 3)
        boltLife = max(0, boltLife - dt)
        if condition == .thunder {
            nextStrike -= dt
            if nextStrike <= 0 {
                nextStrike = rnd(4, 10)
                strike(at: rnd(80, w * 0.7))
            }
        }
    }

    // MARK: Gambar

    override func draw(_ ctx: CGContext) {
        let c = condition
        let sky: [UInt32] = isDay ? [0x111111, 0x262626] : [0x000000, 0x0A0A0A]
        ctx.verticalGradient(sky.map { color($0) }, bounds)
        if flash > 0 { ctx.fill(color(0xFFFFFF, 0.35 * flash), bounds) }

        let clearSky = c == .clear || c == .partlyCloudy
        if !isDay, clearSky {
            for (i, star) in stars.enumerated() {
                // Bintang di dekat jari berkelip lebih terang.
                let near = touchX.map { max(0, 1 - abs(star.x - $0) / 70) } ?? 0
                let alpha = 0.3 + 0.3 * sin(time * 1.7 + CGFloat(i)) + 0.7 * near
                if near > 0.3 { ctx.glow(color(0xFFFFFF, 0.5 * near), star, 2 + 3 * near) }
                ctx.fill(color(0xFFFFFF, min(1, alpha)), CGRect(x: star.x - near * 0.6, y: star.y - near * 0.6, width: 0.8 + 1.2 * near, height: 0.8 + 1.2 * near))
            }
        }
        if showsBody { drawBody(ctx, faded: c == .fog) }

        let cloudColor = isRainy || c == .cloudy ? color(0x9A9A9A, isDay ? 0.32 : 0.22) : color(0xFFFFFF, isDay ? 0.24 : 0.14)
        for cloud in clouds {
            for p in cloud.puffs {
                ctx.fillEllipse(cloudColor, CGPoint(x: cloud.x + p.dx * cloud.scale, y: cloud.y + p.dy * cloud.scale),
                                p.r * cloud.scale * 1.4, p.r * cloud.scale)
            }
        }

        if boltLife > 0 {
            let a = boltLife / 0.25
            ctx.line(color(0xFFFFFF, 0.35 * a), 3, bolt)
            ctx.line(color(0xFFFFFF, a), 1.1, bolt)
        }
        if !drops.isEmpty {
            ctx.setStrokeColor(color(0xFFFFFF, c == .drizzle ? 0.4 : 0.55))
            ctx.setLineWidth(c == .drizzle ? 0.5 : 0.7)
            ctx.beginPath()
            let slant = wind * 0.6 / 140
            for d in drops {
                ctx.move(to: CGPoint(x: d.x, y: d.y))
                ctx.addLine(to: CGPoint(x: d.x - slant * d.length, y: d.y + d.length))
            }
            ctx.strokePath()
            for s in splashes {
                let r = s.age * 16, y = s.y + 0.8 + s.age * 8 - s.age * s.age * 32, a = 0.7 * (1 - s.age / 0.25)
                ctx.fill(color(0xFFFFFF, a), CGRect(x: s.x - r, y: y, width: 0.8, height: 0.8))
                ctx.fill(color(0xFFFFFF, a), CGRect(x: s.x + r, y: y, width: 0.8, height: 0.8))
            }
        }
        if isRainy, let tx = touchX { drawUmbrella(ctx, at: tx) }
        for f in flakes { ctx.fillEllipse(color(0xFFFFFF, 0.85), CGPoint(x: f.x, y: f.y), f.r, f.r) }
        if c == .fog { drawFog(ctx) }

        drawInfo(ctx)
    }

    private func drawBody(_ ctx: CGContext, faded: Bool) {
        let body = CGPoint(x: bodyCenterX, y: 17)
        let strength: CGFloat = faded ? 0.35 : 1
        let held: CGFloat = holdingBody ? 1 : 0
        if isDay {
            ctx.glow(color(0xFFFFFF, 0.22 * strength + 0.1 * held), body, 30 + 6 * held)
            ctx.saveGState()
            ctx.translateBy(x: body.x, y: body.y)
            ctx.rotate(by: time * (0.15 + 0.6 * held))
            for k in 0..<12 {
                let a = CGFloat(k) * .pi / 6
                let outer: CGFloat = 13 + 2 * held
                ctx.line(color(0xFFFFFF, 0.6 * strength), 1.2, [CGPoint(x: cos(a) * 9.5, y: sin(a) * 9.5), CGPoint(x: cos(a) * outer, y: sin(a) * outer)])
            }
            ctx.restoreGState()
            ctx.fillEllipse(color(0xFFFFFF, strength), body, 7, 7)
        } else {
            ctx.glow(color(0xFFFFFF, 0.18 + 0.12 * held), body, 16 + 4 * held)
            ctx.fillEllipse(color(0xFFFFFF, 0.95 * strength), body, 5.5, 5.5)
            ctx.fillEllipse(color(0x050505), CGPoint(x: body.x + 2.5, y: body.y + 1.5), 4.6, 4.6)
        }
    }

    private func drawUmbrella(_ ctx: CGContext, at x: CGFloat) {
        let r = umbrellaRadius, top = umbrellaTop
        ctx.setFillColor(color(0xFFFFFF, 0.92))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x - r, y: top - 5))
        ctx.addQuadCurve(to: CGPoint(x: x + r, y: top - 5), control: CGPoint(x: x, y: top + 5))
        // Tepi bawah bergelombang seperti payung.
        for k in stride(from: 3, through: 0, by: -1) {
            let right = x - r + CGFloat(k + 1) * r / 2, left = x - r + CGFloat(k) * r / 2
            ctx.addQuadCurve(to: CGPoint(x: left, y: top - 5), control: CGPoint(x: (left + right) / 2, y: top - 3))
        }
        ctx.closePath()
        ctx.fillPath()
        ctx.line(color(0xFFFFFF, 0.92), 0.9, [CGPoint(x: x, y: top - 4), CGPoint(x: x, y: 5)])
        ctx.setStrokeColor(color(0xFFFFFF, 0.92))
        ctx.setLineWidth(0.9)
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: x - 2, y: 5), radius: 2, startAngle: 0, endAngle: .pi, clockwise: true)
        ctx.strokePath()
    }

    private func drawFog(_ ctx: CGContext) {
        let step: CGFloat = 4
        var x: CGFloat = 0
        while x < w {
            let clear = fogHoles.reduce(CGFloat(0)) { max($0, $1.life * max(0, 1 - abs(x - $1.x) / 24)) }
            let visible = 1 - min(1, clear)
            if visible > 0.02 {
                for k in 0..<3 {
                    let wave = 0.6 + 0.4 * sin(x * 0.012 + time * (0.2 + CGFloat(k) * 0.07) + CGFloat(k) * 2)
                    ctx.fill(color(0xFFFFFF, 0.09 * wave * visible), CGRect(x: x, y: 2 + CGFloat(k) * 8.5, width: step, height: 9))
                }
            }
            x += step
        }
    }

    /// Suhu, kondisi, dan nama kota di kanan; bergeser pelan supaya tidak membekas di layar OLED.
    private func drawInfo(_ ctx: CGContext) {
        let right = w - 14 - 70 * (1 + sin(time / 180))
        let primary = NSColor(white: 1, alpha: 0.85)
        let secondary = NSColor(white: 1, alpha: 0.55)
        // Bayangan lembut di belakang tulisan supaya tetap terbaca di atas awan.
        if let shade = CGGradient(colorsSpace: sRGB, colors: [color(0x000000, 0), color(0x000000, 0.6)] as CFArray, locations: nil) {
            ctx.drawLinearGradient(shade, start: CGPoint(x: right - 176, y: 0), end: CGPoint(x: right - 56, y: 0), options: .drawsAfterEndLocation)
        }
        guard let weather else {
            let message = WeatherService.shared.status as NSString
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            let size = message.size(withAttributes: [.font: font])
            message.draw(at: CGPoint(x: right - size.width, y: (h - size.height) / 2), withAttributes: [.font: font, .foregroundColor: secondary])
            return
        }
        let temperature = "\(Int(weather.temperature.rounded()))°" as NSString
        let bigFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let bigSize = temperature.size(withAttributes: [.font: bigFont])
        temperature.draw(at: CGPoint(x: right - bigSize.width, y: (h - bigSize.height) / 2),
                         withAttributes: [.font: bigFont, .foregroundColor: primary])

        let smallFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let lines = [weather.condition.label, weather.place].compactMap { $0 } as [NSString]
        let lineHeight: CGFloat = 11
        var y = (h + lineHeight * CGFloat(lines.count)) / 2 - lineHeight
        for (i, line) in lines.enumerated() {
            let size = line.size(withAttributes: [.font: smallFont])
            line.draw(at: CGPoint(x: right - bigSize.width - 8 - size.width, y: y),
                      withAttributes: [.font: smallFont, .foregroundColor: i == 0 ? primary : secondary])
            y -= lineHeight
        }
    }
}

// MARK: - Render ke file (untuk menguji tanpa Touch Bar)

enum WallpaperRenderer {
    /// Menjalankan satu tema tanpa tampil, lalu menyimpan beberapa frame (bertumpuk) sebagai PNG.
    @MainActor
    static func render(_ theme: WallpaperTheme, text: String? = nil, start: Double, frames: Int, interval: Double, to path: String) -> Bool {
        let size = CGSize(width: 1004, height: 30), gap: CGFloat = 4
        let scene = theme == .text && text != nil ? TextScene(text: text!) : theme.makeScene()
        // Untuk tema cuaca, `text` berisi "kode,siang(1/0),suhu,angin km/jam,arah angin,kota", misalnya "61,1,27,12,270,Yogyakarta".
        // Tambahan ",geser=awal-akhir" mensimulasikan jari yang menggeser dari x awal ke x akhir selama frame dirender.
        var drag: (from: CGFloat, to: CGFloat)?
        if let weatherScene = scene as? WeatherScene, let parts = text?.components(separatedBy: ","), parts.count >= 5 {
            weatherScene.override = Weather(code: Int(parts[0]) ?? 0, isDay: parts[1] == "1", temperature: Double(parts[2]) ?? 0,
                                            windSpeed: Double(parts[3]) ?? 0, windDirection: Double(parts[4]) ?? 0,
                                            place: parts.count > 5 ? parts[5] : nil)
            if let spec = parts.first(where: { $0.hasPrefix("geser=") })?.dropFirst(6).split(separator: "-"), spec.count == 2,
               let from = Double(spec[0]), let to = Double(spec[1]) {
                drag = (CGFloat(from), CGFloat(to))
            }
        }
        scene.resize(size)
        func advance(_ seconds: Double) {
            var left = seconds
            while left > 0 {
                scene.step(CGFloat(min(left, 1.0 / 30)))
                left -= 1.0 / 30
            }
        }
        let height = CGFloat(frames) * (size.height + gap)
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.scaleBy(x: 2, y: 2)
        ctx.fill(color(0x808080), CGRect(x: 0, y: 0, width: size.width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        advance(start)
        if let drag { scene.touchBegan(at: drag.from) }
        for i in 0..<frames {
            if let drag {
                let t = frames > 1 ? CGFloat(i) / CGFloat(frames - 1) : 1
                scene.touchMoved(to: drag.from + (drag.to - drag.from) * t)
            }
            if i > 0 { advance(interval) }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: height - CGFloat(i + 1) * (size.height + gap) + gap / 2)
            ctx.clip(to: CGRect(origin: .zero, size: size))
            scene.draw(ctx)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

// MARK: - Tampilan dan pengatur

/// View di Touch Bar yang menjalankan satu adegan pada frame rate adegan itu (10–30 fps), hanya selama tampil.
///
/// Penjaga OLED (Touch Bar memakai layar OLED yang bisa burn-in kalau ada piksel terang yang diam lama):
/// seluruh gambar digeser beberapa piksel secara berkala, kecerahan maksimumnya dibatasi, dan setelah lama
/// tampil tanpa disentuh, animasinya diredupkan dan diperlambat ("tenang").
@MainActor
final class WallpaperView: NSView {
    var scene: WallpaperScene? {
        didSet {
            needsDisplay = true
            restartTimer()
        }
    }
    var onTouch: (() -> Void)?
    /// Mode tenang: lebih redup, 15 fps, dan bergerak setengah kecepatan. Kembali normal saat disentuh.
    var isCalm = false {
        didSet {
            if isCalm != oldValue { restartTimer() }
        }
    }
    private var timer: Timer?
    private var lastFrame: TimeInterval?

    /// Kecerahan maksimum normal dan saat tenang (1 = putih penuh).
    private let brightness: CGFloat = 0.8
    private let calmBrightness: CGFloat = 0.4
    private var dim: CGFloat = 0.8
    /// Geseran seluruh gambar (pixel shift): menuju titik acak baru setiap 90 detik, perlahan.
    private var shift = CGPoint.zero
    private var shiftTarget = CGPoint.zero
    private var shiftClock: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("tidak dipakai") }

    override var isOpaque: Bool { true }

    func start() {
        guard timer == nil else { return }
        lastFrame = nil
        let rate = (scene?.frameRate ?? 30) / (isCalm ? 2 : 1)
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Frame rate berubah (adegan lain atau mode tenang): pasang ulang pengatur waktu kalau sedang berjalan.
    private func restartTimer() {
        guard timer != nil else { return }
        stop()
        start()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.1, now - (lastFrame ?? now)))
        lastFrame = now
        scene?.resize(bounds.size)
        scene?.step(isCalm ? dt * 0.5 : dt)

        shiftClock -= dt
        if shiftClock <= 0 {
            shiftClock = 90
            shiftTarget = CGPoint(x: CGFloat(Int.random(in: -3...3)), y: CGFloat(Int.random(in: -1...1)))
        }
        shift.x += (shiftTarget.x - shift.x) * min(1, dt * 0.5)
        shift.y += (shiftTarget.y - shift.y) * min(1, dt * 0.5)
        dim += ((isCalm ? calmBrightness : brightness) - dim) * min(1, dt * 0.2)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(.black)
        ctx.fill(bounds)
        guard let scene else { return }
        scene.resize(bounds.size)
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: shift.x, y: shift.y)
        scene.draw(ctx)
        ctx.restoreGState()
        // Lapisan hitam transparan meredupkan semua warna dengan rata, termasuk putih penuh.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1 - dim))
        ctx.fill(bounds)
    }

    // Sentuhan bisa datang sebagai NSTouch maupun sebagai event mouse, jadi keduanya masuk ke satu gerakan yang sama.
    private var gesture: (startX: CGFloat, startTime: TimeInterval, dragging: Bool)?
    /// Rentang waktu sentuhan terakhir di wallpaper, supaya tidak dikira aktivitas keyboard/mouse.
    private(set) var touchSpan: ClosedRange<TimeInterval> = 0...0

    private func noteTouch() {
        let now = ProcessInfo.processInfo.systemUptime
        touchSpan = gesture == nil ? now...now : min(touchSpan.lowerBound, now)...now
    }

    private func began(_ x: CGFloat) {
        guard gesture == nil else { return }
        noteTouch()
        isCalm = false
        guard scene?.isInteractive == true else { return onTouch?() ?? () }
        gesture = (x, ProcessInfo.processInfo.systemUptime, false)
    }

    private func moved(_ x: CGFloat) {
        guard var g = gesture else { return }
        noteTouch()
        if !g.dragging, abs(x - g.startX) > 6 {
            g.dragging = true
            scene?.touchBegan(at: g.startX)
        }
        gesture = g
        if g.dragging { scene?.touchMoved(to: x) }
    }

    private func ended() {
        guard let g = gesture else { return }
        noteTouch()
        gesture = nil
        if g.dragging {
            scene?.touchEnded()
        } else if ProcessInfo.processInfo.systemUptime - g.startTime < 0.5 {
            onTouch?()
        }
    }

    /// Posisi jari dalam koordinat adegan (dikurangi geseran pixel shift).
    private func touchX(_ event: NSEvent) -> CGFloat? {
        event.touches(matching: .any, in: self).first.map { $0.location(in: self).x - shift.x }
    }

    private func mouseX(_ event: NSEvent) -> CGFloat {
        convert(event.locationInWindow, from: nil).x - shift.x
    }

    override func touchesBegan(with event: NSEvent) { touchX(event).map(began) }
    override func touchesMoved(with event: NSEvent) { touchX(event).map(moved) }
    override func touchesEnded(with event: NSEvent) { ended() }
    override func touchesCancelled(with event: NSEvent) { ended() }
    override func mouseDown(with event: NSEvent) { began(mouseX(event)) }
    override func mouseDragged(with event: NSEvent) { moved(mouseX(event)) }
    override func mouseUp(with event: NSEvent) { ended() }
}

/// Menampilkan wallpaper di Touch Bar saat Mac lama tidak dipakai, dan menutupnya saat Touch Bar disentuh
/// (atau juga saat mengetik/klik, kalau dipilih di menu).
@MainActor
final class IdleWallpaper: NSObject, NSTouchBarDelegate {
    static let trayID = NSTouchBarItem.Identifier("local.touchbarlyrics.wallpaper.tray")
    static let itemID = NSTouchBarItem.Identifier("local.touchbarlyrics.wallpaper")
    static let delays: [TimeInterval] = [30, 60, 120, 300]

    /// Boleh muncul sendiri sekarang? (Misalnya tidak sedang menampilkan lirik.)
    var canShow: () -> Bool = { true }
    /// Dipanggil setelah wallpaper ditutup.
    var onDismiss: (() -> Void)?
    private(set) var isShown = false

    /// nil = mati.
    var theme: WallpaperTheme? {
        get { WallpaperTheme(rawValue: UserDefaults.standard.string(forKey: "wallpaper") ?? WallpaperTheme.fish.rawValue) }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? "off", forKey: "wallpaper")
            view.scene = newValue?.makeScene()
            if newValue == nil { hide() }
        }
    }

    /// Lama Mac tidak disentuh sebelum wallpaper muncul (detik).
    var delay: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "wallpaperDelay")
            return value > 0 ? value : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: "wallpaperDelay") }
    }

    /// true = juga ditutup saat mengetik, klik, atau scroll; false (bawaan) = hanya saat Touch Bar disentuh.
    var closesOnInput: Bool {
        get { UserDefaults.standard.bool(forKey: "wallpaperClosesOnInput") }
        set { UserDefaults.standard.set(newValue, forKey: "wallpaperClosesOnInput") }
    }

    /// Pilihan mode tenang di menu; -1 = tidak pernah.
    static let calmOptions: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, -1]

    /// Setelah selama ini tampil tanpa disentuh, wallpaper masuk mode tenang (lebih redup dan lambat); -1 = tidak pernah.
    /// Bawaannya 1 jam. Untuk uji bisa diisi detik berapa pun: `defaults write local.touchbarlyrics wallpaperCalmAfter -float 10`.
    var calmAfter: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "wallpaperCalmAfter")
            return value != 0 ? value : 60 * 60
        }
        set { UserDefaults.standard.set(newValue, forKey: "wallpaperCalmAfter") }
    }

    private let bar = NSTouchBar()
    private let view = WallpaperView()
    private var shownAt: TimeInterval = 0
    private var dismissedAt: TimeInterval = 0
    /// Ditampilkan lewat menu: tetap tampil walau lirik sedang aktif, sampai disentuh.
    private var previewing = false
    private var screensAsleep = false

    override init() {
        super.init()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.itemID]
        view.onTouch = { [weak self] in self?.hide() }
        view.scene = theme?.makeScene()
        // Tanpa Touch Bar tidak ada tempat untuk wallpaper: tidak perlu tombol, pemantau, maupun pengatur waktu.
        guard TouchBarHardware.isPresent else { return }

        let tray = NSCustomTouchBarItem(identifier: Self.trayID)
        tray.view = NSButton(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Wallpaper")!,
                             target: self, action: #selector(preview))
        SystemTouchBar.addSystemTrayItem(tray)
        SystemTouchBar.setControlStripPresence(Self.trayID, false)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.hide()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == Self.itemID else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1004).isActive = true
        view.heightAnchor.constraint(equalToConstant: 30).isActive = true
        item.view = view
        return item
    }

    /// Detik sejak ketikan, klik, atau scroll terakhir. Gerakan pointer tidak dihitung: trackpad bisa terus
    /// mengirim gerakan kecil sehingga Mac tidak pernah terhitung diam. Sentuhan di Touch Bar juga tidak tercatat di sini.
    static var secondsSinceInput: TimeInterval {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        let idle = Self.secondsSinceInput
        if isShown {
            // Input terakhir yang terjadi selama jari menggeser wallpaper bukan tanda Mac sedang dipakai.
            let inputAt = now - idle
            let fromTouch = (view.touchSpan.lowerBound - 0.3)...(view.touchSpan.upperBound + 0.3) ~= inputAt
            let typedOrClicked = closesOnInput && inputAt > shownAt + 0.5 && !fromTouch
            if typedOrClicked || (!previewing && !canShow()) { return hide() }
            view.isCalm = calmAfter > 0 && now - max(shownAt, view.touchSpan.upperBound) > calmAfter
            return
        }
        // Setelah ditutup dengan sentuhan, tunggu satu jeda penuh lagi (sentuhan Touch Bar tidak mengubah `idle`).
        guard theme != nil, !screensAsleep, canShow(), idle >= delay, now - dismissedAt >= delay else { return }
        show()
    }

    @objc func preview() { show(preview: true) }

    func show(preview: Bool = false) {
        guard theme != nil, TouchBarHardware.isPresent else { return }
        previewing = preview
        shownAt = ProcessInfo.processInfo.systemUptime
        SystemTouchBar.present(bar, trayItem: Self.trayID)
        isShown = true
        view.isCalm = false
        view.start()
    }

    /// Kembali ke Touch Bar bawaan.
    func hide() {
        guard isShown else { return }
        isShown = false
        previewing = false
        dismissedAt = ProcessInfo.processInfo.systemUptime
        view.stop()
        SystemTouchBar.dismiss(bar)
        onDismiss?()
    }
}
