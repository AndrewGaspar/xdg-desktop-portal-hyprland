#!/usr/bin/env bash
# End-to-end test of ScreencastControl1.CloseAll and the portal-side Session.Closed paths.
#
#   tests/close-all/e2e.sh            (run by tests/close-all/run-in-container.sh, inside a container)
#
# Stack, all private to this run:
#   headless labwc (nest) -> nested Hyprland -> pipewire + XDPH under test + xdg-desktop-portal on a
#   dbus-run-session bus -> client.py (a ScreenCast app) + busctl (a bar button).
#
# Never run this in a live session: it is meant for a throwaway container. Even so, it uses a clean
# environment (env -i), its own XDG_RUNTIME_DIR / HOME / config dirs, and kills only the PIDs it started.
#
# Env:
#   XDPH_BIN      portal under test (default: the build next to this script)
#   HYPRLAND_BIN  compositor (default: Hyprland on PATH)
#   HYPRCTL_BIN   its hyprctl
#   HYPRLAND_LIBRARY_PATH  extra library dir for the compositor only
#   GPU           render node for labwc
#   LOG_DIR       where to leave logs (default: a temp dir)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
XDPH_BIN="${XDPH_BIN:-$ROOT/build/xdg-desktop-portal-hyprland}"
HYPRLAND_BIN="${HYPRLAND_BIN:-$(command -v Hyprland)}"
HYPRCTL_BIN="${HYPRCTL_BIN:-$(command -v hyprctl)}"
HYPRLAND_LIBRARY_PATH="${HYPRLAND_LIBRARY_PATH:-}"
GPU="${GPU:-/dev/dri/renderD128}"

# Short on purpose: $XDG_RUNTIME_DIR/hypr/<signature>/.socket2.sock must fit in sun_path.
T="$(mktemp -d /tmp/xca.XXXXXX)"
LOG_DIR="${LOG_DIR:-$T/logs}"
mkdir -p "$T/run" "$T/nest" "$T/home/.config/hypr" "$T/home/.config/xdg-desktop-portal" "$LOG_DIR"
chmod 0700 "$T/run" "$T/nest"

PIDS=()
cleanup() {
    local pid
    for ((i = ${#PIDS[@]} - 1; i >= 0; i--)); do
        pid="${PIDS[$i]}"
        [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1)) || continue
        kill "$pid" 2>/dev/null
        for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$pid" 2>/dev/null
    done
    cp "$T"/run/hypr/*/hyprland.log "$LOG_DIR/" 2>/dev/null
    echo "logs in $LOG_DIR"
}
trap cleanup EXIT

BASE_ENV=(
    env -i
    PATH=/usr/bin:/bin
    HOME="$T/home"
    XDG_CONFIG_HOME="$T/home/.config"
    XDG_CACHE_HOME="$T/home/.cache"
    XDG_DATA_HOME="$T/home/.local/share"
    XDG_STATE_HOME="$T/home/.local/state"
    LANG=C.UTF-8
)

# --- nest: headless labwc ------------------------------------------------------------------------
"${BASE_ENV[@]}" XDG_RUNTIME_DIR="$T/nest" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1 \
    WLR_RENDER_DRM_DEVICE="$GPU" labwc >"$LOG_DIR/labwc.out" 2>&1 &
PIDS+=($!)
for _ in $(seq 100); do [[ -S "$T/nest/wayland-0" ]] && break; sleep 0.1; done
[[ -S "$T/nest/wayland-0" ]] || { echo "labwc did not come up"; tail -20 "$LOG_DIR/labwc.out"; exit 1; }

# --- nested Hyprland -----------------------------------------------------------------------------
cat >"$T/hyprland.conf" <<'EOF'
monitor = , 1280x720@60, auto, 1
animations {
    enabled = false
}
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
EOF

"${BASE_ENV[@]}" XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY="$T/nest/wayland-0" HYPRLAND_HEADLESS_ONLY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_NOTIFY=1 \
    ${HYPRLAND_LIBRARY_PATH:+LD_LIBRARY_PATH="$HYPRLAND_LIBRARY_PATH"} "$HYPRLAND_BIN" --config "$T/hyprland.conf" >"$LOG_DIR/hyprland.out" 2>&1 &
COMPOSITOR_PID=$!
PIDS+=($COMPOSITOR_PID)

HIS=""
WL=""
for _ in $(seq 150); do
    for lock in "$T"/run/hypr/*/hyprland.lock; do
        [[ -f "$lock" && "$(sed -n 1p "$lock")" == "$COMPOSITOR_PID" ]] || continue
        HIS="$(basename "$(dirname "$lock")")"
        WL="$(sed -n 2p "$lock")"
    done
    [[ -n "$HIS" && -n "$WL" ]] && break
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || break
    sleep 0.1
done
[[ -n "$HIS" && -n "$WL" ]] || { echo "Hyprland did not come up"; tail -30 "$LOG_DIR/hyprland.out"; exit 1; }

SESSION_ENV=("${BASE_ENV[@]}" XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY="$WL" HYPRLAND_INSTANCE_SIGNATURE="$HIS" XDG_CURRENT_DESKTOP=Hyprland)

cat >"$T/hyprctl" <<EOF
#!/bin/sh
exec ${HYPRLAND_LIBRARY_PATH:+env LD_LIBRARY_PATH="$HYPRLAND_LIBRARY_PATH"} "$HYPRCTL_BIN" "\$@"
EOF
chmod +x "$T/hyprctl"
ctl() { "${SESSION_ENV[@]}" "$T/hyprctl" "$@"; }
monitor_names() { ctl monitors -j 2>/dev/null | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }

# The nested (wayland backend) output may never get configured by a headless nest: add a headless one.
sleep 1
[[ -n "$(monitor_names)" ]] || ctl output create headless XCA-1 >/dev/null
for _ in $(seq 50); do [[ -n "$(monitor_names)" ]] && break; sleep 0.1; done
[[ -n "$(monitor_names)" ]] || { echo "Hyprland has no monitor"; exit 1; }
echo "Hyprland pid=$COMPOSITOR_PID instance=$HIS monitors: $(monitor_names)"

# --- portal config: a picker that shares whatever output the client wrote to $T/pick --------------
cat >"$T/picker" <<EOF
#!/bin/sh
echo "[SELECTION]/screen:\$(cat "$T/pick")"
EOF
chmod +x "$T/picker"
cat >"$T/home/.config/hypr/xdph.conf" <<EOF
screencopy {
    custom_picker_binary = $T/picker
}
EOF
printf '[preferred]\ndefault=hyprland\n' >"$T/home/.config/xdg-desktop-portal/portals.conf"

# --- the app's stream reader ----------------------------------------------------------------------
gcc -O1 -o "$T/pw-consumer" "$HERE/pw-consumer.c" $(pkg-config --cflags --libs libpipewire-0.3) || { echo "couldn't build pw-consumer"; exit 1; }

# --- the private bus: pipewire, XDPH, the frontend, the client -----------------------------------
cat >"$T/bus.sh" <<EOF
#!/usr/bin/env bash
# runs inside dbus-run-session; only ever sees the private bus
set -u
pipewire >"$LOG_DIR/pipewire.out" 2>&1 &
PW=\$!
for _ in \$(seq 50); do [[ -S "$T/run/pipewire-0" ]] && break; sleep 0.1; done

"$XDPH_BIN" -v >"$LOG_DIR/xdph.out" 2>&1 &
XDPH=\$!
for _ in \$(seq 100); do busctl --user status org.freedesktop.impl.portal.desktop.hyprland >/dev/null 2>&1 && break; sleep 0.1; done
echo "XDPH pid \$XDPH owns \$(busctl --user status org.freedesktop.impl.portal.desktop.hyprland 2>/dev/null | sed -n 's/^Exe=//p')"

/usr/lib/xdg-desktop-portal -v >"$LOG_DIR/xdg-desktop-portal.out" 2>&1 &
XDP=\$!
for _ in \$(seq 100); do busctl --user status org.freedesktop.portal.Desktop >/dev/null 2>&1 && break; sleep 0.1; done

busctl --user introspect org.freedesktop.impl.portal.desktop.hyprland /org/freedesktop/portal/desktop io.github.andrewgaspar.hypxr.ScreencastControl1

python3 -u "$HERE/client.py" "$T/pick" "$T/hyprctl" "$T/pw-consumer" "$LOG_DIR"
RC=\$?

if kill -0 \$XDPH 2>/dev/null; then echo "PASS: XDPH still running"; else echo "FAIL: XDPH died"; RC=1; fi
grep -E 'CloseAll|Closing session|ended session|Assert|CRIT' "$LOG_DIR/xdph.out" | sed 's/^/xdph log: /'

kill \$XDP \$XDPH \$PW 2>/dev/null
wait \$XDP \$XDPH \$PW 2>/dev/null
exit \$RC
EOF
chmod +x "$T/bus.sh"

"${SESSION_ENV[@]}" dbus-run-session -- "$T/bus.sh"
RC=$?
echo "result: $([[ $RC == 0 ]] && echo PASS || echo FAIL)"
exit $RC
