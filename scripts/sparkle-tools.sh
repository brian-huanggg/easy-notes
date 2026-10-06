#!/bin/bash
# Sparkle command-line tools (generate_appcast, generate_keys): downloaded to build/sparkle/<version>, SHA-256 verified.
#
#   ./scripts/sparkle-tools.sh path           print the bin directory (downloads on first use)
#   ./scripts/sparkle-tools.sh generate-keys  create an EdDSA key pair and print the public key (private key goes to the
#                                             login keychain; if a key exists, only prints the public key)
#   ./scripts/sparkle-tools.sh export-key F   back up the private key to file F (do this before changing Macs or resetting
#                                             the keychain; without it no more updates can reach installed copies)
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
  [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$SHA256" ]] || { echo "SHA-256 mismatch for Sparkle $VERSION" >&2; rm -f "$archive"; exit 1; }
  tar -xf "$archive" -C "$DIR/$VERSION"
fi

case "${1:-path}" in
  path) echo "$BIN" ;;
  generate-keys) "$BIN/generate_keys" ;;
  export-key) "$BIN/generate_keys" -x "${2:?backup file path}" ;;
  *) echo "Usage: $0 path | generate-keys | export-key <file>" >&2; exit 2 ;;
esac
