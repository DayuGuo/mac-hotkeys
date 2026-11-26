#!/bin/bash
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/dist"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mac-hotkeys-package.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

for arch in arm64 x86_64; do
    package="mac-hotkeys-$arch"
    minimum=12.0
    if [ "$arch" = x86_64 ]; then minimum=13.0; fi
    mkdir "$work/$package"
    xcrun swiftc -Osize -target "$arch-apple-macosx$minimum" -module-cache-path "$work/cache" \
        "$root"/*.swift -o "$work/$package/mac-hotkeys"
    cp "$root/install.sh" "$work/$package/install.sh"
    (cd "$work" && /usr/bin/zip -q "$package.zip" "$package/install.sh" "$package/mac-hotkeys")
done

mv "$work"/*.zip "$out/"
printf '安装包已生成  %s\n' "$out"
