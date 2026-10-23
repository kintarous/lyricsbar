// Membuat ikon app 1024×1024 dari Resources/logo.png: logo di tengah kotak membulat ala ikon macOS.
// Pakai: swift make_icon.swift Resources/logo.png build/icon_1024.png

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("Pakai: swift make_icon.swift <logo.png> <keluaran.png>\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Kotak membulat 824 pt dengan margin 100 pt, sesuai template ikon macOS.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
           ending: NSColor(srgbRed: 0.91, green: 0.96, blue: 0.93, alpha: 1))!
    .draw(in: path, angle: -90)

// Logo pada ukuran aslinya (512 px) supaya tetap tajam.
let logoRect = NSRect(x: 256, y: 256, width: 512, height: 512)
logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
