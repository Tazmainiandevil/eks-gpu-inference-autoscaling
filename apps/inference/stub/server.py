"""
Stub inference server for architecture validation.

Exposes /health, /ready, /metrics (Prometheus), /queue, and /infer endpoints.
Does not require CUDA — just schedules on a GPU node and stays healthy,
proving Karpenter provisioning and KEDA scaling work end-to-end.

Metrics exported (visible in Grafana):
  gpu_job_queue_depth                 — gauge, set via /queue/depth/<n> or Pushgateway
  inference_requests_total            — counter, increments on every /infer POST
  inference_request_duration_seconds  — histogram, records /infer latency (p50/p95/p99)
  inference_errors_total              — counter, increments on /infer failures
  inference_uptime_seconds            — gauge

Usage:
  POST /infer                  — simulate inference (sleep latency_ms ms, record histogram)
  POST /queue/depth/{n}        — set gpu_job_queue_depth (for testing without Pushgateway)
  GET  /metrics                — Prometheus metrics endpoint
  GET  /health                 — liveness probe
  GET  /ready                  — readiness probe
"""
import os
import time
import random
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# ── Histogram implementation (stdlib only) ────────────────────────────────────
# Buckets in seconds covering 10ms → 30s inference range
_HIST_BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, float("inf")]

_queue_depth = 0
_request_count = 0
_infer_count = 0
_infer_errors = 0
_infer_duration_sum = 0.0
_infer_duration_buckets = [0] * len(_HIST_BUCKETS)
_start_time = time.time()
_lock = threading.Lock()


def _record_duration(duration_seconds: float) -> None:
    """Record a duration sample into the histogram buckets (called under _lock)."""
    global _infer_duration_sum
    _infer_duration_sum += duration_seconds
    for i, upper in enumerate(_HIST_BUCKETS):
        if duration_seconds <= upper:
            _infer_duration_buckets[i] += 1
            break  # store in the narrowest matching bucket; _histogram_lines accumulates


def _histogram_lines() -> str:
    """Render the duration histogram in Prometheus text format."""
    lines = [
        "# HELP inference_request_duration_seconds Inference request latency in seconds",
        "# TYPE inference_request_duration_seconds histogram",
    ]
    cumulative = 0
    for i, upper in enumerate(_HIST_BUCKETS):
        cumulative += _infer_duration_buckets[i]
        le = "+Inf" if upper == float("inf") else str(upper)
        lines.append(f'inference_request_duration_seconds_bucket{{le="{le}"}} {cumulative}')
    lines.append(f"inference_request_duration_seconds_sum {_infer_duration_sum:.6f}")
    lines.append(f"inference_request_duration_seconds_count {_infer_count}")
    return "\n".join(lines)


def metrics_output() -> str:
    uptime = time.time() - _start_time
    with _lock:
        hist = _histogram_lines()
        queue = _queue_depth
        reqs = _request_count
        infer = _infer_count
        errors = _infer_errors

    return "\n".join([
        "# HELP gpu_job_queue_depth Current depth of the GPU job queue",
        "# TYPE gpu_job_queue_depth gauge",
        f'gpu_job_queue_depth{{job="inference-stub"}} {queue}',
        "# HELP inference_requests_total Total HTTP requests handled",
        "# TYPE inference_requests_total counter",
        f"inference_requests_total {reqs}",
        "# HELP inference_infer_total Total /infer requests processed",
        "# TYPE inference_infer_total counter",
        f"inference_infer_total {infer}",
        "# HELP inference_errors_total Total /infer requests that returned an error",
        "# TYPE inference_errors_total counter",
        f"inference_errors_total {errors}",
        hist,
        "# HELP inference_uptime_seconds Time since pod started",
        "# TYPE inference_uptime_seconds gauge",
        f"inference_uptime_seconds {uptime:.2f}",
    ]) + "\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log noise

    def _send(self, code, body, content_type="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self):
        global _request_count
        with _lock:
            _request_count += 1
        path = urlparse(self.path).path

        if path in ("/health", "/healthz"):
            self._send(200, '{"status":"healthy"}')
        elif path in ("/ready", "/readyz"):
            self._send(200, '{"status":"ready"}')
        elif path == "/metrics":
            self._send(200, metrics_output(), "text/plain; version=0.0.4")
        elif path == "/":
            self._send(200, '{"service":"inference-stub","version":"1.0.0"}')
        else:
            self._send(404, '{"error":"not found"}')

    def do_POST(self):
        global _queue_depth, _infer_count, _infer_errors
        path = urlparse(self.path).path

        # ── Set queue depth (for testing without Pushgateway) ──
        if path.startswith("/queue/depth/"):
            try:
                depth = int(path.split("/")[-1])
                with _lock:
                    _queue_depth = max(0, depth)
                    d = _queue_depth
                self._send(200, f'{{"queue_depth":{d}}}')
            except ValueError:
                self._send(400, '{"error":"depth must be an integer"}')
            return

        # ── Simulated inference endpoint ──────────────────────
        if path == "/infer":
            t_start = time.monotonic()
            try:
                # Parse optional latency_ms from body: {"latency_ms": 200}
                # Default: random uniform 50–500ms to simulate real model variance
                body = self._read_body()
                latency_ms = None
                if body:
                    import json
                    try:
                        latency_ms = json.loads(body).get("latency_ms")
                    except Exception:
                        pass
                if latency_ms is None:
                    latency_ms = random.uniform(50, 500)
                time.sleep(latency_ms / 1000.0)

                duration = time.monotonic() - t_start
                with _lock:
                    _infer_count += 1
                    _record_duration(duration)
                    count = _infer_count

                self._send(200, f'{{"result":"ok","latency_ms":{duration*1000:.1f},"request_id":{count}}}')
            except Exception as exc:
                duration = time.monotonic() - t_start
                with _lock:
                    _infer_errors += 1
                    _record_duration(duration)
                self._send(500, f'{{"error":"{exc}"}}')
            return

        self._send(404, '{"error":"not found"}')


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Inference stub listening on :{port}")
    print("Endpoints: /health /ready /metrics /queue/depth/<n> /infer")
    server.serve_forever()
