#!/bin/bash
set -eu

if [ "$(uname -s)" != Darwin ]; then
    printf 'mac-hotkeys 适用于 macOS。\n' >&2
    exit 1
fi

arch=$(uname -m)
if [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    arch=arm64
fi
case "$arch" in
    arm64) minimum=12 ;;
    x86_64) minimum=13 ;;
    *) printf '不支持此 Mac 的处理器架构  %s\n' "$arch" >&2; exit 1 ;;
esac
version=$(sw_vers -productVersion)
if [ "${version%%.*}" -lt "$minimum" ]; then
    printf '此 %s 安装包需要 macOS %s 或更高版本，当前为 %s。\n' "$arch" "$minimum" "$version" >&2
    exit 1
fi

package="mac-hotkeys-$arch"
url="https://github.com/DayuGuo/mac-hotkeys/releases/latest/download/$package.zip"
work=$(mktemp -d "${TMPDIR:-/tmp}/mac-hotkeys-download.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 "$url" -o "$work/release.zip"
/usr/bin/unzip -q "$work/release.zip" "$package/install.sh" "$package/mac-hotkeys" -d "$work"
/bin/bash "$work/$package/install.sh" "$@"
