#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCKET="$RUNTIME_DIR/wayland-1"
COMPOSITOR_MANIFEST="$ROOT/oxyde/crates/compositor/Cargo.toml"

echo "[1/3] Building compositor…"
cargo build --manifest-path "$COMPOSITOR_MANIFEST" --quiet

echo "[2/3] Starting compositor…"
cargo run --manifest-path "$COMPOSITOR_MANIFEST" --quiet &
COMP_PID=$!

echo "[*] Waiting for $SOCKET…"
for i in {1..100}; do [ -S "$SOCKET" ] && break; sleep .05; done
if [ ! -S "$SOCKET" ]; then
  echo "ERROR: wayland-1 socket not found"; kill $COMP_PID || true; exit 1
fi

echo "[3/3] Building + launching taskbar…"
pushd "$ROOT/taskbar" >/dev/null
cc -std=c11 -O2 -Wall -o bar_y2k \
  bar_y2k.c \
  xdg-shell-protocol.c \
  wlr-layer-shell-unstable-v1-protocol.c \
  wlr-foreign-toplevel-management-unstable-v1-protocol.c \
  $(pkg-config --cflags --libs wayland-client cairo)
WAYLAND_DISPLAY=wayland-1 ./bar_y2k &
popd >/dev/null

trap 'echo; echo "Stopping…"; kill $COMP_PID 2>/dev/null || true; pkill -P $$ || true' INT TERM
wait $COMP_PID || true