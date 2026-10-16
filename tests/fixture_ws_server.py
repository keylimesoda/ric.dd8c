#!/usr/bin/env python3
"""Minimal in-memory Ascend mesh WebSocket server for tests.

Speaks just enough of the protocol (framing + the endpoints the dd8c CLI
uses) to exercise the daemon end-to-end without touching real speakers.
"""
import base64
import hashlib
import json
import socket
import struct
import threading

DOC = {
    "type": "room", "name": "Test Room", "version": "2.6.43",
    "selectedInput": "XLR", "selectedXLR": "aes",
    "inputModes": ["analogHighGain", "analogLowGain", "aes",
                   "AES Streamer", "File Player"],
    "inputLevel": -50.0,
    "gain": {"global": -30.0, "limits": {"min": -70, "max": 6, "step": 0.1}},
    "mute": {"global": False}, "sleep": False, "nightmode": False,
    "frontledEnable": True, "linearPhase": True,
    "selectedProfile": "default", "lastSelectedPreset": "p-flat",
    "presets": {"p-flat": {"name": "Flat"}, "p-night": {"name": "Night"}},
    "profiles": {"default": {"name": "Default",
                             "settings": {"room": {"sub": 0, "bass": 0, "treble": 0}}}},
    "confirmed_licenses": {"audio": True, "streaming": False},
    "streaming": False, "streamingInfo": {},
    "positions": {"pos-l": "left", "pos-r": "right"},
}

IDENTITY = "test-master-identity"


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def _read_frame(sock):
    b0, b1 = _recv_exact(sock, 2)
    op, masked, n = b0 & 0x0F, b1 & 0x80, b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", _recv_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", _recv_exact(sock, 8))[0]
    if masked:
        mask = _recv_exact(sock, 4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(_recv_exact(sock, n)))
    else:
        data = _recv_exact(sock, n)
    return op, data


def _send_text(sock, text):
    payload = text.encode()
    n = len(payload)
    head = bytes([0x81])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    sock.sendall(head + payload)


def _handle(doc, msg):
    meta = msg.get("meta", {})
    mid, method, endpoint = meta.get("id"), meta.get("method"), meta.get("endpoint")
    data = msg.get("data")

    def ok(payload):
        return {"meta": {"id": mid, "method": method, "endpoint": endpoint},
                "data": payload}

    def err(detail):
        return {"meta": {"id": mid, "method": method, "endpoint": endpoint},
                "errors": [{"detail": detail}]}

    if method == "read" and endpoint == "Master Plugin:identity":
        return ok({"identity": IDENTITY})
    if method == "read" and endpoint == "master":
        return ok({"target": IDENTITY})
    if method == "read" and endpoint == "targets":
        return ok([{"targetType": "room", "target": "room1"}])
    if method == "read" and endpoint == "room":
        return ok({"data": doc})
    if method == "subscribe" and endpoint == "network":
        return ok({})
    if method == "update" and endpoint == "gain2":
        lim = doc["gain"]["limits"]
        doc["gain"]["global"] = max(lim["min"], min(lim["max"], data["gain"]))
        return ok({})
    if method == "update" and endpoint == "mute":
        doc["mute"]["global"] = data[0]["mute"]
        return ok({})
    if method == "update" and endpoint == "sleep":
        doc["sleep"] = data["enable"]
        return ok({})
    if method == "update" and endpoint == "frontled":
        doc["frontledEnable"] = data["enable"]
        return ok({})
    if method == "update" and endpoint == "selectedInput":
        doc["selectedInput"] = data["input"]
        return ok({})
    if method == "update" and endpoint == "selectedXLR":
        doc["selectedXLR"] = data["xlr"]
        return ok({})
    if method == "select" and endpoint == "preset2":
        doc["lastSelectedPreset"] = data["presetID"]
        return ok({})
    if method == "select" and endpoint == "profile":
        doc["selectedProfile"] = data["profileID"]
        return ok({})
    if method == "update" and endpoint == "tone-control":
        s = doc["profiles"][doc["selectedProfile"]]["settings"]["room"]
        s.update({k: data[k] for k in ("sub", "bass", "treble")})
        return ok({})
    # firmware verbs must be refused exactly like the real device
    if endpoint in ("rms-releases", "rms-factory-reset", "rms"):
        return err("Unknown method/endpoint combination")
    return err("Unknown method/endpoint combination")


class FixtureServer:
    def __init__(self, doc=None):
        self.doc = json.loads(json.dumps(DOC if doc is None else doc))
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def _run(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            try:
                self._client(conn)
            except Exception:
                pass
            finally:
                conn.close()

    def _client(self, conn):
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                return
            req += chunk
        key = None
        for line in req.decode(errors="replace").split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        if not key:
            return
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        while not self.stop.is_set():
            try:
                op, data = _read_frame(conn)
            except (ConnectionError, OSError):
                return
            if op == 0x8:
                return
            if op == 0x9:
                continue
            if op in (0x1, 0x2):
                try:
                    msg = json.loads(data.decode())
                except json.JSONDecodeError:
                    continue
                _send_text(conn, json.dumps(_handle(self.doc, msg)))

    def shutdown(self):
        self.stop.set()
        try:
            self.sock.close()
        except OSError:
            pass


if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8768
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    print(f"listening on {port}", flush=True)
    while True:
        conn, _ = srv.accept()
        t = threading.Thread(target=lambda c=conn: (
            FixtureServer._client(FixtureServer.__new__(FixtureServer), c),
            c.close()), daemon=True)
        t.start()
