# SPDX-FileCopyrightText: 2025 2025 Oxyde Contributors
#
# SPDX-License-Identifier: MPL-2.0
#
#!/usr/bin/env bash
# Oxyde: verbose compositor + taskbar launcher (ts-less)
set -Eeuo pipefail

# ---------- Config ----------
VERBOSE="${VERBOSE:-1}"
LOG_DIR="${LOG_DIR:-/tmp/oxyde-run}"
mkdir -p "$LOG_DIR"
COMP_LOG="$LOG_DIR/compositor.log"
BAR_LOG="$LOG_DIR/taskbar.log"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSITOR_MANIFEST="$ROOT/crates/compositor/Cargo.toml"
TASKBAR_DIR="$ROOT/taskbar"

WAYLAND_DISPLAY_NAME="${WAYLAND_DISPLAY_NAME:-wayland-1}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCKET="$RUNTIME_DIR/$WAYLAND_DISPLAY_NAME"
BUILD_PROFILE="${BUILD_PROFILE:-debug}"     # debug|release
TIMEOUT_SECS="${TIMEOUT_SECS:-30}"
BAR_ARGS="${BAR_ARGS:-}"
WAYLAND_DEBUG="${WAYLAND_DEBUG:-0}"         # 0|1|client

# ---------- Verbose ----------
if [[ "$VERBOSE" != "0" ]]; then
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

# ---------- Helpers ----------
say()  { printf "\n\033[1;34m[OXYDE]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

# Timestamp shim (no dependency on moreutils `ts`)
ts_pipe() {
  awk '{ cmd="date +\"[%Y-%m-%d %H:%M:%S]\""; cmd | getline d; close(cmd); print d, $0; fflush(); }'
}

# Pipe helper: tee + timestamps
tee_ts_append() {
  local file="$1"
  awk '{ cmd="date +\"[%Y-%m-%d %H:%M:%S]\""; cmd | getline d; close(cmd); print d, $0; fflush(); }' \
    | tee -a "$file"
}

# ---------- Env dump ----------
say "Environment snapshot"
echo "ROOT=$ROOT"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
echo "WAYLAND_DISPLAY(target)=$WAYLAND_DISPLAY_NAME"
echo "RUNTIME_DIR=$RUNTIME_DIR"
echo "SOCKET=$SOCKET"
echo "BUILD_PROFILE=$BUILD_PROFILE"
echo "TIMEOUT_SECS=$TIMEOUT_SECS"
echo "LOG_DIR=$LOG_DIR"
echo "PATH=$PATH"
id || true
ulimit -a || true

# ---------- Sanity checks ----------
say "Sanity checks"
[[ -f "$COMPOSITOR_MANIFEST" ]] || die "Missing $COMPOSITOR_MANIFEST"
[[ -d "$TASKBAR_DIR"        ]] || die "Missing $TASKBAR_DIR"
for f in xdg-shell-protocol.c wlr-layer-shell-unstable-v1-protocol.c \
         wlr-foreign-toplevel-management-unstable-v1-protocol.c bar_y2k.c; do
  [[ -f "$TASKBAR_DIR/$f" ]] || warn "Taskbar file missing: $f"
done
command -v pkg-config >/dev/null || die "pkg-config not installed"
pkg-config --exists wayland-client cairo || warn "pkg-config: wayland-client/cairo missing"
echo "pkg-config wayland-client cflags: $(pkg-config --cflags wayland-client || true)"
echo "pkg-config cairo cflags: $(pkg-config --cflags cairo || true)"

# ---------- Build compositor ----------
say "[1/5] Building compositor"
if [[ "$BUILD_PROFILE" == "release" ]]; then
  cargo build --manifest-path "$COMPOSITOR_MANIFEST" --release | tee "$COMP_LOG"
else
  cargo build --manifest-path "$COMPOSITOR_MANIFEST" | tee "$COMP_LOG"
fi

# ---------- Launch compositor ----------
say "[2/5] Launching compositor"
: > "$COMP_LOG"
if [[ "$BUILD_PROFILE" == "release" ]]; then
  cargo run --manifest-path "$COMPOSITOR_MANIFEST" --release \
    > >(tee_ts_append "$COMP_LOG") \
    2> >(tee_ts_append "$COMP_LOG" >&2) &
else
  cargo run --manifest-path "$COMPOSITOR_MANIFEST" \
    > >(tee_ts_append "$COMP_LOG") \
    2> >(tee_ts_append "$COMP_LOG" >&2) &
fi
COMP_PID=$!
echo "Compositor PID: $COMP_PID"

cleanup() {
  set +e
  say "Cleaning up…"
  kill "$COMP_PID" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# ---------- Wait for socket ----------
say "[3/5] Waiting for Wayland socket: $SOCKET (timeout ${TIMEOUT_SECS}s)"
t0=$(date +%s)
while [[ ! -S "$SOCKET" ]]; do
  sleep 0.05
  (( $(date +%s) - t0 >= TIMEOUT_SECS )) && {
    warn "Socket didn't appear."
    ls -l "$RUNTIME_DIR" || true
    say "Last 100 lines of compositor log:"; tail -n 100 "$COMP_LOG" || true
    die "Wayland socket not found at $SOCKET"
  }
done
say "Socket is up."

# ---------- Quick health check ----------
sleep 0.3
if ! kill -0 "$COMP_PID" 2>/dev/null; then
  say "Compositor died early; last 150 lines:"
  tail -n 150 "$COMP_LOG" || true
  die "Compositor exited"
fi

# ---------- Build taskbar ----------
say "[4/5] Building taskbar"
pushd "$TASKBAR_DIR" >/dev/null
echo "+ cc -std=c11 -O2 -Wall -o bar_y2k bar_y2k.c xdg-shell-protocol.c wlr-layer-shell-unstable-v1-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.c \$(pkg-config --cflags --libs wayland-client cairo)"
cc -std=c11 -O2 -Wall -o bar_y2k \
  bar_y2k.c \
  xdg-shell-protocol.c \
  wlr-layer-shell-unstable-v1-protocol.c \
  wlr-foreign-toplevel-management-unstable-v1-protocol.c \
  $(pkg-config --cflags --libs wayland-client cairo) \
  | tee "$BAR_LOG"
[[ -x ./bar_y2k ]] || die "bar_y2k did not build"

# ---------- Launch taskbar ----------
say "[5/5] Launching taskbar"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY_NAME"
[[ "$WAYLAND_DEBUG" != "0" ]] && export WAYLAND_DEBUG="$WAYLAND_DEBUG" && echo "WAYLAND_DEBUG=$WAYLAND_DEBUG"

echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo "Launching: $TASKBAR_DIR/bar_y2k $BAR_ARGS"

: > "$BAR_LOG"
"$TASKBAR_DIR/bar_y2k" $BAR_ARGS \
  > >(tee_ts_append "$BAR_LOG") \
  2> >(tee_ts_append "$BAR_LOG" >&2) &
BAR_PID=$!
echo "Taskbar PID: $BAR_PID"
popd >/dev/null

say "Both processes launched."
echo "  Compositor log: $COMP_LOG"
echo "  Taskbar log   : $BAR_LOG"
echo "Press Ctrl+C to stop."

# ---------- Monitor ----------
# If compositor dies, dump logs and exit non-zero.
wait "$COMP_PID" || {
  rc=$?
  warn "Compositor exited (code $rc). Tail logs:"
  tail -n 200 "$COMP_LOG" || true
  tail -n 200 "$BAR_LOG" || true
  exit "$rc"
}