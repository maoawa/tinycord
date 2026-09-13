"""Verify the shipped Caddy policy locally, without issuing public certificates.

Usage: CADDY_BIN=/path/to/caddy python tests/verify_tls.py
Uses only temporary certificates, loopback ports and synthetic credentials.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class Backend(BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.calls.append(dict(self.headers))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    do_POST = do_GET

    def log_message(self, *_):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    thread = threading.Thread(target=backend.serve_forever, daemon=True)
    thread.start()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="tinycord-tls-") as directory:
            root = Path(directory)
            cert, key = root / "cert.pem", root / "key.pem"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                "-keyout", str(key), "-out", str(cert),
            ], check=True, capture_output=True)
            http_port, https_port = free_port(), free_port()
            config = (Path(__file__).parents[1] / "Caddyfile").read_text()
            config = config.replace("{\n", f"{{\n\thttp_port {http_port}\n\thttps_port {https_port}\n", 1)
            config = config.replace("tls {", f"tls {cert} {key} {{")
            config = config.replace("companion:8080", f"127.0.0.1:{backend.server_port}")
            (root / "Caddyfile").write_text(config)
            env = {**os.environ, "COMPANION_DOMAIN": "localhost", "ACME_EMAIL": "test@example.com",
                   "XDG_DATA_HOME": str(root / "data"), "XDG_CONFIG_HOME": str(root / "config")}
            process = subprocess.Popen([os.environ["CADDY_BIN"], "run", "--config", str(root / "Caddyfile")],
                                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.create_default_context(cafile=str(cert))
            for attempt in range(50):
                try:
                    with urlopen(f"https://localhost:{https_port}/healthz", context=context, timeout=1) as result:
                        assert result.status == 200
                    break
                except (URLError, OSError):
                    if process.poll() is not None or attempt == 49:
                        raise RuntimeError("Caddy failed to start") from None
                    time.sleep(0.1)
            Backend.calls.clear()
            try:
                urlopen(f"http://localhost:{http_port}/v1/session", timeout=2)
                raise AssertionError("HTTP unexpectedly allowed")
            except HTTPError as error:
                assert error.code == 426
            assert not Backend.calls, "Plain HTTP reached the backend"
            request = Request(f"https://localhost:{https_port}/healthz", headers={
                "X-Forwarded-Proto": "http", "Authorization": "Bearer synthetic-test-credential",
            })
            with urlopen(request, context=context, timeout=2) as result:
                assert result.status == 200
                assert result.headers["Strict-Transport-Security"] == "max-age=31536000"
                assert result.headers["Cache-Control"] == "no-store"
            headers = {key.lower(): value for key, value in Backend.calls[-1].items()}
            assert headers["x-forwarded-proto"] == "https"
            assert headers["authorization"] == "Bearer synthetic-test-credential"
            print("TLS policy verified: HTTPS works, HTTP is rejected, HSTS/no-store set, forwarded scheme overwritten.")
    finally:
        if process:
            process.terminate()
            process.wait(timeout=10)
        backend.shutdown()
        backend.server_close()


if __name__ == "__main__":
    main()
