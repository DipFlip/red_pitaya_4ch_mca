"""Bounded live MCA statistics and a read-only, dependency-free HTTP dashboard."""
from collections import deque
import csv
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import threading
import time

WEB = Path(__file__).with_name("web")


class Dashboard:
    def __init__(self, channels, bins=256, maximum=25.0, recording=None):
        self.lock = threading.Lock()
        self.bins, self.maximum = bins, maximum
        self.started = time.monotonic()
        self.updated = None
        self.phase, self.error = "starting", None
        self.status = {}
        self.recording = str(recording) if recording else None
        self.channels = {c: dict(channel=c, accepted=0, rejected=0, cps=0,
                                 live_fraction=0, histogram=[0] * bins,
                                 underflow=0, overflow=0, history=deque(maxlen=1200))
                         for c in channels}
        self.origin = None
        self.server = None

    def batch(self, channel, start, end, live, records, reject_flags):
        with self.lock:
            row = self.channels[channel]
            accepted = 0
            for words in records:
                if (words[2] >> 16) & reject_flags:
                    row["rejected"] += 1
                    continue
                accepted += 1
                raw = words[4]
                integral = (raw - (1 << 32) if raw & (1 << 31) else raw) * .008 / 8192
                if integral < 0:
                    row["underflow"] += 1
                elif integral >= self.maximum:
                    row["overflow"] += 1
                else:
                    row["histogram"][int(integral / self.maximum * self.bins)] += 1
            row["accepted"] += accepted
            duration = (end - start) / 125000000
            row["cps"] = accepted / duration if duration else 0
            row["live_fraction"] = live / (end - start) if end > start else 0
            if self.origin is None:
                self.origin = start
            row["history"].append([(end - self.origin) / 125000000, row["cps"]])

    def set_channels(self, channels):
        """Replay gets its active input set from metadata, not CLI defaults."""
        with self.lock:
            if set(channels) == set(self.channels):
                return
            self.channels = {c: dict(channel=c, accepted=0, rejected=0, cps=0,
                                     live_fraction=0, histogram=[0] * self.bins,
                                     underflow=0, overflow=0, history=deque(maxlen=1200))
                             for c in channels}

    def set_status(self, status):
        with self.lock:
            self.status = status
            self.updated = time.monotonic()
            self.phase = "complete" if status["type"] == "summary" else "running"

    def fail(self, error):
        with self.lock:
            self.phase, self.error = "error", str(error)

    def snapshot(self):
        with self.lock:
            now = time.monotonic()
            return dict(phase=self.phase, error=self.error, recording=self.recording,
                        uptime_s=now - self.started,
                        age_s=None if self.updated is None else now - self.updated,
                        histogram_max=self.maximum, histogram_bins=self.bins,
                        status=self.status,
                        channels=[dict(row, history=list(row["history"]),
                                       histogram=list(row["histogram"]))
                                  for row in self.channels.values()])

    def start(self, host, port):
        dashboard = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                route = self.path.split("?", 1)[0]
                extra = {}
                if route == "/favicon.ico":
                    self.send_response(204)
                    self.end_headers()
                    return
                if route == "/api/state":
                    body = json.dumps(dashboard.snapshot(), allow_nan=False).encode()
                    mime = "application/json"
                elif route == "/api/spectrum.csv":
                    state = dashboard.snapshot()
                    output = io.StringIO()
                    writer = csv.writer(output)
                    writer.writerow(["channel", "low_v_us", "high_v_us", "accepted_count"])
                    width = state["histogram_max"] / state["histogram_bins"]
                    for row in state["channels"]:
                        for i, count in enumerate(row["histogram"]):
                            writer.writerow([row["channel"], i * width, (i + 1) * width, count])
                    body, mime = output.getvalue().encode(), "text/csv"
                    extra["Content-Disposition"] = 'attachment; filename="mca-spectrum.csv"'
                elif route in ("/", "/app.js", "/style.css"):
                    filename, mime = {"/": ("index.html", "text/html"),
                                      "/app.js": ("app.js", "text/javascript"),
                                      "/style.css": ("style.css", "text/css")}[route]
                    body = (WEB / filename).read_bytes()
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", mime + "; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'")
                for name, value in extra.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer((host, port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self.server.server_address[1]

    def close(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
