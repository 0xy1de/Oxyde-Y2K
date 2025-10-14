#!/usr/bin/env bash
# Oxyde: verbose compositor + taskbar launcher
set -Eeuo pipefail

# ---- Verbosity & logging ----------------------------------------------------
VERBOSE="${VERBOSE:-1}"          # set 0 to disable bash trace
WAYLAND_DEBUG="${WAYLAND_DEBUG:-0}" # set 1 or "client" for Wayland client debug
LOG_DIR="${LOG_DIR:-/tmp/oxyde-run}"
mkdir -p "$LOG_DIR"
COMP_LOG="$LOG_DIR/compositor.log"
BAR_LOG="$LOG_DIR/taskbar.log"

if [[ "$VERBOSE" != "0" ]]; then
  # xtrace, include time and line no
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

# ---- Paths ------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSITOR_MANIFEST="$ROOT/crates/compositor/Cargo.toml"
TASKBAR_DIR="$ROOT/taskbar"

# ---- Config -----------------------------------------------------------------
WAYLAND_DISPLAY_NAME="${WAYLAND_DISPLAY_NAME:-wayland-1}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCKET="$RUNTIME_DIR/$WAYLAND_DISPLAY_NAME"
BUILD_PROFILE="${BUILD_PROFILE:-debug}"       # debug|release
TIMEOUT_SECS="${TIMEOUT_SECS:-20}"            # how long to wait for socket
BAR_ARGS="${BAR_ARGS:-}"                       # extra args to bar_y2k if you add any

# ---- Pretty helpers ---------------------------------------------------------
say() { printf "\n\e[1;34m[OXYDE]\e[0m %s\n" "$*"; }
warn(){ printf "\n\e[1;33m[WARN]\e[0m %s\n" "$*"; }
die() { printf "\n\e[1;31m[ERROR]\e[0m %s\n" "$*"; exit 1; }

# ---- Environment dump -------------------------------------------------------
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

# ---- Sanity checks ----------------------------------------------------------
say "Sanity checks"
[[ -f "$COMPOSITOR_MANIFEST" ]] || die "Missing compositor manifest at $COMPOSITOR_MANIFEST"
[[ -d "$TASKBAR_DIR" ]] || die "Missing taskbar dir at $TASKBAR_DIR"

# Required protocol sources for the C taskbar
for f in xdg-shell-protocol.c wlr-layer-shell-unstable-v1-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.c bar_y2k.c; do
  [[ -f "$TASKBAR_DIR/$f" ]] || warn "Taskbar file missing: $f (build may fail)"
done

# pkg-config present?
command -v pkg-config >/dev/null || die "pkg-config is not installed"
pkg-config --exists wayland-client cairo || warn "pkg-config can't find wayland-client and/or cairo (build may fail)"
echo "pkg-config wayland-client cflags: $(pkg-config --cflags wayland-client || true)"
echo "pkg-config cairo cflags: $(pkg-config --cflags cairo || true)"

# ---- Build compositor --------------------------------------------------------
say "[1/4] Building compositor"
if [[ "$BUILD_PROFILE" == "release" ]]; then
  cargo build --manifest-path "$COMPOSITOR_MANIFEST" --release | tee "$COMP_LOG"
else
  cargo build --manifest-path "$COMPOSITOR_MANIFEST" | tee "$COMP_LOG"
fi

# ---- Launch compositor -------------------------------------------------------
say "[2/4] Launching compositor"
: > "$COMP_LOG"
if [[ "$BUILD_PROFILE" == "release" ]]; then
  cargo run --manifest-path "$COMPOSITOR_MANIFEST" --release \
    > >(ts '[%Y-%m-%d %H:%M:%S] COMP ' | tee -a "$COMP_LOG") \
    2> >(ts '[%Y-%m-%d %H:%M:%S] COMP ' | tee -a "$COMP_LOG" >&2) &
else
  cargo run --manifest-path "$COMPOSITOR_MANIFEST" \
    > >(ts '[%Y-%m-%d %H:%M:%S] COMP ' | tee -a "$COMP_LOG") \
    2> >(ts '[%Y-%m-%d %H:%M:%S] COMP ' | tee -a "$COMP_LOG" >&2) &
fi
COMP_PID=$!
echo "Compositor PID: $COMP_PID"

# Trap for clean shutdown
cleanup() {
  set +e
  say "Cleaning up…"
  if kill -0 "$COMP_PID" 2>/dev/null; then
    kill "$COMP_PID" 2>/dev/null || true
    sleep 0.2
  fi
  pkill -P $$ 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# ---- Wait for Wayland socket -------------------------------------------------
say "[3/4] Waiting for Wayland socket: $SOCKET (timeout ${TIMEOUT_SECS}s)"
t0=$(date +%s)
while [[ ! -S "$SOCKET" ]]; do
  sleep 0.05
  now=$(date +%s)
  if (( now - t0 >= TIMEOUT_SECS )); then
    warn "Socket didn't appear. Diagnostic:"
    echo "ls -l $RUNTIME_DIR:"
    ls -l "$RUNTIME_DIR" || true
    echo "lsof on XDG_RUNTIME_DIR (if available):"
    command -v lsof >/dev/null && lsof +D "$RUNTIME_DIR" 2>/dev/null | head -n 50 || true
    echo "ps tree:"
    ps -o pid,ppid,pgid,stat,cmd --forest -p "$COMP_PID" || true
    say "Last 100 lines of compositor log:"
    tail -n 100 "$COMP_LOG" || true
    die "Wayland socket not found at $SOCKET"
  fi
done
say "Socket is up."

# ---- Build + launch taskbar --------------------------------------------------
say "[4/4] Building + launching taskbar"
pushd "$TASKBAR_DIR" >/dev/null

# Show full compile line
echo "+ cc -std=c11 -O2 -Wall -o bar_y2k bar_y2k.c xdg-shell-protocol.c wlr-layer-shell-unstable-v1-protocol.c wlr-foreign-toplevel-management-unstable-v1-protocol.c \$(pkg-config --cflags --libs wayland-client cairo)"
cc -std=c11 -O2 -Wall -o bar_y2k \
  bar_y2k.c \
  xdg-shell-protocol.c \
  wlr-layer-shell-unstable-v1-protocol.c \
  wlr-foreign-toplevel-management-unstable-v1-protocol.c \
  $(pkg-config --cflags --libs wayland-client cairo) \
  | tee "$BAR_LOG"

[[ -x ./bar_y2k ]] || die "bar_y2k did not build"

# Export WAYLAND vars & optionally enable client debugging
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY_NAME"
if [[ "$WAYLAND_DEBUG" != "0" ]]; then
  # WAYLAND_DEBUG=1 or WAYLAND_DEBUG=client are both fine
  export WAYLAND_DEBUG="$WAYLAND_DEBUG"
  say "WAYLAND_DEBUG=$WAYLAND_DEBUG enabled for taskbar"
fi

# Print current env that matters
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo "Launching: $TASKBAR_DIR/bar_y2k $BAR_ARGS"

# Run taskbar with timestamps and capture stdout/stderr
: > "$BAR_LOG"
"$TASKBAR_DIR/bar_y2k" $BAR_ARGS \
  > >(ts '[%Y-%m-%d %H:%M:%S] BAR  ' | tee -a "$BAR_LOG") \
  2> >(ts '[%Y-%m-%d %H:%M:%S] BAR  ' | tee -a "$BAR_LOG" >&2) &
BAR_PID=$!
echo "Taskbar PID: $BAR_PID"

popd >/dev/null

say "Both processes running."
echo "  Compositor log: $COMP_LOG"
echo "  Taskbar log   : $BAR_LOG"
echo "Press Ctrl+C to stop."

# ---- Monitor processes -------------------------------------------------------
wait "$COMP_PID"