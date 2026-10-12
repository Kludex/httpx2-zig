# httpx2-zig

An experimental synchronous HTTP/1.1 transport for [HTTPX2](https://github.com/pydantic/httpx2), backed by Zig's standard library HTTP client.

## Install

```sh
uv pip install "git+https://github.com/Kludex/httpx2-zig.git"
```

The source build uses Zig 0.16.0 through `hatch-ziglang`. The extension is built for your Python version and platform. The package has not been published to PyPI.

## Use

```python
import httpx2
from httpx2_zig import ZigTransport

with httpx2.Client(transport=ZigTransport()) as client:
    response = client.get("https://example.com/")
    print(response.status_code, response.text)
```

`ZigTransport` supports HTTP and HTTPS, connection reuse, redirects through HTTPX2, and the methods available in Zig's `std.http.Method`. It buffers request and response bodies in memory and serializes calls through each transport instance. Streaming, timeouts, proxies, HTTP/2, and an async transport are not supported yet.

## Develop

```sh
uv sync
uv run pytest -q tests
./scripts/check
```

The transport lives entirely in this package. HTTPX2 does not need a patch or a `library_path` argument.
