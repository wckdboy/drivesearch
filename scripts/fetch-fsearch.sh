#!/usr/bin/env bash
# Clone the pinned fsearch commit that DriveSearch builds FSearchKit from.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$(tr -d '[:space:]' < "$ROOT/Config/fsearch.pin")"
DEST="$ROOT/ThirdParty/fsearch"

if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch --depth 1 origin "$PIN"
  git -C "$DEST" checkout --detach "$PIN"
else
  rm -rf "$DEST"
  git clone --filter=blob:none https://github.com/wckdboy/fsearch.git "$DEST"
  git -C "$DEST" checkout --detach "$PIN"
fi

echo "fsearch at $(git -C "$DEST" rev-parse HEAD)"
