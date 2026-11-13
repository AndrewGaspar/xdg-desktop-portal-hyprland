#!/usr/bin/env python3
# ScreenCast portal client for tests/close-all/e2e.sh. Talks to xdg-desktop-portal the way a browser
# does, and to XDPH's io.github.andrewgaspar.hypxr.ScreencastControl1 the way a bar button does
# (busctl). Run it only on a private bus: e2e.sh starts one with dbus-run-session.
#
#   client.py <pick-file> <hyprctl-wrapper>
#
# The picker (see e2e.sh) shares the output named in <pick-file>. <hyprctl-wrapper> runs hyprctl
# against the isolated compositor only.

import ctypes
import json
import os
import re
import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop

# dbus-python delivers signals through the default GLib main context. pygobject isn't needed to spin
# it (and the test image doesn't ship it): call glib directly.
DBusGMainLoop(set_as_default=True)
_glib = ctypes.CDLL("libglib-2.0.so.0")
_glib.g_main_context_iteration.argtypes = [ctypes.c_void_p, ctypes.c_int]
_glib.g_main_context_iteration.restype = ctypes.c_int

PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
IMPL = "org.freedesktop.impl.portal.desktop.hyprland"
CONTROL = "io.github.andrewgaspar.hypxr.ScreencastControl1"

PICK_FILE = sys.argv[1]
HYPRCTL = sys.argv[2]
CONSUMER = sys.argv[3]
LOG_DIR = sys.argv[4]

bus = dbus.SessionBus()
SENDER = bus.get_unique_name()[1:].replace(".", "_")
portal = bus.get_object(PORTAL, PORTAL_PATH, introspect=False)

passes = 0
fails = 0
counter = 0

# session handle -> number of org.freedesktop.portal.Session::Closed received
closed = {}
# session handle -> its pipewire node
nodes = {}
consumers = []


def check(what, ok, detail=""):
    global passes, fails
    if ok:
        passes += 1
        print(f"PASS: {what}{' (' + detail + ')' if detail else ''}", flush=True)
    else:
        fails += 1
        print(f"FAIL: {what}{': ' + detail if detail else ''}", flush=True)


def spin(seconds, until=lambda: False):
    """Run the main context for up to `seconds`, returning early once until() holds."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if until():
            return True
        while _glib.g_main_context_iteration(None, 0):
            pass
        time.sleep(0.01)
    return until()


def token():
    global counter
    counter += 1
    return f"xca{os.getpid()}_{counter}"


def portal_request(method, args, timeout=20):
    """Call a ScreenCast method that answers through a Request object; return (response, results)."""
    tok = token()
    path = f"{PORTAL_PATH}/request/{SENDER}/{tok}"
    got = {}

    def on_response(response, results):
        got["response"], got["results"] = int(response), results

    match = bus.add_signal_receiver(on_response, signal_name="Response", dbus_interface="org.freedesktop.portal.Request", path=path)
    try:
        args[-1]["handle_token"] = dbus.String(tok)
        args[-1] = dbus.Dictionary(args[-1], signature="sv")
        getattr(portal, method)(*args, dbus_interface="org.freedesktop.portal.ScreenCast")
        spin(timeout, lambda: "response" in got)
    finally:
        match.remove()

    if "response" not in got:
        return None, {}
    return got["response"], got["results"]


def watch_closed(session):
    closed[session] = 0

    def on_closed(*_args, path=None):
        closed[path] = closed.get(path, 0) + 1

    bus.add_signal_receiver(on_closed, signal_name="Closed", dbus_interface="org.freedesktop.portal.Session", path=session, path_keyword="path")


def session_close(session):
    bus.get_object(PORTAL, session, introspect=False).Close(dbus_interface="org.freedesktop.portal.Session", timeout=5)


def start_share(output):
    """Create, select (picker -> output) and start a monitor share. Returns the session handle or None."""
    with open(PICK_FILE, "w") as f:
        f.write(output)

    resp, res = portal_request("CreateSession", [{"session_handle_token": dbus.String(token())}])
    if resp != 0:
        print(f"CreateSession response {resp}", flush=True)
        return None
    session = str(res["session_handle"])
    watch_closed(session)

    resp, _ = portal_request("SelectSources", [dbus.ObjectPath(session), {"types": dbus.UInt32(1), "multiple": dbus.Boolean(False)}])
    if resp != 0:
        print(f"SelectSources response {resp}", flush=True)
        return None

    resp, res = portal_request("Start", [dbus.ObjectPath(session), "", {}])
    if resp != 0 or not res.get("streams"):
        print(f"Start response {resp} {res}", flush=True)
        return None

    nodes[session] = int(res["streams"][0][0])
    print(f"started {session} on {output}: pipewire node {nodes[session]}", flush=True)
    return session


def busctl(*args):
    """busctl --user call on XDPH's control interface (exactly what a bar button runs)."""
    out = subprocess.run(["busctl", "--user", "call", IMPL, PORTAL_PATH, CONTROL, *args], capture_output=True, text=True, timeout=10)
    if out.returncode != 0:
        print(f"busctl {' '.join(args)} failed: {out.stderr.strip()}", flush=True)
        return None
    return out.stdout.strip()


def close_all():
    out = busctl("CloseAll")
    m = re.fullmatch(r"u (\d+)", out or "")
    return int(m.group(1)) if m else None


def listed():
    """List() -> the session handles it reports, or None if the call failed."""
    out = subprocess.run(["busctl", "--user", "--json=short", "call", IMPL, PORTAL_PATH, CONTROL, "List"], capture_output=True, text=True, timeout=10)
    if out.returncode != 0:
        print(f"List failed: {out.stderr.strip()}", flush=True)
        return None
    return json.loads(out.stdout)["data"][0]


def pw_objects():
    out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=10)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return []


def live_nodes(*sessions):
    """How many of these sessions' pipewire nodes still exist."""
    ids = {o["id"] for o in pw_objects() if o.get("type") == "PipeWire:Interface:Node"}
    return sum(1 for s in sessions if nodes[s] in ids)


def xdph_log():
    with open(f"{LOG_DIR}/xdph.out", errors="replace") as f:
        return f.read()


def ports(node, direction):
    return [o["id"] for o in pw_objects() if o.get("type") == "PipeWire:Interface:Port" and o["info"]["direction"] == direction and o["info"]["props"].get("node.id") == node]


class Consumer:
    """The app's side of the stream: a pipewire consumer linked to the share's node."""

    def __init__(self, session):
        self.log = f"{LOG_DIR}/consumer-{len(consumers)}.out"
        self.proc = subprocess.Popen([CONSUMER, f"xca-consumer-{len(consumers)}"], stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        consumers.append(self)
        spin(5, lambda: self.node() is not None)
        out, inp = ports(nodes[session], "output"), ports(self.node(), "input")
        if out and inp:
            subprocess.run(["pw-link", str(out[0]), str(inp[0])], capture_output=True, timeout=10)
        else:
            print(f"no ports to link: {out} -> {inp}", flush=True)

    def lines(self):
        with open(self.log) as f:
            return f.read().splitlines()

    def node(self):
        for line in self.lines():
            m = re.match(r"state (\S+) node (\d+)", line)
            if m and m.group(2) != "4294967295":
                return int(m.group(2))
        return None

    def frames(self):
        counts = [int(line.split()[1]) for line in self.lines() if line.startswith("frames ")]
        return counts[-1] if counts else 0

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)


# --- zero sessions ---------------------------------------------------------------------------------
check("List with no sessions is empty", listed() == [], str(listed()))
check("CloseAll with no sessions returns 0", close_all() == 0)

# --- CloseAll ends every share, and the apps hear about it ----------------------------------------
monitors = subprocess.run([HYPRCTL, "monitors", "-j"], capture_output=True, text=True).stdout
first_output = re.search(r'"name": "([^"]+)"', monitors).group(1)

s1 = start_share(first_output)
s2 = start_share(first_output)
check("two shares started", s1 is not None and s2 is not None)

if s1 and s2:
    entries = listed() or []
    check("List shows both sessions as monitor shares", sorted(e[0] for e in entries) == sorted([s1, s2]) and all(e[2] == "monitor" for e in entries), str(entries))
    check("two pipewire streams exist", live_nodes(s1, s2) == 2, str(live_nodes(s1, s2)))

    # s1 streams for real (XDPH keeps capturing frames for it); s2 stays paused with no reader
    c1 = Consumer(s1)
    spin(5, lambda: c1.frames() >= 10)
    check("the linked share streams frames", c1.frames() >= 10, f"{c1.frames()} frames")

    # resize the shared output and CloseAll as soon as XDPH asks pipewire to renegotiate s1's format
    renegotiations = xdph_log().count("Incompatible formats, renegotiate stream")
    subprocess.run([HYPRCTL, "keyword", "monitor", f"{first_output},1024x600@60,0x0,1"], capture_output=True)
    spin(3, lambda: xdph_log().count("Incompatible formats, renegotiate stream") > renegotiations)
    check("s1 is renegotiating after the resize", xdph_log().count("Incompatible formats, renegotiate stream") > renegotiations)
    n1 = close_all()
    n2 = close_all()  # right away: the first call's teardown hasn't run yet
    check("CloseAll returns 2", n1 == 2, str(n1))
    check("CloseAll again right away returns 0", n2 == 0, str(n2))

    spin(5, lambda: closed[s1] and closed[s2])
    check("client got Session::Closed for both sessions", closed[s1] == 1 and closed[s2] == 1, str(closed))
    check("List is empty after CloseAll", listed() == [])
    spin(2, lambda: live_nodes(s1, s2) == 0)
    check("pipewire streams are gone", live_nodes(s1, s2) == 0, str(live_nodes(s1, s2)))
    frames = c1.frames()
    spin(1)
    check("no frames after CloseAll", c1.frames() == frames, f"{frames} -> {c1.frames()}")
    c1.stop()

    # the frontend dropped the sessions, so a Close from the app now fails cleanly and nothing breaks
    try:
        session_close(s1)
        check("Close on a session ended by CloseAll is rejected", False, "call succeeded")
    except dbus.exceptions.DBusException as e:
        check("Close on a session ended by CloseAll is rejected", True, e.get_dbus_name())

# --- the app's own Close still works and stays silent ---------------------------------------------
s3 = start_share(first_output)
check("share after CloseAll started", s3 is not None)
if s3:
    c3 = Consumer(s3)
    spin(5, lambda: c3.frames() >= 10)
    check("it streams frames", c3.frames() >= 10, f"{c3.frames()} frames")
    session_close(s3)
    spin(2, lambda: listed() == [])
    check("app Close ends the session", listed() == [])
    spin(1)
    check("app Close sends no Closed back", closed[s3] == 0, str(closed[s3]))
    check("CloseAll after app Close returns 0", close_all() == 0)
    spin(2, lambda: live_nodes(s3) == 0)
    check("pipewire stream gone after app Close", live_nodes(s3) == 0)
    c3.stop()

# --- the shared output goes away -----------------------------------------------------------------
for name, streaming in (("XCA-GONE-A", True), ("XCA-GONE-B", False)):
    subprocess.run([HYPRCTL, "output", "create", "headless", name], capture_output=True)
    spin(1)
    s = start_share(name)
    check(f"share on removable output {name} started", s is not None)
    if not s:
        continue
    if streaming:
        c = Consumer(s)
        # an idle output only produces a frame when damaged, so XDPH is now waiting on the next one
        spin(5, lambda: c.frames() >= 1)
        check("it streams", c.frames() >= 1, f"{c.frames()} frames")
        spin(0.5)
    subprocess.run([HYPRCTL, "output", "remove", name], capture_output=True)
    spin(5, lambda: closed[s] > 0)
    check(f"removing {name} ({'streaming' if streaming else 'paused'}) ends its session with Closed", closed[s] == 1, str(closed[s]))
    check("List is empty after the output went away", listed() == [])
    check("CloseAll after that returns 0", close_all() == 0)
    spin(2, lambda: live_nodes(s) == 0)
    check("its pipewire stream is gone", live_nodes(s) == 0)
    if streaming:
        c.stop()

for c in consumers:
    if c.proc.poll() is None:
        c.proc.kill()

print(f"\n{passes} passed, {fails} failed", flush=True)
sys.exit(0 if fails == 0 else 1)
