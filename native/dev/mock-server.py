#!/usr/bin/env python3
"""本地 mock 服务：模拟 DeepSeek 的 Messages / ASR / TTS 接口，方便在模拟器里联调。

用法：
    python3 native/dev/mock-server.py [端口，默认 8099]

然后在 App 设置里把「接口地址」改成 http://127.0.0.1:8099，API Key 随便填。
"""
from __future__ import annotations

import json
import math
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

THINKING = "这是 mock 服务的思考内容。用户想了解原声客户端是否能正常流式渲染。"
REPLY = (
    "你好，我是 DeepSeek 的原生客户端。这条回答来自本地 mock 服务，"
    "用来验证流式渲染、思考块折叠和语音朗读。"
    "如果你能在屏幕上看到文字一段段出现，说明 SSE 解析是正常的。"
)
TITLE = "Mock 流式回答"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("mock %s - %s\n" % (self.address_string(), fmt % args))

    # ---------------------------------------------------------------- helpers
    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse_headers(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _sse(self, payload: dict) -> None:
        self.wfile.write(b"data: " + json.dumps(payload, ensure_ascii=False).encode() + b"\n\n")
        self.wfile.flush()

    # ---------------------------------------------------------------- routes
    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "deepseek-flash"}]})
            return
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:  # noqa: N802
        if self.path.startswith("/anthropic/v1/messages"):
            self.handle_messages()
        elif self.path.startswith("/anthropic/v1/files"):
            self._json(200, {"id": "file_mock_1", "type": "file", "filename": "image.jpg",
                             "mime_type": "image/jpeg", "size_bytes": 1024,
                             "created_at": "2026-01-01T00:00:00Z"})
        elif self.path.startswith("/v1/tools/asr"):
            # 假装识别到一句话，让语音链路能跑通
            self._json(200, {"request_id": "mock", "text": "你好，介绍一下你自己", "duration_ms": 2400})
        elif self.path.startswith("/v1/tools/tts"):
            self.handle_tts()
        else:
            self._json(404, {"error": {"message": "not found"}})

    def handle_messages(self) -> None:
        self._sse_headers()
        try:
            self._sse({"type": "message_start", "message": {"id": "msg_mock", "role": "assistant"}})

            # 思考块
            self._sse({"type": "content_block_start", "index": 0,
                       "content_block": {"type": "thinking", "thinking": ""}})
            for i in range(0, len(THINKING), 6):
                self._sse({"type": "content_block_delta", "index": 0,
                           "delta": {"type": "thinking_delta", "thinking": THINKING[i:i + 6]}})
                time.sleep(0.04)
            self._sse({"type": "content_block_stop", "index": 0})

            # 正文
            self._sse({"type": "content_block_start", "index": 1,
                       "content_block": {"type": "text", "text": ""}})
            for i in range(0, len(REPLY), 4):
                self._sse({"type": "content_block_delta", "index": 1,
                           "delta": {"type": "text_delta", "text": REPLY[i:i + 4]}})
                time.sleep(0.05)
            self._sse({"type": "content_block_stop", "index": 1})

            self._sse({"type": "message_delta",
                       "delta": {"stop_reason": "end_turn", "title": TITLE},
                       "usage": {"input_tokens": 10, "output_tokens": 60,
                                 "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}})
            self._sse({"type": "message_stop"})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_tts(self) -> None:
        body = b""
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            body = self.rfile.read(length)
        try:
            text = json.loads(body or b"{}").get("text", "")
        except json.JSONDecodeError:
            text = ""

        # 按字数生成一段 440 Hz 正弦波，24 kHz / 16-bit / 单声道
        rate = 24000
        seconds = min(3.0, max(0.6, len(text) * 0.08))
        frames = int(rate * seconds)
        pcm = bytearray()
        for i in range(frames):
            sample = int(9000 * math.sin(2 * math.pi * 440 * i / rate))
            pcm += struct.pack("<h", sample)

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        # 分块发送，模拟流式合成
        chunk = 4800
        for offset in range(0, len(pcm), chunk):
            try:
                self.wfile.write(pcm[offset:offset + chunk])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break
            time.sleep(0.03)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock server listening on http://127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
