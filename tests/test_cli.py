#!/usr/bin/env python3
"""End-to-end tests for bin/dd8c against the fixture WS server (no device)."""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "bin", "dd8c")
sys.path.insert(0, HERE)
from fixture_ws_server import FixtureServer  # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok  {name}")
    else:
        print(f" FAIL {name} {detail}")
        FAILS.append(name)


def read_until_state(proc, want_pred, timeout=8.0):
    """Read stdout lines until a state event matches want_pred; return (events, responses)."""
    events, responses = [], []
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        obj = json.loads(line)
        if "event" in obj:
            events.append(obj)
            if obj["event"] == "state" and want_pred(obj["snapshot"]):
                return events, responses
        elif "id" in obj:
            responses.append(obj)
    return events, responses


def test_daemon():
    print("daemon against fixture WS server")
    srv = FixtureServer().start()
    proc = subprocess.Popen(
        [BIN, "--ip", "127.0.0.1", "--port", str(srv.port), "daemon"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    try:
        # hello + initial state
        events, _ = read_until_state(proc, lambda s: s["room"] == "Test Room")
        check("hello received", any(e["event"] == "hello" for e in events))
        check("initial state gain -30",
              events[-1]["snapshot"]["gain"]["global"] == -30.0)
        check("master identity resolved",
              events[-1]["snapshot"]["online"] is True)

        def send(obj):
            proc.stdin.write(json.dumps(obj) + "\n")
            proc.stdin.flush()

        # vol within limits
        send({"id": 1, "cmd": "vol", "args": {"db": -20}})
        events, res = read_until_state(proc, lambda s: s["gain"]["global"] == -20.0)
        check("vol -20 applied", any(r["id"] == 1 and r["ok"] for r in res))

        # vol clamped by room-doc limits
        send({"id": 2, "cmd": "vol", "args": {"db": 99}})
        events, res = read_until_state(proc, lambda s: s["gain"]["global"] == 6.0)
        check("vol clamped to max 6", any(r["id"] == 2 and r["ok"] for r in res))

        # mute
        send({"id": 3, "cmd": "mute", "args": {"on": True}})
        events, res = read_until_state(proc, lambda s: s["mute"] is True)
        check("mute on", any(r["id"] == 3 and r["ok"] for r in res))

        # input mode switch (XLR submode)
        send({"id": 4, "cmd": "input", "args": {"mode": "analogLowGain"}})
        events, res = read_until_state(
            proc, lambda s: s["selectedInput"] == "XLR"
            and s["selectedXLR"] == "analogLowGain")
        check("input analogLowGain", any(r["id"] == 4 and r["ok"] for r in res))

        # input mode switch (special mode)
        send({"id": 5, "cmd": "input", "args": {"mode": "File Player"}})
        events, res = read_until_state(
            proc, lambda s: s["selectedInput"] == "File Player")
        check("input File Player", any(r["id"] == 5 and r["ok"] for r in res))

        # preset + profile select
        send({"id": 6, "cmd": "preset", "args": {"name": "Night"}})
        events, res = read_until_state(proc, lambda s: s["lastSelectedPreset"] == "p-night")
        check("preset Night", any(r["id"] == 6 and r["ok"] for r in res))

        # tone
        send({"id": 7, "cmd": "tone", "args": {"bass": 2.5}})
        events, res = read_until_state(proc, lambda s: s["tone"]["bass"] == 2.5)
        check("tone bass 2.5", any(r["id"] == 7 and r["ok"] for r in res))

        # unknown command -> error response, daemon stays alive
        send({"id": 8, "cmd": "bogus"})
        deadline = time.time() + 5
        got_err = False
        while time.time() < deadline:
            line = proc.stdout.readline()
            obj = json.loads(line)
            if obj.get("id") == 8 and obj.get("ok") is False:
                got_err = True
                break
        check("unknown cmd errors", got_err)
        send({"id": 9, "cmd": "status"})
        events, res = read_until_state(proc, lambda s: s["online"])
        check("daemon alive after error", any(r["id"] == 9 and r["ok"] for r in res))
    finally:
        proc.stdin.close()
        proc.wait(timeout=5)
        srv.shutdown()


def test_fixture_daemon():
    print("daemon --fixture (in-memory)")
    proc = subprocess.Popen([BIN, "daemon", "--fixture"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True, bufsize=1)
    try:
        proc.stdin.write(json.dumps({"id": 1, "cmd": "vol", "args": {"db": -12}}) + "\n")
        proc.stdin.flush()
        events, res = read_until_state(proc, lambda s: s["gain"]["global"] == -12.0)
        check("fixture vol applied", any(r["id"] == 1 and r["ok"] for r in res))
        check("fixture room name", events[-1]["snapshot"]["room"].endswith("(fixture)"))
    finally:
        proc.stdin.close()
        proc.wait(timeout=5)


def test_one_shot():
    print("one-shot CLI against fixture WS server")
    srv = FixtureServer().start()
    out = subprocess.run([BIN, "--ip", "127.0.0.1", "--port", str(srv.port), "status"],
                         capture_output=True, text=True, timeout=10)
    check("status exit 0", out.returncode == 0, out.stderr[:200])
    if out.returncode == 0:
        snap = json.loads(out.stdout)
        check("status room", snap["room"] == "Test Room")
        check("status presets", set(snap["presets"].values()) == {"Flat", "Night"})
    srv.shutdown()


if __name__ == "__main__":
    test_daemon()
    test_fixture_daemon()
    test_one_shot()
    print("FAILS:", FAILS if FAILS else "none")
    sys.exit(1 if FAILS else 0)
