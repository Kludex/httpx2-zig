from __future__ import annotations

import threading

import httpx2

from . import _httpx2_zig


class ZigTransport(httpx2.BaseTransport):
    def __init__(self) -> None:
        self._handle: _httpx2_zig.Client | None = _httpx2_zig.create_client()
        self._lock = threading.Lock()

    def handle_request(self, request: httpx2.Request) -> httpx2.Response:
        if request.url.scheme not in ("http", "https"):
            raise httpx2.UnsupportedProtocol(f"Unsupported scheme: {request.url.scheme}", request=request)

        with self._lock:
            if self._handle is None:
                raise RuntimeError("Zig transport is closed")
            status, raw_headers, content, error_name = _httpx2_zig.send_request(
                self._handle,
                request.method.encode("ascii"),
                str(request.url).encode("ascii"),
                request.headers.raw,
                request.read(),
            )
        if error_name is not None:
            raise httpx2.TransportError(error_name, request=request)
        response_headers: list[tuple[bytes, bytes]] = []
        for line in raw_headers.split(b"\r\n"):
            if line:
                name, _, value = line.partition(b": ")
                response_headers.append((name, value))
        return httpx2.Response(status, headers=response_headers, content=content)

    def close(self) -> None:
        with self._lock:
            if self._handle is not None:
                _httpx2_zig.close_client(self._handle)
                self._handle = None
