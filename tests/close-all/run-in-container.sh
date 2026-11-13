#!/usr/bin/env bash
# Run tests/close-all/e2e.sh in a throwaway podman container (no host sockets, runtime dir or bus;
# only a GPU render node and read-only mounts).
#
#   tests/close-all/run-in-container.sh [log-dir]
#
# Image: any image with labwc, pipewire, xdg-desktop-portal, python-gobject, busctl and pw-dump;
# the default is this box's hypxrland-ctr session image. The compositor is the host's installed
# HypXRland (bind-mounted with the host's libhyprutils), so the portal is tested against the
# compositor it runs under. Set HYPRLAND_DIR= to use the image's own Hyprland instead.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
IMAGE="${XDPH_TEST_IMAGE:-localhost/hypxrland-ctr:session-057a}"
HYPRLAND_DIR="${HYPRLAND_DIR-/usr/lib/hypxrland}"
LOGS="$(realpath -m "${1:-$ROOT/build/close-all-logs}")"

[[ -x "$ROOT/build/xdg-desktop-portal-hyprland" ]] || { echo "build XDPH first (build/xdg-desktop-portal-hyprland)"; exit 2; }

# Prefer the AMD render node, else the first one.
GPU=""
for r in /sys/class/drm/renderD*; do
    [[ "$(cat "$r/device/vendor" 2>/dev/null)" == 0x1002 ]] && GPU="/dev/dri/$(basename "$r")" && break
done
[[ -n "$GPU" ]] || GPU="$(ls /dev/dri/renderD* | head -1)"

HOSTLIBS="$(mktemp -d)"
trap 'rm -rf "$HOSTLIBS"' EXIT
cp -L /usr/lib/libhyprutils.so.* "$HOSTLIBS/" 2>/dev/null || true

COMPOSITOR_ARGS=()
if [[ -n "$HYPRLAND_DIR" ]]; then
    COMPOSITOR_ARGS=(-v "$HYPRLAND_DIR":/opt/hyprland:ro -v "$HOSTLIBS":/opt/hostlibs:ro
        -e HYPRLAND_BIN=/opt/hyprland/Hyprland -e HYPRCTL_BIN=/opt/hyprland/hyprctl -e HYPRLAND_LIBRARY_PATH=/opt/hostlibs)
fi

mkdir -p "$LOGS"
echo "image $IMAGE, GPU $GPU, compositor ${HYPRLAND_DIR:-image}, logs -> $LOGS"

podman run --rm --name "xdph-close-all-$$" \
    --entrypoint /bin/bash \
    --userns=keep-id --user "$(id -u):$(id -g)" --group-add keep-groups \
    --security-opt label=disable \
    --network none \
    --device "$GPU" \
    -v "$ROOT":/xdph:ro \
    -v "$LOGS":/logs \
    "${COMPOSITOR_ARGS[@]}" \
    -e GPU="$GPU" -e LOG_DIR=/logs \
    "$IMAGE" /xdph/tests/close-all/e2e.sh
