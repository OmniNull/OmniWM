import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, address):
        super().__init__(address, Handler)
        self.state_lock = threading.Lock()
        self.release = threading.Event()
        self.requests = 0
        self.stalled = 0
        self.slots = threading.BoundedSemaphore(64)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def respond(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/metrics":
            with self.server.state_lock:
                body = {"requests": self.server.requests, "stalled": self.server.stalled}
            self.respond(200, json.dumps(body).encode())
            return
        with self.server.state_lock:
            self.server.requests += 1
            number = self.server.requests
        if url.path == "/stall":
            with self.server.state_lock:
                self.server.stalled += 1
            try:
                self.server.release.wait()
            finally:
                with self.server.state_lock:
                    self.server.stalled -= 1
        if url.path == "/invalid-json":
            self.respond(200, b'{"workflow_runs":[')
        elif url.path == "/bytes":
            try:
                size = int(query.get("size", ["1048576"])[0])
            except ValueError:
                self.respond(400, b'{"error":"invalid size"}')
                return
            if not 0 <= size <= 5 * 1024 * 1024:
                self.respond(400, b'{"error":"size exceeds fixture bound"}')
                return
            self.respond(200, b"x" * size, "application/octet-stream")
        elif url.path == "/status/503":
            self.respond(503, b'{"message":"fixture unavailable"}')
        else:
            body = {"workflow_runs": [{"id": number, "name": "Fixture pipeline", "status": "completed",
                                      "conclusion": query.get("conclusion", ["success"])[0], "run_attempt": 1}]}
            self.respond(200, json.dumps(body).encode())

    def do_POST(self):
        if self.path == "/release":
            self.server.release.set()
            self.respond(200, b'{"released":true}')
        elif self.path == "/arm":
            with self.server.state_lock:
                if self.server.stalled:
                    self.respond(409, b'{"error":"wait for released requests to finish"}')
                    return
                self.server.release.clear()
            self.respond(200, b'{"armed":true}')
        else:
            self.respond(404, b'{}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = FixtureServer(("127.0.0.1", args.port))
    print(json.dumps({"url": f"http://127.0.0.1:{server.server_address[1]}"}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.release.set()
        server.server_close()


if __name__ == "__main__":
    main()
