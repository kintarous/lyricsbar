#!/bin/bash
# Build Lyricsbar.app (universal: Apple Silicon + Intel).
#
#   ./build.sh            build ke build/Lyricsbar.app
#   ./build.sh install    build lalu pasang ke /Applications
#   ./build.sh release    build lalu buat dist/Lyricsbar-<versi>.dmg dan .zip untuk GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lyricsbar.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# Teks izin (Automation, Lokasi) dalam bahasa Inggris dan Indonesia.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Ikon app: Resources/logo.png → AppIcon.icns
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift make_icon.swift Resources/logo.png build/icon_1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Sebagian besar MacBook Pro ber-Touch Bar memakai Intel, jadi build untuk kedua arsitektur lalu digabung.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -framework Cocoa -framework ServiceManagement -framework CoreLocation \
        Sources/*.swift -o "build/Lyricsbar-$arch"
done
lipo -create build/Lyricsbar-arm64 build/Lyricsbar-x86_64 -output "$APP/Contents/MacOS/Lyricsbar"
rm -f build/Lyricsbar-arm64 build/Lyricsbar-x86_64

# Tanda tangan ad-hoc (tanpa akun Apple Developer). Lihat README bagian "Membuka app pertama kali".
codesign --force --sign - "$APP"
echo "Selesai: $APP (versi $VERSION, $(lipo -archs "$APP/Contents/MacOS/Lyricsbar"))"

case "${1:-}" in
install)
    pkill -x Lyricsbar 2>/dev/null || true
    pkill -x TouchBarLyrics 2>/dev/null || true
    rm -rf /Applications/Lyricsbar.app /Applications/TouchBarLyrics.app
    cp -R "$APP" /Applications/
    # Salinan build punya bundle ID yang sama; kalau dibiarkan, macOS bisa menjalankan salinan ini
    # saat login (dengan izin yang berbeda) alih-alih versi di /Applications.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Terpasang di /Applications/Lyricsbar.app"
    ;;
release)
    mkdir -p dist
    ZIP="dist/Lyricsbar-$VERSION.zip"
    rm -f "$ZIP"
    # ditto menjaga tanda tangan dan atribut bundle; zip biasa bisa merusaknya.
    ditto -c -k --keepParent "$APP" "$ZIP"

    # DMG: jendela berisi Lyricsbar.app dan pintasan ke Applications, tinggal diseret.
    DMG="dist/Lyricsbar-$VERSION.dmg"
    rm -rf build/dmg && mkdir -p build/dmg
    ditto "$APP" build/dmg/Lyricsbar.app
    ln -s /Applications build/dmg/Applications
    rm -f "$DMG"
    diskutil image create from --format UDZO --volumeName Lyricsbar build/dmg "$DMG" >/dev/null
    rm -rf build/dmg

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Rilis: $DMG ($(du -h "$DMG" | cut -f1)) dan $ZIP ($(du -h "$ZIP" | cut -f1))"
    ;;
esac
