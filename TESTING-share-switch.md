# Testing the `share-switch` portal build

Branch `share-switch` is XDPH v1.4.1 (the version the `xdg-desktop-portal-hyprland 1.4.1-2`
package installs), plus:

| commit | what |
|---|---|
| upstream #424 (cherry-pick) | no frozen session after running out of PipeWire buffers |
| upstream #425 (cherry-pick) | renegotiation no longer destroys the frame callback it just installed |
| upstream #447 (backport) | modifier-choice validation in `pwStreamParamChanged` |
| requeue after a failed frame | fixes #445/#451: a failed frame used to stall the stream for good |
| don't restart an in-flight renegotiation | the mismatch path used to re-request renegotiation on every frame |
| renegotiate instead of aborting | the DMA format `RASSERT` used to kill the portal when the format changed mid-negotiation |
| dma-buf retry reset | the 2nd renegotiation (resize/switch) of a stream used to fall back to SHM permanently |
| `pwStreamParamChanged` hardening (backport from #441) | div-by-zero on a format without a framerate; stale `isDMA` after a DMA→SHM fallback |
| `ScreencastControl1` + `Session.Closed` | `CloseAll()` ends every screencast from outside (bar button, keybind) and the app is told; the portal also ends a share itself, with `Closed`, when the shared output goes away or pipewire drops the stream (it used to freeze) |

## Build

`hyprwayland-scanner` isn't installed system-wide on this box. A copy lives in `.tools/` (git-ignored
via `.git/info/exclude`), so put it on `PATH` for configure *and* build:

```sh
cd ~/code/xdg-desktop-portal-hyprland
export PATH=$PWD/.tools/bin:$PATH PKG_CONFIG_PATH=$PWD/.tools/lib/pkgconfig
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache   # once
flock -w 7200 /tmp/hypxrland-build.lock cmake --build build -j8
```

Binary: `~/code/xdg-desktop-portal-hyprland/build/xdg-desktop-portal-hyprland`.

## Swap the patched portal in

Stop any running screenshares first. Stopping the portal ends them.

Facts checked on this machine:
- Unit: `xdg-desktop-portal-hyprland.service` (`Type=dbus`,
  `BusName=org.freedesktop.impl.portal.desktop.hyprland`, `ExecStart=/usr/lib/xdg-desktop-portal-hyprland`).
- v1.4.1 has **no `-r`/`--replace` flag**. The only flags are `-v` (trace logging), `-q`, `-h` and `-V`.
  It requests the bus name and **fails to start if the stock portal still owns it**, so you have to stop
  the stock one first.
- The D-Bus service file has `SystemdService=xdg-desktop-portal-hyprland.service`. If something calls
  the portal between the stop and the start, D-Bus re-activates the *stock* one. That's why the two
  commands are chained below.

From a terminal inside the Hyprland session:

```sh
systemctl --user stop xdg-desktop-portal-hyprland.service && \
  ~/code/xdg-desktop-portal-hyprland/build/xdg-desktop-portal-hyprland -v 2>&1 | tee /tmp/xdph-share-switch.log
```

Check that the patched build owns the name:

```sh
busctl --user status org.freedesktop.impl.portal.desktop.hyprland | grep -E '^(PID|Exe)='
# Exe= should be .../build/xdg-desktop-portal-hyprland
```

If it exits right away with a D-Bus "name exists"/request-name error, the stock one got re-activated.
Run the stop-and-start line again.

**`xdg-desktop-portal` itself:** it reaches the backend through the well-known bus name, so it
normally picks up the new owner without a restart. If an app's share dialog errors out or never shows
the picker, restart it with `systemctl --user restart xdg-desktop-portal.service`. That interrupts
every portal user for a moment (file choosers and so on), so do it only if needed.

Your `~/.config/hypr/xdph.conf` (custom picker `hyprland-preview-share-picker`) is read as usual.

## Revert

1. Press Ctrl-C in the terminal running the patched portal, or kill that one PID. Never kill it by name.
2. `systemctl --user start xdg-desktop-portal-hyprland.service` (or just start a share and let D-Bus
   activate it).
3. `systemctl --user status xdg-desktop-portal-hyprland.service` should show `/usr/lib/xdg-desktop-portal-hyprland` running.

Nothing was installed, so there's nothing else to undo.

## Repro check for #451 / #445 (no plugin needed)

Optional A/B: run the stock binary the same way first (`/usr/lib/xdg-desktop-portal-hyprland -v`
after the same `systemctl --user stop`) to see the freeze. Then repeat with the patched build.

1. Open a getDisplayMedia test page in Chromium, e.g. https://webrtc.github.io/samples/src/content/getusermedia/getdisplaymedia/
   (Vesktop/Discord window share works too). Share **a window** (toplevel export path), e.g. a kitty window.
2. With the preview visible, do each of these and check the preview keeps updating (type in the
   shared terminal):
   - drag-resize the window (floating: SUPER+right-drag) for a few seconds, continuously;
   - toggle fullscreen (`hyprctl dispatch fullscreen 0` with the window focused) on, then off;
   - toggle floating, and move it to another monitor (one with a different scale or bit depth, if you have one);
   - do the resize/fullscreen cycle at least **3 times** (the SHM-fallback bug showed on the 3rd negotiation).
3. Repeat with **a monitor** share (wlr-screencopy path). Change that monitor's mode or scale with
   `hyprctl keyword monitor ...` if you want to force a size change there.

What to expect in `/tmp/xdph-share-switch.log`:

| line | stock 1.4.1 | patched |
|---|---|---|
| `hlOnFailed` / `wlrOnFailed` followed by endless `tried scheduling on already scheduled cb` and no more frames | the freeze | shouldn't happen. A failed frame is followed by a new capture |
| `Incompatible formats, renegotiate stream` | once per size change, possibly repeated every frame until it settles | once per size change. Repeats show as TRACE `renegotiation for WxH already requested` |
| `DMA-BUF fixation failed after 2 attempts, falling back to SHM` | after the 2nd resize | shouldn't appear on a healthy GPU setup |
| `negotiated dma format ... doesn't match the source's ..., renegotiating` | (stock aborts on `invalid format in dma pw param change`) | may appear once when the format changes. Streaming continues |
| `N consecutive frames failed, backing off` | (none) | only when a source keeps failing, e.g. a window that can't be captured. Retries slow to at most 1/s |

```sh
grep -cE 'already scheduled' /tmp/xdph-share-switch.log      # a few at most is fine; thousands = stall
grep -E 'falling back to SHM|backing off|renegotiating|Assert' /tmp/xdph-share-switch.log
```

Known limitation (compositor side, not fixed here): if the shared window is **closed**,
Hyprland 0.56.2 ignores the capture request without sending `failed`. The share then shows the last
frame until the app stops it. Same as stock.

## Ending every share: `ScreencastControl1`

On the portal's own bus name and object path:

```sh
busctl --user call org.freedesktop.impl.portal.desktop.hyprland /org/freedesktop/portal/desktop \
    io.github.andrewgaspar.hypxr.ScreencastControl1 CloseAll    # -> u <sessions ended>
busctl --user call org.freedesktop.impl.portal.desktop.hyprland /org/freedesktop/portal/desktop \
    io.github.andrewgaspar.hypxr.ScreencastControl1 List        # -> a(sss) handle, app id, type
```

`CloseAll` emits `org.freedesktop.impl.portal.Session::Closed` for each ScreenCast session, which
xdg-desktop-portal relays to the app as `org.freedesktop.portal.Session::Closed`, then tears the
session down like a normal `Close`. `List` types are `monitor`, `window`, `region`, `workspace`, or
`none` (no source selected yet). Screenshot and GlobalShortcuts sessions aren't touched.

End-to-end test, in a throwaway podman container (headless labwc, nested Hyprland, private bus,
pipewire, the frontend and a stream reader; nothing from the live session):

```sh
tests/close-all/run-in-container.sh     # needs build/xdg-desktop-portal-hyprland; logs in build/close-all-logs
```
