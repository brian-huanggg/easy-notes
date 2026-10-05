#!/bin/bash
# Sparkle 命令列工具（generate_appcast、generate_keys）：下載到 build/sparkle/<版本>，驗證 SHA-256。
#
#   ./scripts/sparkle-tools.sh path           印出 bin 目錄（第一次會下載）
#   ./scripts/sparkle-tools.sh generate-keys  建立 EdDSA 金鑰並印出公鑰（私鑰存在登入 keychain；已有金鑰就只印公鑰）
#   ./scripts/sparkle-tools.sh export-key F   把私鑰備份到檔案 F（換電腦或 keychain 重置前先備份；遺失就無法再發更新給舊版）
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DIR=build/sparkle
BIN="$DIR/$VERSION/bin"

if [[ ! -x "$BIN/generate_appcast" ]]; then
  mkdir -p "$DIR/$VERSION"
  archive="$DIR/Sparkle-$VERSION.tar.xz"
  curl -fsSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$SHA256" ]] || { echo "Sparkle $VERSION 的 SHA-256 不符" >&2; rm -f "$archive"; exit 1; }
  tar -xf "$archive" -C "$DIR/$VERSION"
fi

case "${1:-path}" in
  path) echo "$BIN" ;;
  generate-keys) "$BIN/generate_keys" ;;
  export-key) "$BIN/generate_keys" -x "${2:?備份檔路徑}" ;;
  *) echo "用法：$0 path | generate-keys | export-key <檔案>" >&2; exit 2 ;;
esac
