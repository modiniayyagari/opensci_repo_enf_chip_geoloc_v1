"""Serve live PicoScope reference captures and unsigned metadata over HTTP.

PREPARE/START requests identify a capture by request ID and nonce. The sibling
acquisition module and ps3000a hardware write raw-int16 traces and JSON metadata.
Trace hashes check consistency; they do not authenticate sensor origin.
"""

# STEP_1: Dependencies and configuration
import argparse
import copy
import hashlib
import json
import os
import re
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from auto_trace_capture_v2 import (
    CONFIG,
    close_picoscope,
    complete_capture,
    prepare_capture,
    start_capture,
)


SERVICE_NAME = "ENF_PICO_REFERENCE_SERVICE"
NODE_ID = "REF_PICO_CITYA"
VERIFIER_ID = "VERIF_CITYA"
DEFAULT_BIND = "0.0.0.0"
DEFAULT_PORT = 8766
CAPTURE_DURATION_S = 220
TARGET_SAMPLE_RATE_HZ = 44100
TRACE_FORMAT = "raw_int16_le"
BYTES_PER_SAMPLE = 2
NONCE_PATTERN = re.compile(r"^[0-9a-f]{32}$")
CAPTURE_PATH_PATTERN = re.compile(r"^/capture/(\d+)/(status|metadata|trace)$")


class ApiError(Exception):
    """An HTTP-safe request error."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def _utc_iso(dt):
    """Formats a naive UTC datetime from the capture module as RFC 3339."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat(timespec="microseconds").replace("+00:00", "Z")


# STEP_2: Request identity and duration validation
def _validate_uint32(value, field_name="request_id"):
    """Require a non-boolean unsigned 32-bit request field or raise an HTTP error."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApiError(400, f"{field_name} must be a uint32")
    if not 0 <= value <= 0xFFFFFFFF:
        raise ApiError(400, f"{field_name} must be a uint32")


def _validate_identity(payload, include_duration):
    """Validate Pico transaction fields and optional duration; no signature authentication is performed."""
    expected_fields = {"request_id", "nonce", "verifier_id"}
    if include_duration:
        expected_fields.add("duration_s")

    missing = expected_fields - payload.keys()
    extra = payload.keys() - expected_fields
    if missing:
        raise ApiError(400, f"missing field(s): {', '.join(sorted(missing))}")
    if extra:
        raise ApiError(400, f"unexpected field(s): {', '.join(sorted(extra))}")

    _validate_uint32(payload["request_id"])
    if not isinstance(payload["nonce"], str) or not NONCE_PATTERN.fullmatch(payload["nonce"]):
        raise ApiError(400, "nonce must contain exactly 32 lowercase hex characters")
    if payload["verifier_id"] != VERIFIER_ID:
        raise ApiError(400, f"verifier_id must be {VERIFIER_ID}")

    if include_duration:
        duration = payload["duration_s"]
        if isinstance(duration, bool) or not isinstance(duration, int):
            raise ApiError(400, "duration_s must be an integer")
        if duration != CAPTURE_DURATION_S:
            raise ApiError(400, f"only duration_s={CAPTURE_DURATION_S} is supported")


# STEP_3: Device preparation and transaction lifecycle
class PicoReferenceService:
    """Thread-safe state machine controlling one PicoScope transaction at a time."""

    def __init__(self, trace_directory=None):
        """Initialize transaction state and the trace directory; device preparation occurs later."""
        self.lock = threading.RLock()
        self.state = "IDLE"
        self.transaction = None
        if trace_directory is None:
            trace_directory = os.path.join(os.path.dirname(__file__), "pico_ref_traces")
        self.trace_directory = os.path.abspath(trace_directory)

    def health(self):
        with self.lock:
            return {
                "service": SERVICE_NAME,
                "node_id": NODE_ID,
                "state": self.state,
                "target_sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
                "capture_duration_s": CAPTURE_DURATION_S,
            }

    def prepare(self, payload):
        """Prepare a capture transaction using the supplied request identity and configured duration."""
        _validate_identity(payload, include_duration=True)
        with self.lock:
            if self.state in {"READY", "CAPTURING"}:
                raise ApiError(409, f"cannot PREPARE while service is {self.state}")

            request_id = payload["request_id"]
            transaction = {
                "request_id": request_id,
                "nonce": payload["nonce"],
                "verifier_id": payload["verifier_id"],
                "state": "IDLE",
                "error": None,
                "session": None,
                "metadata": None,
                "worker": None,
            }
            self.transaction = transaction
            self.state = "IDLE"

            capture_config = copy.deepcopy(CONFIG)
            capture_config["CAPTURE_DURATION_S"] = CAPTURE_DURATION_S
            capture_config["SAMPLING_RATE_HZ"] = TARGET_SAMPLE_RATE_HZ
            capture_config["SAVE_DIRECTORY"] = self.trace_directory
            capture_config["FILENAME_PREFIX"] = f"pico_ref_{request_id}"
            timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            trace_path = os.path.join(
                self.trace_directory,
                f"pico_ref_{request_id}_{timestamp}.bin",
            )

            try:
                session = prepare_capture(capture_config, full_path=trace_path)
            except Exception as exc:
                message = f"PicoScope preparation failed: {exc}"
                transaction["state"] = "ERROR"
                transaction["error"] = message
                self.state = "ERROR"
                raise ApiError(500, message) from exc

            transaction["session"] = session
            transaction["state"] = "READY"
            self.state = "READY"
            interval_ns = float(session["time_interval_ns"].value)
            return {
                "request_id": request_id,
                "state": "READY",
                "node_id": NODE_ID,
                "target_sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
                "actual_sample_interval_ns": interval_ns,
                "actual_sample_rate_hz": 1e9 / interval_ns,
            }

    def start(self, payload):
        """Start the identified prepared capture transaction."""
        _validate_identity(payload, include_duration=False)
        with self.lock:
            transaction = self._matching_transaction(payload["request_id"])
            if self.state != "READY" or transaction["state"] != "READY":
                raise ApiError(409, f"cannot START while transaction is {transaction['state']}")
            if (payload["nonce"] != transaction["nonce"] or
                    payload["verifier_id"] != transaction["verifier_id"]):
                raise ApiError(409, "START transaction identifiers do not match PREPARE")

            try:
                # This call does not return until ps3000aRunBlock succeeds.
                start_capture(transaction["session"])
            except Exception as exc:
                message = f"PicoScope start failed: {exc}"
                try:
                    self._close_transaction_scope(transaction)
                except Exception as cleanup_exc:
                    message += f"; cleanup failed: {cleanup_exc}"
                transaction["state"] = "ERROR"
                transaction["error"] = message
                self.state = "ERROR"
                raise ApiError(500, message) from exc

            transaction["state"] = "CAPTURING"
            self.state = "CAPTURING"
            worker = threading.Thread(
                target=self._capture_worker,
                args=(transaction,),
                name=f"pico-capture-{transaction['request_id']}",
                daemon=False,
            )
            transaction["worker"] = worker
            worker.start()
            return {
                "request_id": transaction["request_id"],
                "state": "CAPTURING",
                "node_id": NODE_ID,
            }

    def status(self, request_id):
        _validate_uint32(request_id)
        with self.lock:
            transaction = self._matching_transaction(request_id)
            response = {
                "request_id": request_id,
                "state": transaction["state"],
            }
            if transaction["state"] == "ERROR":
                response["error"] = transaction["error"]
            if transaction["state"] == "COMPLETE":
                response["actual_samples"] = transaction["metadata"]["actual_samples"]
            return response

    def metadata(self, request_id):
        """Return or download capture metadata for the identified request."""
        _validate_uint32(request_id)
        with self.lock:
            transaction = self._matching_transaction(request_id)
            if transaction["state"] != "COMPLETE":
                raise ApiError(409, "metadata is available only after COMPLETE")
            return dict(transaction["metadata"])

    def trace_path(self, request_id):
        """Return a completed transaction's saved trace path or raise an HTTP state error."""
        _validate_uint32(request_id)
        with self.lock:
            transaction = self._matching_transaction(request_id)
            if transaction["state"] != "COMPLETE":
                raise ApiError(409, "trace is available only after COMPLETE")
            return transaction["metadata"]["trace_path"]

    def close_ready_scope(self):
        """Releases a PREPAREd scope when the server stops before START."""
        with self.lock:
            if self.state == "READY" and self.transaction is not None:
                self._close_transaction_scope(self.transaction)
                self.transaction["state"] = "ERROR"
                self.transaction["error"] = "server stopped before capture START"
                self.state = "ERROR"

    def _matching_transaction(self, request_id):
        """Return the active matching request or raise a not-found HTTP error."""
        if self.transaction is None or self.transaction["request_id"] != request_id:
            raise ApiError(404, f"capture request {request_id} was not found")
        return self.transaction

    @staticmethod
    def _close_transaction_scope(transaction):
        """Close a transaction's scope once, including capture-error cleanup."""
        session = transaction.get("session")
        if session is not None and not session.get("scope_closed", False):
            try:
                close_picoscope(session["scope_handle"])
            finally:
                session["scope_closed"] = True

    def _capture_worker(self, transaction):
        """Complete device capture and persist trace metadata; publish failures in transaction state."""
        error = None
        metadata = None
        try:
            session = complete_capture(
                transaction["session"], output_format=TRACE_FORMAT
            )
            trace_path = session["full_path"]
            trace_size_bytes = os.path.getsize(trace_path)
            expected_size_bytes = session["actual_samples"] * BYTES_PER_SAMPLE
            if trace_size_bytes != expected_size_bytes:
                raise ValueError(
                    f"raw trace size mismatch: expected {expected_size_bytes} bytes, "
                    f"found {trace_size_bytes} bytes"
                )

            digest = hashlib.sha256()
            with open(trace_path, "rb") as trace_file:
                for chunk in iter(lambda: trace_file.read(1024 * 1024), b""):
                    digest.update(chunk)

            interval_ns = float(session["time_interval_ns"].value)
            timestamps = session["timestamps"]
            metadata = {
                "service": SERVICE_NAME,
                "node_id": NODE_ID,
                "request_id": transaction["request_id"],
                "nonce": transaction["nonce"],
                "verifier_id": transaction["verifier_id"],
                "capture_duration_s": CAPTURE_DURATION_S,
                "target_sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
                "actual_sample_interval_ns": interval_ns,
                "actual_sample_rate_hz": 1e9 / interval_ns,
                "expected_samples": session["expected_samples"],
                "actual_samples": session["actual_samples"],
                "channel": session["config"]["TRIGGER_CHANNEL"],
                "voltage_range": session["config"]["VOLTAGE_RANGE"],
                "coupling": session["config"]["COUPLING_TYPE"],
                "trace_format": TRACE_FORMAT,
                "sample_format": "int16",
                "byte_order": "little",
                "bytes_per_sample": BYTES_PER_SAMPLE,
                "trace_filename": os.path.basename(trace_path),
                "trace_path": trace_path,
                "trace_size_bytes": trace_size_bytes,
                "trace_sha256": digest.hexdigest(),
                "capture_started_utc": _utc_iso(timestamps["capture_started_utc"]),
                "capture_completed_utc": _utc_iso(timestamps["capture_completed_utc"]),
                "trace_save_started_utc": _utc_iso(timestamps["trace_save_started_utc"]),
                "trace_save_completed_utc": _utc_iso(timestamps["trace_save_completed_utc"]),
                "capture_started_perf_counter_ns": timestamps["capture_started_perf_counter_ns"],
                "capture_completed_perf_counter_ns": timestamps["capture_completed_perf_counter_ns"],
                "trace_save_started_perf_counter_ns": timestamps["trace_save_started_perf_counter_ns"],
                "trace_save_completed_perf_counter_ns": timestamps["trace_save_completed_perf_counter_ns"],
                "authenticated": False,
            }
        except Exception as exc:
            error = f"PicoScope capture failed: {exc}"
        finally:
            try:
                self._close_transaction_scope(transaction)
            except Exception as exc:
                if error is None:
                    error = f"PicoScope cleanup failed: {exc}"

        with self.lock:
            # PREPARE cannot replace an active transaction, but retain this guard.
            if self.transaction is not transaction:
                return
            if error is not None:
                transaction["state"] = "ERROR"
                transaction["error"] = error
                self.state = "ERROR"
            else:
                transaction["metadata"] = metadata
                transaction["state"] = "COMPLETE"
                self.state = "COMPLETE"


# STEP_4: Existing HTTP protocol handling
class PicoReferenceRequestHandler(BaseHTTPRequestHandler):
    """JSON/raw-binary HTTP interface for PicoReferenceService."""

    server_version = "ENFPicoReference/1.0"

    @property
    def service(self):
        return self.server.reference_service

    def do_GET(self):
        """Serve health or capture resources, returning HTTP errors for invalid requests."""
        path = urlparse(self.path).path
        try:
            if path == "/health":
                self._send_json(200, self.service.health())
                return

            match = CAPTURE_PATH_PATTERN.fullmatch(path)
            if match is None:
                raise ApiError(404, "endpoint not found")
            request_id = int(match.group(1))
            endpoint = match.group(2)
            if endpoint == "status":
                self._send_json(200, self.service.status(request_id))
            elif endpoint == "metadata":
                metadata = self.service.metadata(request_id)
                metadata.pop("trace_path", None)
                self._send_json(200, metadata)
            else:
                self._send_trace(self.service.trace_path(request_id))
        except ApiError as exc:
            self._send_json(exc.status, {"error": exc.message})
        except Exception as exc:
            self._send_json(500, {"error": f"internal server error: {exc}"})

    def do_POST(self):
        """Dispatch capture PREPARE/START requests and report validation or state errors."""
        path = urlparse(self.path).path
        try:
            payload = self._read_json_body()
            if path == "/capture/prepare":
                self._send_json(200, self.service.prepare(payload))
            elif path == "/capture/start":
                self._send_json(200, self.service.start(payload))
            else:
                raise ApiError(404, "endpoint not found")
        except ApiError as exc:
            self._send_json(exc.status, {"error": exc.message})
        except Exception as exc:
            self._send_json(500, {"error": f"internal server error: {exc}"})

    def _read_json_body(self):
        """Read and validate the HTTP JSON request body; reject malformed input."""
        content_type = self.headers.get_content_type()
        if content_type != "application/json":
            raise ApiError(415, "Content-Type must be application/json")
        try:
            content_length = int(self.headers.get("Content-Length", ""))
        except ValueError as exc:
            raise ApiError(400, "invalid Content-Length") from exc
        if not 0 < content_length <= 65536:
            raise ApiError(400, "JSON body must contain 1 to 65536 bytes")
        try:
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError(400, "request body must be valid UTF-8 JSON") from exc
        if not isinstance(payload, dict):
            raise ApiError(400, "request JSON must be an object")
        return payload

    def _send_json(self, status, payload):
        """Write an HTTP JSON response with its status and byte length."""
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_trace(self, trace_path):
        """Stream a completed raw Pico trace to the HTTP client."""
        size = os.path.getsize(trace_path)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(trace_path, "rb") as trace_file:
            for chunk in iter(lambda: trace_file.read(1024 * 1024), b""):
                self.wfile.write(chunk)


# STEP_5: Reference service entrypoint and cleanup
def main():
    """Parse the bind/output options and run the live Pico HTTP service."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default=DEFAULT_BIND)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--trace-directory", default=None)
    args = parser.parse_args()

    service = PicoReferenceService(args.trace_directory)
    server = ThreadingHTTPServer((args.bind, args.port), PicoReferenceRequestHandler)
    server.reference_service = service
    print(f"{SERVICE_NAME} ({NODE_ID}) listening on {args.bind}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping Pico reference service.")
    finally:
        server.server_close()
        service.close_ready_scope()


if __name__ == "__main__":
    main()
