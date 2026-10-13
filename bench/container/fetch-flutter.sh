#!/bin/bash
# fetch-flutter.sh — host-side Flutter SDK prep for the container tier.
#
# There's no published linux-arm64 Flutter tarball (stable index ships x64
# only), so we clone stable and pre-seed the linux-arm64 Dart SDK + engine
# stamps on the HOST: update_dart_sdk.sh then skips its ~300MB download,
# which runs at ~10 KB/s inside the container VM over IPv4 (IPv6 hits
# ~22 MB/s but the script's curl doesn't get steered to it reliably).
# `flutter precache --linux` still pulls the remaining arm64 engine
# artifacts inside the container on first run (dart:io picks IPv6 fine).
#
# The clone lives under bench/container/sdk/flutter-linux (gitignored) and
# is baked into klaxon-bench-flutter (Dockerfile.flutter) — Apple
# `container` cannot mount host volumes (VM boot hangs on any -v).
#
# Usage: bench/container/fetch-flutter.sh [dest-dir]

set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")" && pwd)/sdk/flutter-linux}"

if [ ! -x "$DEST/bin/flutter" ]; then
  mkdir -p "$DEST"
  git clone --depth 1 -b stable https://github.com/flutter/flutter "$DEST"
  echo "fetch-flutter: cloned stable → $DEST" >&2
fi

ENGINE_VERSION="$(cat "$DEST/bin/internal/engine.version" | tr -d '[:space:]')"
CACHE="$DEST/bin/cache"

if [ ! -x "$CACHE/dart-sdk/bin/dart" ]; then
  ZIP="/tmp/dart-sdk-linux-arm64-$ENGINE_VERSION.zip"
  URL="https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_VERSION/dart-sdk-linux-arm64.zip"
  echo "fetch-flutter: downloading dart-sdk linux-arm64 ($ENGINE_VERSION) on host" >&2
  curl -fsSL --retry 3 "$URL" -o "$ZIP"
  rm -rf "$CACHE/dart-sdk"
  unzip -q -o "$ZIP" -d "$CACHE"
fi

# Stamps that make update_dart_sdk.sh + update_engine_version.sh no-ops.
echo "$ENGINE_VERSION" > "$CACHE/engine.stamp"
printf '' > "$CACHE/engine.realm"
echo "$ENGINE_VERSION" > "$CACHE/engine-dart-sdk.stamp"

echo "fetch-flutter: SDK ready → $DEST" >&2
