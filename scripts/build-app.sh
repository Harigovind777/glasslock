#!/bin/bash
# Builds build/GlassLock.app (release, ad-hoc signed). No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build output must live outside iCloud-synced folders: iCloud adds file
# metadata that codesign rejects. `.build` and `build` are symlinks into Caches.
CACHE="$HOME/Library/Caches/GlassLock"
for link in .build:swiftpm build:app; do
    name="${link%%:*}"; target="$CACHE/${link##*:}"
    mkdir -p "$target"
    if [ ! -L "$name" ]; then
        rm -rf "$name"
        ln -s "$target" "$name"
    fi
done

swift build -c release --product GlassLock
BIN="$(swift build -c release --show-bin-path)/GlassLock"
APP="build/GlassLock.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GlassLock"
cp packaging/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
