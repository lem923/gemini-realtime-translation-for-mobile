#!/usr/bin/env python3
"""Minimal RFC 6455 WebSocket mock of the Gemini Live Translate endpoint."""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time

LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_server.log")
CONTROL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_control.json")

T0 = time.monotonic()

def now_ms():
    return int((time.monotonic() - T0) * 1000)

def log(msg):
    line = f"[{now_ms():>8}] {msg}"
    print(line, flush=True)
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")

def read_control():
    try:
        with open(CONTROL_PATH) as f:
            return json.load(f)
    except Exception:
        return {}

def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf

class MockClient(threading.Thread):
    def __init__(self, conn, addr):
        super().__init__(daemon=True)
        self.conn = conn
        self.addr = addr
        self.turns = 0
        self.audio_chunks = 0
        self.audio_bytes = 0
        self.turn_audio = 0
        self.transcript_len = 0

    def handshake(self):
        data = b""
        while b"\r\n\r\n" not in data:
            data += self.conn.recv(4096)
        lines = data.decode("latin1").split("\r\n")
        key = None
        for line in lines:
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        if key is None:
            raise ConnectionError("no ws key")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        self.conn.sendall(resp.encode())
        log(f"client {self.addr} connected")

    def send_frame(self, opcode, payload):
        b1 = 0x80 | opcode
        n = len(payload)
        header = struct.pack("!B", b1)
        if n < 126:
            header += struct.pack("!B", n)
        elif n < 65536:
            header += struct.pack("!BH", 126, n)
        else:
            header += struct.pack("!BQ", 127, n)
        self.conn.sendall(header + payload)

    def send_text(self, obj):
        self.send_frame(0x1, json.dumps(obj).encode())

    def send_pong(self, payload):
        self.send_frame(0xA, payload)

    def send_close(self, code=1001):
        self.send_frame(0x8, struct.pack("!H", code))
        log(f"client {self.addr} sent close {code}")

    def recv_frame(self):
        header = read_exact(self.conn, 2)
        b0, b1 = header[0], header[1]
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(self.conn, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(self.conn, 8))[0]
        mask = read_exact(self.conn, 4) if masked else None
        payload = read_exact(self.conn, length) if length else b""
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    def respond_transcripts(self, final=False):
        self.transcript_len = min(self.turn_audio // 1600, 600)
        source = "nihao shijie"[: min(self.transcript_len, 12)]
        translated = "Hello world this is a test."[: min(self.transcript_len * 2, 40)]
        if final:
            source = "nihao shijie"
            translated = "Hello world this is a test."
        self.send_text(
            {
                "serverContent": {
                    "inputTranscription": {"text": source},
                    "outputTranscription": {"text": translated},
                }
            }
        )

    def respond_audio(self, bytes_out):
        if bytes_out <= 0:
            return
        pcm = bytes((i * 37 + 3) % 256 for i in range(min(bytes_out, 2400)))
        self.send_text(
            {
                "serverContent": {
                    "modelTurn": {
                        "parts": [
                            {
                                "inlineData": {
                                    "mimeType": "audio/pcm;rate=24000",
                                    "data": base64.b64encode(pcm).decode(),
                                }
                            }
                        ]
                    }
                }
            }
        )

    def handle_setup(self, message):
        self.send_text({"setupComplete": {}})
        self.send_text(
            {"sessionResumptionUpdate": {"resumable": True, "newHandle": "mock-handle"}}
        )
        log(f"client {self.addr} setupComplete")

    def handle_audio(self, payload):
        self.audio_chunks += 1
        self.audio_bytes += len(payload)
        self.turn_audio += len(payload)
        if self.audio_chunks % 10 == 1:
            log(f"client {self.addr} chunk#{self.audio_chunks} bytes={len(payload)}")
        control = read_control()
        if control.get("silence"):
            return
        if self.audio_chunks % 2 == 0:
            t0 = time.monotonic()
            self.respond_transcripts(final=False)
            self.respond_audio(1200)
            log(f"client {self.addr} responded to chunk#{self.audio_chunks} in {(time.monotonic()-t0)*1000:.1f}ms")
        if control.get("send_usage"):
            self.send_text(
                {
                    "usageMetadata": {
                        "promptTokenCount": self.audio_chunks,
                        "responseTokenCount": self.audio_chunks * 2,
                        "totalTokenCount": self.audio_chunks * 3,
                    }
                }
            )

    def handle_stream_end(self):
        self.respond_transcripts(final=True)
        self.respond_audio(1200)
        self.turns += 1
        control = read_control()
        self.send_text({"serverContent": {"turnComplete": True, "interrupted": False}})
        log(f"client {self.addr} turn {self.turns} complete")
        if control.get("goaway_after_turns") == self.turns:
            self.send_text({"goAway": {}})
            log(f"client {self.addr} sent goAway")
        if control.get("close_after_turns") == self.turns:
            self.send_close(1001)

    def run(self):
        try:
            self.handshake()
            while True:
                opcode, payload = self.recv_frame()
                if opcode == 0x8:
                    log(f"client {self.addr} closed connection (code={payload[:2].hex()})")
                    break
                if opcode == 0x9:
                    self.send_pong(payload)
                    continue
                if opcode == 0x1:
                    try:
                        message = json.loads(payload.decode())
                    except Exception:
                        continue
                    if "setup" in message:
                        self.handle_setup(message["setup"])
                    elif "realtimeInput" in message:
                        ri = message["realtimeInput"]
                        if "audio" in ri and ri["audio"] is not None:
                            data = ri["audio"].get("data", "")
                            try:
                                raw = base64.b64decode(data)
                            except Exception:
                                raw = b""
                            if raw:
                                self.handle_audio(raw)
                        elif ri.get("audioStreamEnd"):
                            log(f"client {self.addr} audioStreamEnd after {self.turn_audio} bytes")
                            self.handle_stream_end()
                            self.turn_audio = 0
                    continue
        except ConnectionError:
            log(f"client {self.addr} connection lost")
        except OSError as e:
            log(f"client {self.addr} error: {e}")
        finally:
            try:
                self.conn.close()
            except OSError:
                pass

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", port))
    server.listen(8)
    log(f"mock gemini live server listening on :{port}")
    while True:
        conn, addr = server.accept()
        MockClient(conn, addr).start()

if __name__ == "__main__":
    main()
