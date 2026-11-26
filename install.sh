#!/bin/bash
set -eu

usage() {
    printf '用法  %s [--replace] [安装目录]\n' "$0"
    printf '默认安装到 ~/.local/bin。再次运行可升级，--replace 可替换其他同名普通文件。\n'
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    usage
    exit 0
fi

replace=false
if [ "${1:-}" = --replace ]; then
    replace=true
    shift
fi
if [ "$#" -gt 1 ] || [[ "${1:-}" == --* ]]; then
    usage >&2
    exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
    printf 'mac-hotkeys 适用于 macOS。\n' >&2
    exit 1
fi

source_dir="$(cd "$(dirname "$0")" && pwd)"
architecture="$(uname -m)"
packaged_binary="$source_dir/mac-hotkeys"

is_mac_hotkeys() {
    file -b "$1" | grep -q 'Mach-O.*executable' &&
        LC_ALL=C grep -aqF 'mac-hotkeys' "$1" &&
        LC_ALL=C grep -aqF 'DefaultSpacesShortcuts.xml' "$1"
}

if [ -f "$source_dir/main.swift" ]; then
    build=true
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        printf '从源码编译需要 Apple 命令行开发工具。请运行 xcode-select --install，或使用预编译安装包。\n' >&2
        exit 1
    fi
else
    build=false
    if [ -L "$packaged_binary" ] || [ ! -f "$packaged_binary" ] || [ ! -x "$packaged_binary" ] ||
        ! is_mac_hotkeys "$packaged_binary"; then
        printf '请完整解压安装包，让 install.sh 与可执行文件 mac-hotkeys 位于同一目录。\n' >&2
        exit 1
    fi
    if ! file -b "$packaged_binary" | grep -Eq "Mach-O 64-bit executable ${architecture}([^[:alnum:]_]|$)"; then
        if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ] ||
            ! file -b "$packaged_binary" | grep -Eq 'Mach-O 64-bit executable arm64([^[:alnum:]_]|$)'; then
            printf '此安装包不支持本机的 %s 架构，请使用匹配的版本或从源码安装。\n' "$architecture" >&2
            exit 1
        fi
    fi
fi

bin_dir="${1:-$HOME/.local/bin}"
mkdir -p "$bin_dir"
bin_dir="$(cd "$bin_dir" && pwd)"
destination="$bin_dir/mac-hotkeys"

check_destination() {
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        printf '安装位置已被符号链接或特殊文件占用，请另选目录  %s\n' "$destination" >&2
        return 1
    fi
    if [ ! -f "$destination" ] || $replace; then
        return 0
    fi
    # Recognize previous local builds without executing an unknown file.
    if is_mac_hotkeys "$destination"; then
        return 0
    fi
    printf '发现其他同名文件，原文件已保留  %s\n' "$destination" >&2
    printf '请另选安装目录，或用 --replace 明确替换。\n' >&2
    return 1
}

check_destination
staging_dir="$(mktemp -d "$bin_dir/.mac-hotkeys.XXXXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

if $build; then
    xcrun swiftc -Osize -target "${architecture}-apple-macosx12.0" -module-cache-path "$staging_dir/cache" \
        "$source_dir"/*.swift -o "$staging_dir/mac-hotkeys"
else
    /usr/bin/install -m 755 "$packaged_binary" "$staging_dir/mac-hotkeys"
fi

check_destination
if [ -f "$destination" ]; then
    if [ ! -x "$destination" ] || ! cmp -s "$destination" "$staging_dir/mac-hotkeys"; then
        mv -f "$staging_dir/mac-hotkeys" "$destination"
    fi
else
    ln "$staging_dir/mac-hotkeys" "$destination"
fi
printf '已安装  %s\n' "$destination"
if [ "$(command -v mac-hotkeys || true)" = "$destination" ]; then
    printf '运行 mac-hotkeys 即可生成快捷键清单。\n'
else
    printf '运行 %q 即可生成快捷键清单。\n' "$destination"
    printf '要在当前终端直接运行 mac-hotkeys，请执行  export PATH=%q:"$PATH"\n' "$bin_dir"
fi
