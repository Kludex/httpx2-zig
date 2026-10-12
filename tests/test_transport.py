from __future__ import annotations

from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

import httpx2
import pytest

from httpx2_zig import ZigTransport


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    connection_count = 0

    def setup(self) -> None:
        super().setup()
        type(self).connection_count += 1
        self.connection_number = type(self).connection_count

    def do_GET(self) -> None:
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/done")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/large":
            self.send_response(200)
            self.send_header("Content-Length", "102400")
            self.send_header("X-Connection-Number", str(self.connection_number))
            self.end_headers()
            self.wfile.write(b"x" * 102400)
            return
        self.send_response(201)
        self.send_header("X-Answer", "one")
        self.send_header("X-Answer", "two")
        self.send_header("X-Connection-Number", str(self.connection_number))
        self.send_header("Content-Length", "5")
        self.end_headers()
        self.wfile.write(b"hello")

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("X-Content-Length-Count", str(len(self.headers.get_all("Content-Length", []))))
        self.send_header("X-Connection-Number", str(self.connection_number))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


def test_zig_transport() -> None:
    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever)
    thread.start()
    try:
        transport = ZigTransport()
        with httpx2.Client(transport=transport, follow_redirects=True) as client:
            base = f"http://127.0.0.1:{server.server_port}"
            response = client.get(base + "/redirect")
            assert response.status_code == 201
            assert response.content == b"hello"
            assert response.headers.get_list("x-answer") == ["one", "two"]
            assert len(response.history) == 1
            posted = client.post(base + "/echo", content=b"abc")
            assert posted.content == b"abc"
            assert posted.headers["x-content-length-count"] == "1"
            assert posted.headers["x-connection-number"] == response.headers["x-connection-number"]
            large = client.get(base + "/large")
            assert large.content == b"x" * 102400
            assert client.get(base + "/done").headers["x-connection-number"] == large.headers["x-connection-number"]
            with pytest.raises(httpx2.TransportError, match="UnsupportedMethod"):
                client.request("QUERY", base + "/")
        transport.close()
        with pytest.raises(RuntimeError, match="closed"):
            transport.handle_request(httpx2.Request("GET", base + "/"))
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
