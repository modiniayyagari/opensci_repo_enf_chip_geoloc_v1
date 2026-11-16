"""Coordinate live UART attestation and HTTP reference acquisition.

Sends fresh request nonces, authenticates board and mains ECDSA evidence,
checks unsigned Pico metadata and trace hashes, and invokes saved-data ENF
comparison. Requires a programmed board, UART, and configured reference
services; writes request evidence, traces, logs, and numerical outputs.
Workflow PASS is not geographic acceptance. The bundled board key is public
demonstration material; Pico evidence is unauthenticated.
"""

# STEP_1: Dependencies and configuration
import argparse
import csv
import hashlib
import hmac
import json
import math
import os
import secrets
import serial
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib import error as urllib_error
from urllib import request as urllib_request

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed, encode_dss_signature


BOARD_ATTESTATION_PROTOCOL = "ENF_LOCATION_ATTESTATION"
REFERENCE_CAPTURE_PROTOCOL = "ENF_REFERENCE_CAPTURE"
REFERENCE_SERVICE_ID = "ENF_REFERENCE_SERVICE"
VERIFIER_ID = "VERIF_CITYA"
REF_NODE_ID = "REF_CITYA"
PICO_REF_NODE_ID = "REF_PICO_CITYA"
PICO_REF_SERVICE_ID = "ENF_PICO_REFERENCE_SERVICE"
PICO_REF_DURATION_SECONDS = 220
PICO_REF_TARGET_SAMPLE_RATE_HZ = 44100
PICO_COMPLETE_TIMEOUT_MARGIN_SECONDS = 120.0
ZB_NODE_ID = "ZB_CITYA"
ZB_SIGNATURE_ALGORITHM = "ECDSA_P256_SHA256"
ZB_EXPECTED_PUBLIC_KEY_SHA256 = (
    "5cff0fcb4982b3b6ab8e59bd06b366076a72affbc982abbf557b01be9dfe65ee"
)
BOARD_EVIDENCE_DOMAIN = b"ENF_BOARD_EVIDENCE"
BOARD_EVIDENCE_VERSION = 1
BOARD_EVIDENCE_SIZE = 288
ZB_SIGNATURE_SIZE = 64
REF_SIGNATURE_FORMAT = "RAW_R_S_64"
REFERENCE_EVIDENCE_DOMAIN = b"ENF_REFERENCE_EVIDENCE"
REFERENCE_EVIDENCE_VERSION = 1
REFERENCE_EVIDENCE_SIZE = 149

PORT = "COM4"
BAUD = 115200
TOTAL_SAMPLES = 400000
PING_TIMEOUT_SECONDS = 5.0
ATTEST_TIMEOUT_SECONDS = 5.0
ATTEST_MAX_ATTEMPTS = 3
GET_TIMEOUT_SECONDS = 5.0
DEFAULT_BOARD_EVIDENCE_TIMEOUT_SECONDS = 300.0
DEFAULT_REF_DURATION_SECONDS = 220.0
DEFAULT_REF_PRE_ROLL_SECONDS = 10.0
DEFAULT_REF_POLL_INTERVAL_SECONDS = 0.1
DEFAULT_REF_HTTP_TIMEOUT_SECONDS = 5.0
DEFAULT_REF_TRACE_BASENAME = "mains_pow_trace_220s_reference"
REF_COMPLETE_TIMEOUT_MARGIN_SECONDS = 60.0
PROBE_PONG_TIMEOUT_SECONDS = 1.0
SYNC_RETRY_DELAY_SECONDS = 0.25
SYNC_DRAIN_SECONDS = 0.15

VERIFIER_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = VERIFIER_ROOT.parent / "fpga_enf_data"
TRUST_STORE_PATH = VERIFIER_ROOT / "keys" / "trusted" / "trust_store.json"
REFERENCE_PROCESSOR_PATH = Path(__file__).resolve().parent / "enf_reference_processing.py"
ASCII_RX_BUFFER = bytearray()
ACTIVE_LOG_FILE = None
ACTIVE_REQUEST_PATHS = None
ACTIVE_REQUEST_ID = None
ACTIVE_PROCESSING_STARTED = False


# STEP_2: CLI and transaction input validation
def parse_request_id_arg(text):
    if not text.isdigit():
        raise argparse.ArgumentTypeError("request ID must be a positive decimal integer")
    value = int(text, 10)
    if not 0 < value <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError("request ID must be within 1..0xffffffff")
    return value


def parse_positive_float_arg(text):
    value = float(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def parse_nonnegative_float_arg(text):
    value = float(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return value


def parse_ref_trace_basename_arg(text):
    if not text or text in (".", "..") or "/" in text or "\\" in text:
        raise argparse.ArgumentTypeError("must be a filename basename")
    return text


def parse_refdb_url_arg(text):
    """Accept HTTP(S) or resolve the mains alias through ENF_REFDB_URL."""
    if text == "REF_CITYA_IP":
        text = os.environ.get("ENF_REFDB_URL", "")
        if not text:
            raise argparse.ArgumentTypeError("set ENF_REFDB_URL or supply an explicit HTTP(S) --refdb-url")
    if text.startswith(("http://", "https://")):
        return text
    raise argparse.ArgumentTypeError("must be REF_CITYA_IP or an HTTP(S) URL")


def parse_pico_ref_url_arg(text):
    """Accept HTTP(S) or resolve the Pico alias through ENF_PICO_REF_URL."""
    if text == "REF_PICO_CITYA_IP":
        text = os.environ.get("ENF_PICO_REF_URL", "")
        if not text:
            raise argparse.ArgumentTypeError("set ENF_PICO_REF_URL or supply an explicit HTTP(S) --pico-ref-url")
    if text.startswith(("http://", "https://")):
        return text
    raise argparse.ArgumentTypeError("must be REF_PICO_CITYA_IP or an HTTP(S) URL")


def parse_args():
    parser = argparse.ArgumentParser(
        description="ZedBoard and dual-reference acquisition and ENF comparison verifier."
    )
    parser.add_argument("--request-id", type=parse_request_id_arg)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
                        help="Capture root containing reqid_N groups; default: fpga_enf_data/.")
    parser.add_argument(
        "--board-evidence-timeout-s", type=parse_positive_float_arg,
        default=DEFAULT_BOARD_EVIDENCE_TIMEOUT_SECONDS,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ping-only", action="store_true")
    mode.add_argument(
        "--fpga-only", "--board-only", dest="fpga_only", action="store_true",
        help="Run authenticated board evidence without Reference DB matching.",
    )
    parser.add_argument("--refdb-url", type=parse_refdb_url_arg)
    parser.add_argument("--pico-ref-url", type=parse_pico_ref_url_arg)
    parser.add_argument("--ref-duration", type=parse_positive_float_arg,
                        default=DEFAULT_REF_DURATION_SECONDS)
    parser.add_argument("--ref-pre-roll", type=parse_nonnegative_float_arg,
                        default=DEFAULT_REF_PRE_ROLL_SECONDS)
    parser.add_argument("--ref-poll-interval", type=parse_positive_float_arg,
                        default=DEFAULT_REF_POLL_INTERVAL_SECONDS)
    parser.add_argument("--ref-http-timeout", type=parse_positive_float_arg,
                        default=DEFAULT_REF_HTTP_TIMEOUT_SECONDS)
    parser.add_argument("--ref-trace-basename", type=parse_ref_trace_basename_arg,
                        default=DEFAULT_REF_TRACE_BASENAME)
    args = parser.parse_args()
    args.output_dir = args.output_dir.expanduser().resolve()
    if not args.ping_only and not args.fpga_only:
        if not args.refdb_url or not args.pico_ref_url:
            parser.error("--refdb-url and --pico-ref-url are required for full acquisition")
    return args


# STEP_3: Logging and UART transport
def log_print(*args):
    """Print a diagnostic and append it to the active request log when available."""
    message = " ".join(str(arg) for arg in args)
    print(message, flush=True)
    if ACTIVE_LOG_FILE is not None:
        ACTIVE_LOG_FILE.write(message + "\n")
        ACTIVE_LOG_FILE.flush()


def log_board_line(line):
    """Associate a board UART line with the active verifier log."""
    log_print(f"[BOARD -> VERIFIER] {line}")


def send_command(ser, command):
    """Write and flush one ASCII UART command with CRLF framing, then log it."""
    ser.write((command + "\r\n").encode("ascii"))
    ser.flush()
    log_print(f"[VERIFIER -> BOARD] {command}")


def reset_ascii_rx_buffer():
    """Clear the verifier's partial UART line buffer before synchronization."""
    ASCII_RX_BUFFER.clear()


def read_ascii_line(ser, deadline):
    """Return a buffered ASCII UART line, or None at the monotonic deadline."""
    while True:
        newline_index = ASCII_RX_BUFFER.find(b"\n")
        if newline_index != -1:
            raw_line = bytes(ASCII_RX_BUFFER[: newline_index + 1])
            del ASCII_RX_BUFFER[: newline_index + 1]
            line = raw_line.decode("ascii", errors="replace").rstrip("\r\n")
            if line:
                return line
            continue
        if time.monotonic() >= deadline:
            return None
        raw_line = ser.readline()
        if raw_line:
            ASCII_RX_BUFFER.extend(raw_line)


def read_nonempty_line(ser, deadline, timeout_message):
    """Skip empty UART lines until a response arrives or the deadline expires."""
    line = read_ascii_line(ser, deadline)
    if line is None:
        raise RuntimeError(timeout_message)
    return line


def check_error_line(line):
    """Raise if a UART response reports a board-side error."""
    if line.startswith(("ERROR ", "ERROR:")):
        log_board_line(line)
        raise RuntimeError(f"Board protocol error: {line}")


def synchronize_persistent_service(ser):
    """Synchronize the persistent UART service using its PING/PONG exchange."""
    log_print("[BOARD SERVICE] Synchronizing with the persistent ZedBoard service")
    attempt = 0
    waiting_message_printed = False
    while True:
        attempt += 1
        if attempt == 1:
            send_command(ser, "PING")
        else:
            ser.write(b"PING\r\n")
            ser.flush()
        deadline = time.monotonic() + PROBE_PONG_TIMEOUT_SECONDS
        while True:
            line = read_ascii_line(ser, deadline)
            if line is None:
                break
            if line == "PONG":
                log_board_line(line)
                time.sleep(SYNC_DRAIN_SECONDS)
                ser.reset_input_buffer()
                reset_ascii_rx_buffer()
                log_print("[BOARD SERVICE] Persistent ZedBoard service synchronized: PASS")
                return
            check_error_line(line)
        if not waiting_message_printed:
            log_print("[BOARD SERVICE] No service response yet")
            log_print("[BOARD SERVICE] Waiting for the ZedBoard application; press Ctrl+C to cancel")
            waiting_message_printed = True
        time.sleep(SYNC_RETRY_DELAY_SECONDS)


def parse_request_response(line, keyword, request_id):
    """Validate a UART response keyword and its request association."""
    parts = line.split()
    if len(parts) != 2 or parts[0] != keyword or not parts[1].isdigit():
        raise RuntimeError(f"Malformed {keyword} response: {line!r}")
    if int(parts[1], 10) != request_id:
        raise RuntimeError(f"Mismatched request ID in {keyword} response: {line!r}")


def perform_attest_handshake(ser, request_id, nonce_hex):
    """Submit a request ID and nonce through the board's attestation handshake."""
    for attempt in range(1, ATTEST_MAX_ATTEMPTS + 1):
        send_command(ser, f"ATTEST {request_id} {nonce_hex} {VERIFIER_ID}")
        deadline = time.monotonic() + ATTEST_TIMEOUT_SECONDS
        while True:
            line = read_ascii_line(ser, deadline)
            if line is None:
                break
            check_error_line(line)
            if line.startswith("BUSY "):
                log_board_line(line)
                raise RuntimeError(f"Board is busy: {line}")
            if line.startswith("ACCEPTED "):
                log_board_line(line)
                parse_request_response(line, "ACCEPTED", request_id)
                return
            log_board_line(line)
        if attempt < ATTEST_MAX_ATTEMPTS:
            log_print(f"[BOARD ATTESTATION] ACCEPTED not received; retrying ({attempt + 1}/{ATTEST_MAX_ATTEMPTS})")
    raise RuntimeError(f"Timed out waiting for ACCEPTED {request_id}.")


def wait_for_started(ser, request_id):
    """Wait for the requested board capture-start acknowledgement."""
    deadline = time.monotonic() + GET_TIMEOUT_SECONDS
    while True:
        line = read_nonempty_line(ser, deadline, f"Timed out waiting for STARTED {request_id} ENF.")
        check_error_line(line)
        if line.startswith("STARTED "):
            log_board_line(line)
            parts = line.split()
            if parts != ["STARTED", str(request_id), "ENF"]:
                raise RuntimeError(f"Malformed or mismatched STARTED response: {line!r}")
            return
        log_board_line(line)


def decode_uart_fixed_hex(value, field_name, byte_count):
    """Decode a fixed-length UART hex field, rejecting malformed transport data."""
    if len(value) != byte_count * 2 or any(c not in "0123456789abcdef" for c in value):
        raise RuntimeError(f"{field_name} must be {byte_count * 2} lowercase hexadecimal characters.")
    return bytes.fromhex(value)


def parse_zb_transport_record(line, keyword, request_id, byte_count):
    """Validate and decode a request-bound UART evidence or signature record."""
    parts = line.split(" ")
    if len(parts) != 3 or parts[0] != keyword or not parts[1].isdigit():
        raise RuntimeError(f"Malformed {keyword} record: {line!r}")
    if int(parts[1], 10) != request_id:
        raise RuntimeError(f"{keyword} request ID mismatch.")
    return decode_uart_fixed_hex(parts[2], keyword, byte_count)


def parse_zb_benchmark_record(line, request_id):
    """Parse unsigned, unauthenticated diagnostics outside canonical evidence."""
    parts = line.split()
    if len(parts) != 8 or parts[0] != "ZB_BENCHMARK":
        raise ValueError("expected exactly 8 tokens")
    if any(not token or len(token) > 20 or
           any(c not in "0123456789" for c in token) for token in parts[1:]):
        raise ValueError("fields must be unsigned decimal integers")
    rid, timer_hz, count, total, minimum, maximum, crypto = map(int, parts[1:])
    if rid != request_id:
        raise ValueError("request ID mismatch")
    if rid > 0xFFFFFFFF or count > 0xFFFFFFFF or any(
        value > 0xFFFFFFFFFFFFFFFF for value in (timer_hz, total, minimum, maximum, crypto)
    ):
        raise ValueError("field exceeds mailbox integer width")
    if timer_hz <= 0 or count <= 0 or minimum > maximum or total < minimum:
        raise ValueError("invalid timer, count, or tick range")
    return {
        "diagnostic_only": True,
        "request_id": rid,
        "timer_hz": timer_hz,
        "frame_count": count,
        "frame_total_ticks": total,
        "frame_min_ticks": minimum,
        "frame_max_ticks": maximum,
        "frame_mean_seconds": total / count / timer_hz,
        "frame_min_seconds": minimum / timer_hz,
        "frame_max_seconds": maximum / timer_hz,
        "sha256_ecdsa_ticks": crypto,
        "sha256_ecdsa_ms": 1000 * crypto / timer_hz,
    }


# STEP_4: Evidence parsing and authentication
def parse_zb_canonical_evidence(evidence):
    """Decode 288 canonical board bytes; reject domain, version, or acquisition-field mismatches."""
    if not isinstance(evidence, bytes) or len(evidence) != BOARD_EVIDENCE_SIZE:
        raise RuntimeError(f"Canonical ZB ENF evidence must be exactly {BOARD_EVIDENCE_SIZE} bytes.")
    if evidence[:18] != BOARD_EVIDENCE_DOMAIN:
        raise RuntimeError("ZB ENF evidence domain mismatch.")
    if struct.unpack_from(">H", evidence, 18)[0] != BOARD_EVIDENCE_VERSION:
        raise RuntimeError("ZB ENF evidence version mismatch.")
    parsed = {
        "device_id": evidence[40:56].split(b"\0", 1)[0].decode("ascii"),
        "verifier_id": evidence[56:72].split(b"\0", 1)[0].decode("ascii"),
        "request_id": struct.unpack_from(">I", evidence, 20)[0],
        "nonce": evidence[24:40],
        "sample_rate": struct.unpack_from(">I", evidence, 72)[0],
        "capture_duration": struct.unpack_from(">I", evidence, 76)[0],
        "frame_count": struct.unpack_from(">H", evidence, 80)[0],
        "reserved": struct.unpack_from(">H", evidence, 82)[0],
        "enf_unit_scale": struct.unpack_from(">I", evidence, 84)[0],
        "enf_values_nhz": tuple(struct.unpack_from(">Q", evidence, 88 + i * 8)[0] for i in range(25)),
    }
    expected = {"sample_rate": 2000, "capture_duration": 200, "frame_count": 25,
                "reserved": 0, "enf_unit_scale": 1000000000}
    for name, value in expected.items():
        if parsed[name] != value:
            raise RuntimeError(f"ZB ENF evidence {name} mismatch: received {parsed[name]}, expected {value}.")
    return parsed


def load_zb_citya_trusted_public_key():
    """Load the enrolled P-256 board key and enforce its pinned SHA-256 fingerprint."""
    trust_store = json.loads(TRUST_STORE_PATH.read_text(encoding="utf-8"))
    if trust_store.get("verifier_id") != VERIFIER_ID:
        raise RuntimeError("Trust-store verifier identity mismatch.")
    if trust_store.get("protocol") != REFERENCE_CAPTURE_PROTOCOL:
        raise RuntimeError("Trust-store attestation protocol mismatch.")
    identity = trust_store.get("trusted_nodes", {}).get(ZB_NODE_ID)
    if not isinstance(identity, dict):
        raise RuntimeError(f"Trust store does not enroll {ZB_NODE_ID}.")
    if identity.get("role") != "zedboard_attester" or identity.get("algorithm") != ZB_SIGNATURE_ALGORITHM:
        raise RuntimeError("ZB_CITYA trust-store identity mismatch.")
    filename = identity.get("public_key")
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise RuntimeError("ZB_CITYA trust-store public key is invalid.")
    enrolled = identity.get("public_key_sha256")
    if not isinstance(enrolled, str) or not hmac.compare_digest(enrolled, ZB_EXPECTED_PUBLIC_KEY_SHA256):
        raise RuntimeError("ZB_CITYA enrolled fingerprint differs from the pinned value.")
    key = serialization.load_pem_public_key((TRUST_STORE_PATH.parent / filename).read_bytes())
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise RuntimeError("Trusted ZB_CITYA key is not an EC P-256 public key.")
    der = key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if not hmac.compare_digest(hashlib.sha256(der).hexdigest(), ZB_EXPECTED_PUBLIC_KEY_SHA256):
        raise RuntimeError("ZB_CITYA public-key fingerprint validation failed.")
    return key


def authenticate_zb_evidence(evidence, signature, request_id, nonce):
    """Verify raw ECDSA evidence and request/nonce bindings; return decoded fields and digest."""
    parsed = parse_zb_canonical_evidence(evidence)
    if parsed["device_id"] != ZB_NODE_ID:
        raise RuntimeError("ZB identity binding failed.")
    if parsed["verifier_id"] != VERIFIER_ID:
        raise RuntimeError("ZB verifier binding failed.")
    if parsed["request_id"] != request_id:
        raise RuntimeError("ZB request binding failed.")
    if not hmac.compare_digest(parsed["nonce"], nonce):
        raise RuntimeError("ZB nonce binding failed.")
    if len(signature) != ZB_SIGNATURE_SIZE:
        raise RuntimeError("ZB raw signature must be exactly 64 bytes.")
    digest = hashlib.sha256(evidence).digest()
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    try:
        load_zb_citya_trusted_public_key().verify(
            encode_dss_signature(r, s), digest, ec.ECDSA(Prehashed(hashes.SHA256()))
        )
    except InvalidSignature as exc:
        raise RuntimeError("ZB_CITYA ECDSA verification failed.") from exc
    return parsed, digest.hex()


class ReferenceDbError(RuntimeError):
    pass


class ReferenceDbClient:
    def __init__(self, base_url, timeout_seconds):
        self.base_url = base_url.rstrip("/")
        if not self.base_url.startswith(("http://", "https://")):
            raise ReferenceDbError("Reference DB URL must start with http:// or https://")
        self.timeout_seconds = timeout_seconds

    def _request_json(self, method, path, payload=None):
        """Send an HTTP request and decode its JSON response; propagate transport or service errors."""
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib_request.Request(
            self.base_url + path, data=data, headers=headers, method=method
        )
        try:
            with urllib_request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read()
        except urllib_error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise ReferenceDbError(
                f"Reference DB HTTP {exc.code} for {method} {path}: {detail or exc.reason}"
            ) from exc
        except urllib_error.URLError as exc:
            raise ReferenceDbError(
                f"Reference DB network error for {method} {path}: {exc.reason}"
            ) from exc
        except TimeoutError as exc:
            raise ReferenceDbError(
                f"Reference DB timeout for {method} {path} after {self.timeout_seconds} seconds"
            ) from exc
        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ReferenceDbError(
                f"Reference DB returned invalid JSON for {method} {path}"
            ) from exc

    def health(self):
        return self._request_json("GET", "/health")

    def prepare(self, request_id, nonce, duration_seconds):
        """Prepare a capture transaction using the supplied request identity and configured duration."""
        return self._request_json("POST", "/capture/prepare", {
            "request_id": request_id, "nonce": nonce,
            "verifier_id": VERIFIER_ID, "duration_s": duration_seconds,
        })

    def start(self, request_id, nonce):
        """Start the identified prepared capture transaction."""
        return self._request_json("POST", "/capture/start", {
            "request_id": request_id, "nonce": nonce, "verifier_id": VERIFIER_ID,
        })

    def status(self, request_id):
        return self._request_json("GET", f"/capture/{request_id}/status")

    def manifest(self, request_id):
        return self._request_json("GET", f"/capture/{request_id}/manifest")

    def download_trace(self, request_id, destination):
        """Download the identified capture to the destination file; propagate HTTP failures."""
        request = urllib_request.Request(
            self.base_url + f"/capture/{request_id}/trace",
            headers={"Accept": "audio/wav"}, method="GET",
        )
        try:
            with urllib_request.urlopen(request, timeout=self.timeout_seconds) as response:
                with destination.open("wb") as handle:
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        handle.write(chunk)
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError) as exc:
            raise ReferenceDbError(
                f"Reference DB trace download failed for request {request_id}: {exc}"
            ) from exc


class PicoReferenceClient:
    """Unsigned experimental source; HTTP association is not authentication."""

    def __init__(self, base_url, timeout_seconds):
        self.base_url = base_url.rstrip("/")
        if not self.base_url.startswith(("http://", "https://")):
            raise RuntimeError("REF_PICO_CITYA URL must start with http:// or https://")
        self.timeout_seconds = timeout_seconds

    def _request_json(self, method, path, payload=None, destination=None):
        """Send an HTTP request and decode its JSON response; propagate transport or service errors."""
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib_request.Request(
            self.base_url + path, data=data, headers=headers, method=method
        )
        try:
            with urllib_request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read()
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError) as exc:
            raise RuntimeError(f"REF_PICO_CITYA {method} {path} failed: {exc}") from exc
        try:
            result = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"REF_PICO_CITYA invalid JSON for {method} {path}") from exc
        if not isinstance(result, dict):
            raise RuntimeError(f"REF_PICO_CITYA expected a JSON object for {method} {path}")
        if destination is not None:
            # Retain the exact received metadata bytes, including unknown fields.
            destination.write_bytes(body)
        return result

    def health(self):
        return self._request_json("GET", "/health")

    def prepare(self, request_id, nonce):
        """Prepare a capture transaction using the supplied request identity and configured duration."""
        return self._request_json("POST", "/capture/prepare", {
            "request_id": request_id, "nonce": nonce, "verifier_id": VERIFIER_ID,
            "duration_s": PICO_REF_DURATION_SECONDS,
        })

    def start(self, request_id, nonce):
        """Start the identified prepared capture transaction."""
        return self._request_json("POST", "/capture/start", {
            "request_id": request_id, "nonce": nonce, "verifier_id": VERIFIER_ID,
        })

    def status(self, request_id):
        return self._request_json("GET", f"/capture/{request_id}/status")

    def metadata(self, request_id, destination):
        """Return or download capture metadata for the identified request."""
        return self._request_json(
            "GET", f"/capture/{request_id}/metadata", destination=destination
        )

    def download_trace(self, request_id, destination):
        """Download the identified capture to the destination file; propagate HTTP failures."""
        request = urllib_request.Request(
            self.base_url + f"/capture/{request_id}/trace",
            headers={"Accept": "application/octet-stream"}, method="GET",
        )
        try:
            with urllib_request.urlopen(request, timeout=self.timeout_seconds) as response:
                with destination.open("wb") as handle:
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        handle.write(chunk)
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError) as exc:
            raise RuntimeError(
                f"REF_PICO_CITYA trace download failed for request {request_id}: {exc}"
            ) from exc


def require_pico_fields(payload, expected, context):
    """Reject missing or mismatched Pico fields; equality does not authenticate metadata."""
    for name, value in expected.items():
        received = payload.get(name)
        if isinstance(received, bool) or received != value:
            raise RuntimeError(f"REF_PICO_CITYA {context}: invalid {name}: {received!r}")


def require_pico_positive(payload, name, integer=False):
    """Return a finite positive metadata number, optionally requiring an integer."""
    value = payload.get(name)
    if (type(value) not in (int, float) or
            (integer and type(value) is not int) or
            (type(value) is float and not math.isfinite(value)) or value <= 0):
        raise RuntimeError(f"REF_PICO_CITYA invalid positive {name}: {value!r}")
    return value


def validate_pico_metadata(metadata, request_id, nonce_hex):
    """Consistency only: this metadata and its digest are not authenticated."""
    require_pico_fields(metadata, {
        "service": PICO_REF_SERVICE_ID, "node_id": PICO_REF_NODE_ID,
        "request_id": request_id, "nonce": nonce_hex, "verifier_id": VERIFIER_ID,
        "capture_duration_s": PICO_REF_DURATION_SECONDS,
        "target_sample_rate_hz": PICO_REF_TARGET_SAMPLE_RATE_HZ,
        "trace_format": "raw_int16_le", "sample_format": "int16",
        "byte_order": "little", "bytes_per_sample": 2,
    }, "metadata")
    if metadata.get("authenticated") is not False:
        raise RuntimeError("REF_PICO_CITYA metadata must declare authenticated=false")
    require_pico_positive(metadata, "actual_sample_interval_ns")
    require_pico_positive(metadata, "actual_sample_rate_hz")
    samples = require_pico_positive(metadata, "actual_samples", integer=True)
    size = require_pico_positive(metadata, "trace_size_bytes", integer=True)
    if size != samples * 2:
        raise RuntimeError("REF_PICO_CITYA trace_size_bytes must equal actual_samples * 2")
    digest = metadata.get("trace_sha256")
    if (not isinstance(digest, str) or len(digest) != 64 or
            any(c not in "0123456789abcdefABCDEF" for c in digest)):
        raise RuntimeError("REF_PICO_CITYA trace_sha256 must be exactly 64 hex characters")


def pico_timed_call(timing, timing_path, operation, function, *args):
    """All timestamps here originate on the verifier, never the Pico laptop."""
    prefix = f"pico_ref_{operation}"
    timing[f"{prefix}_send_utc"] = utc_now_iso()
    timing[f"{prefix}_send_perf_ns"] = time.perf_counter_ns()
    try:
        result = function(*args)
        timing[f"{prefix}_recv_perf_ns"] = time.perf_counter_ns()
        timing[f"{prefix}_recv_utc"] = utc_now_iso()
        return result
    finally:
        write_json_atomic(timing_path, timing)


def wait_for_pico_state(client, request_id, desired_state, timeout_seconds, poll_interval):
    """Poll until the requested Pico state or raise on timeout, identity mismatch, or capture error."""
    deadline = time.monotonic() + timeout_seconds
    while True:
        if time.monotonic() >= deadline:
            raise RuntimeError(f"REF_PICO_CITYA timed out waiting for {desired_state}")
        status = client.status(request_id)
        if "request_id" in status:
            require_pico_fields(status, {"request_id": request_id}, "status")
        if status.get("state") == "ERROR":
            raise RuntimeError(f"REF_PICO_CITYA capture failed: {status!r}")
        if status.get("state") == desired_state:
            return time.perf_counter_ns()
        if desired_state == "CAPTURING" and status.get("state") == "COMPLETE":
            raise RuntimeError("REF_PICO_CITYA completed before CAPTURING confirmation")
        time.sleep(poll_interval)


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path):
    """Stream a file into SHA-256 and return its hexadecimal digest."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json_atomic(path, payload):
    """Write JSON through a sibling temporary file before replacing the destination."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def resolve_request_id(args, started_at):
    """Use an explicit request ID or select the first unused request directory number."""
    if args.request_id is not None:
        return args.request_id
    day_dir = args.output_dir
    request_id = 1
    while (day_dir / f"reqid_{request_id}").exists():
        request_id += 1
    return request_id


def build_request_paths(request_id, started_at, args):
    """Return the configured request's evidence, data, and result destinations."""
    day_dir = args.output_dir
    request_dir = day_dir / f"reqid_{request_id}"
    data_dir = request_dir / "data"
    results_dir = request_dir / "results"
    aligned_basename = (
        args.ref_trace_basename.replace("220s", "200s", 1)
        if "220s" in args.ref_trace_basename else f"{args.ref_trace_basename}_200s"
    )
    return {
        "day_dir": day_dir, "request_dir": request_dir,
        "data_dir": data_dir, "results_dir": results_dir,
        "log": request_dir / "enf_verifier.log",
        "arm_enf_csv": data_dir / "fpga_em_trace_200s_arm_enf.csv",
        "zb_evidence": data_dir / "zb_m_zb.bin",
        "zb_signature": data_dir / "zb_signature.bin",
        "zb_metadata": data_dir / "zb_attestation_metadata.json",
        "zb_benchmark": data_dir / "zb_benchmark_timing.json",
        "verifier_result": results_dir / "enf_verifier_result.json",
        "reference_wav": data_dir / f"{args.ref_trace_basename}.wav",
        "reference_manifest": data_dir / f"{args.ref_trace_basename}_manifest.json",
        "pico_ref_trace": data_dir / "pico_ref_trace_220s.bin",
        "pico_ref_metadata": data_dir / "pico_ref_metadata.json",
        "pico_host_timing": data_dir / "pico_ref_host_timing.json",
        "host_timing": data_dir / f"{args.ref_trace_basename}_host_timing.json",
        "aligned_wav": data_dir / f"{aligned_basename}_aligned.wav",
        "reference_enf_csv": data_dir / f"{aligned_basename}_enf.csv",
        "comparison_csv": data_dir / "fpga_vs_mains_enf_comparison.csv",
        "metrics": data_dir / "fpga_vs_mains_enf_metrics.json",
        "comparison_plot": results_dir / "fpga_vs_mains_enf_correlation.png",
        "comparison_svg": results_dir / "fpga_vs_mains_enf_correlation.svg",
        "pico_enf_csv": data_dir / "pico_ref_trace_200s_enf.csv",
        "pico_aligned_bin": data_dir / "pico_ref_trace_200s_aligned.bin",
        "fpga_pico_csv": data_dir / "fpga_vs_pico_enf_comparison.csv",
        "mains_pico_csv": data_dir / "mains_vs_pico_enf_comparison.csv",
        "three_source_metrics": data_dir / "three_source_enf_metrics.json",
        "fpga_pico_png": results_dir / "fpga_vs_pico_enf_correlation.png",
        "fpga_pico_svg": results_dir / "fpga_vs_pico_enf_correlation.svg",
        "mains_pico_png": results_dir / "mains_vs_pico_enf_correlation.png",
        "mains_pico_svg": results_dir / "mains_vs_pico_enf_correlation.svg",
        "three_source_png": results_dir / "three_source_enf_comparison.png",
        "three_source_svg": results_dir / "three_source_enf_comparison.svg",
    }


def decode_fixed_hex(value, field_name, byte_count):
    """Decode a fixed-length hexadecimal field or raise a validation error."""
    if not isinstance(value, str):
        raise RuntimeError(f"{field_name} must be a hexadecimal string")
    try:
        decoded = bytes.fromhex(value)
    except ValueError as exc:
        raise RuntimeError(f"{field_name} is not valid hexadecimal") from exc
    if len(decoded) != byte_count:
        raise RuntimeError(f"{field_name} must decode to exactly {byte_count} bytes")
    return decoded


def require_manifest_uint(manifest, field_name, bits):
    """Return a manifest integer in the specified unsigned bit range; reject booleans."""
    value = manifest.get(field_name)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < (1 << bits):
        raise RuntimeError(f"Manifest {field_name} must be an unsigned uint{bits}")
    return value


def load_reference_public_key():
    """Return the enrolled P-256 mains key and fingerprint after enrollment checks."""
    trust_store = json.loads(TRUST_STORE_PATH.read_text(encoding="utf-8"))
    if trust_store.get("verifier_id") != VERIFIER_ID:
        raise RuntimeError("Trust-store verifier identity mismatch")
    if trust_store.get("protocol") != REFERENCE_CAPTURE_PROTOCOL:
        raise RuntimeError("Trust-store attestation protocol mismatch")
    identity = trust_store.get("trusted_nodes", {}).get(REF_NODE_ID)
    if not isinstance(identity, dict) or identity.get("role") != "reference_attester":
        raise RuntimeError("Reference node is not correctly enrolled")
    if identity.get("algorithm") != ZB_SIGNATURE_ALGORITHM:
        raise RuntimeError("Reference signature algorithm mismatch")
    filename = identity.get("public_key")
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise RuntimeError("Reference public-key filename is invalid")
    enrolled = decode_fixed_hex(identity.get("public_key_sha256"), "reference fingerprint", 32)
    key = serialization.load_pem_public_key((TRUST_STORE_PATH.parent / filename).read_bytes())
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise RuntimeError("Trusted reference key is not EC P-256")
    der = key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    calculated = hashlib.sha256(der).digest()
    if not hmac.compare_digest(calculated, enrolled):
        raise RuntimeError("Reference public-key fingerprint does not match enrollment")
    return key, calculated.hex()


def build_reference_evidence(manifest, nonce_hex):
    """Serialize mains manifest fields into the canonical 149-byte signed message."""
    ref_id = REF_NODE_ID.encode("ascii")
    verifier_id = VERIFIER_ID.encode("ascii")
    container = manifest.get("container_format")
    sample_format = manifest.get("sample_format")
    if container not in (None, 1, "WAV", "wav") or sample_format not in (1, "int16"):
        raise RuntimeError("Unsupported signed reference media format")
    evidence = b"".join((
        REFERENCE_EVIDENCE_DOMAIN, struct.pack(">H", REFERENCE_EVIDENCE_VERSION),
        struct.pack(">B", len(ref_id)), ref_id,
        struct.pack(">B", len(verifier_id)), verifier_id,
        struct.pack(">I", require_manifest_uint(manifest, "request_id", 32)),
        decode_fixed_hex(nonce_hex, "reference nonce", 16),
        struct.pack(">I", require_manifest_uint(manifest, "sample_rate_hz", 32)),
        struct.pack(">B", require_manifest_uint(manifest, "channels", 8)),
        struct.pack(">B", 1), struct.pack(">B", 1),
        struct.pack(">I", require_manifest_uint(manifest, "requested_duration_ms", 32)),
        struct.pack(">I", require_manifest_uint(manifest, "expected_samples", 32)),
        struct.pack(">I", require_manifest_uint(manifest, "actual_samples", 32)),
        struct.pack(">Q", require_manifest_uint(manifest, "wav_size_bytes", 64)),
        decode_fixed_hex(manifest.get("wav_sha256"), "wav_sha256", 32),
        struct.pack(">Q", require_manifest_uint(manifest, "start_command_unix_ns", 64)),
        struct.pack(">Q", require_manifest_uint(manifest, "capture_call_unix_ns", 64)),
        struct.pack(">Q", require_manifest_uint(manifest, "capture_complete_unix_ns", 64)),
    ))
    if len(evidence) != REFERENCE_EVIDENCE_SIZE:
        raise RuntimeError(f"Canonical reference evidence must be {REFERENCE_EVIDENCE_SIZE} bytes")
    return evidence


def authenticate_reference_manifest(manifest, request_id, nonce_hex, sample_rate, channels):
    """Verify signed mains fields, transaction binding, and timestamp ordering; return security metadata."""
    if manifest.get("protocol") != REFERENCE_CAPTURE_PROTOCOL:
        raise RuntimeError("Reference manifest protocol mismatch")
    if manifest.get("reference_evidence_version") != REFERENCE_EVIDENCE_VERSION:
        raise RuntimeError("Reference evidence version mismatch")
    if manifest.get("reference_node_id") != REF_NODE_ID:
        raise RuntimeError("Reference identity binding failed")
    if manifest.get("verifier_id") != VERIFIER_ID:
        raise RuntimeError("Reference verifier binding failed")
    if manifest.get("request_id") != request_id:
        raise RuntimeError("Reference request binding failed")
    if manifest.get("nonce") != nonce_hex:
        raise RuntimeError("Reference nonce binding failed")
    if manifest.get("signature_algorithm") != ZB_SIGNATURE_ALGORITHM:
        raise RuntimeError("Reference signature algorithm mismatch")
    if manifest.get("signature_format") != REF_SIGNATURE_FORMAT:
        raise RuntimeError("Reference signature format mismatch")
    if manifest.get("sample_rate_hz") != sample_rate or manifest.get("channels") != channels:
        raise RuntimeError("Reference media format differs from PREPARE response")
    if require_manifest_uint(manifest, "actual_samples", 32) <= 0:
        raise RuntimeError("Reference actual_samples must be positive")
    if require_manifest_uint(manifest, "wav_size_bytes", 64) <= 0:
        raise RuntimeError("Reference WAV size must be positive")
    evidence = build_reference_evidence(manifest, nonce_hex)
    digest = hashlib.sha256(evidence).digest()
    if not hmac.compare_digest(
        digest, decode_fixed_hex(manifest.get("signed_evidence_sha256"), "signed evidence digest", 32)
    ):
        raise RuntimeError("Reference signed-evidence SHA-256 mismatch")
    signature = decode_fixed_hex(manifest.get("signature_hex"), "reference signature", 64)
    key, fingerprint = load_reference_public_key()
    try:
        key.verify(
            encode_dss_signature(int.from_bytes(signature[:32], "big"),
                                 int.from_bytes(signature[32:], "big")),
            digest, ec.ECDSA(Prehashed(hashes.SHA256())),
        )
    except InvalidSignature as exc:
        raise RuntimeError("REF_CITYA ECDSA verification failed") from exc
    start = require_manifest_uint(manifest, "start_command_unix_ns", 64)
    call = require_manifest_uint(manifest, "capture_call_unix_ns", 64)
    complete = require_manifest_uint(manifest, "capture_complete_unix_ns", 64)
    if not start <= call < complete:
        raise RuntimeError("Reference signed timestamps fail ordering sanity")
    return {"request_id": request_id, "nonce": decode_fixed_hex(nonce_hex, "nonce", 16),
            "verifier_id": VERIFIER_ID, "public_key_sha256": fingerprint,
            "canonical_evidence_bytes": len(evidence)}


def write_arm_enf_csv(path, values):
    """Write 25 nanohertz board estimates as Hz at eight-second frame offsets."""
    if len(values) != 25:
        raise RuntimeError(
            f"ARM ENF result count mismatch: received {len(values)}, expected 25."
        )
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("frame_index", "time_seconds", "enf_hz"))
        for index, value in enumerate(values):
            writer.writerow(
                (index, index * 8, f"{value / 1_000_000_000.0:.17g}")
            )


def run_reference_processing(args, paths):
    """Invoke the saved-data processor for downloaded references and signed board ENF."""
    command = [
        sys.executable, str(REFERENCE_PROCESSOR_PATH),
        "--reference-wav", str(paths["reference_wav"]),
        "--reference-manifest", str(paths["reference_manifest"]),
        "--host-timing", str(paths["host_timing"]),
        "--arm-enf-csv", str(paths["arm_enf_csv"]),
        "--pico-bin", str(paths["pico_ref_trace"]),
        "--pico-metadata", str(paths["pico_ref_metadata"]),
        "--pico-host-timing", str(paths["pico_host_timing"]),
        "--data-dir", str(paths["data_dir"]),
        "--results-dir", str(paths["results_dir"]),
        "--ref-pre-roll", str(args.ref_pre_roll),
        "--ref-trace-basename", args.ref_trace_basename,
    ]
    completed = subprocess.run(command, cwd=Path(__file__).resolve().parent,
                               shell=False, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"Reference ENF processing failed with exit code {completed.returncode}")
    required = (
        "aligned_wav", "arm_enf_csv", "reference_enf_csv", "pico_enf_csv",
        "pico_aligned_bin", "comparison_csv", "fpga_pico_csv", "mains_pico_csv",
        "metrics", "three_source_metrics", "comparison_plot", "comparison_svg",
        "fpga_pico_png", "fpga_pico_svg", "mains_pico_png", "mains_pico_svg",
        "three_source_png", "three_source_svg",
    )
    for key in required:
        path = paths[key]
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Required three-source result is missing or empty: {path}")
    metrics = json.loads(paths["three_source_metrics"].read_text(encoding="utf-8"))
    if metrics.get("frame_count") != 25 or metrics.get("request_id") != ACTIVE_REQUEST_ID:
        raise RuntimeError("Three-source metrics frame count or request ID mismatch")
    expected_pairs = {
        "zedboard_vs_ref_citya": ("ZB_CITYA", "REF_CITYA"),
        "zedboard_vs_ref_pico_citya": ("ZB_CITYA", "REF_PICO_CITYA"),
        "ref_citya_vs_ref_pico_citya": ("REF_CITYA", "REF_PICO_CITYA"),
    }
    for name, (a, b) in expected_pairs.items():
        pair = metrics.get("pairwise", {}).get(name, {})
        if (pair.get("sequence_a") != a or pair.get("sequence_b") != b
                or pair.get("frame_count") != 25):
            raise RuntimeError(f"Invalid pair ordering or frame count: {name}")
        for field in ("pearson_r", "rmse_hz", "mae_hz",
                      "max_abs_error_hz", "mean_signed_difference_hz"):
            value = pair.get(field)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise RuntimeError(f"Invalid three-source metric: {name}.{field}")
    return metrics


def run_ping_only():
    """Check UART service responsiveness without requesting ENF capture."""
    log_print("============================================================")
    log_print(" Persistent ZedBoard Service: PING/PONG")
    log_print("============================================================")
    with serial.Serial(PORT, BAUD, bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                       stopbits=serial.STOPBITS_ONE, timeout=1.0) as ser:
        reset_ascii_rx_buffer()
        synchronize_persistent_service(ser)
    log_print("[BOARD SERVICE] Persistent ZedBoard service: PASS")
    return 0


# STEP_5: Reference acquisition and evidence orchestration
def run_attestation(args):
    """Acquire a live transaction, verify evidence, and run three-source numerical comparison."""
    global ACTIVE_LOG_FILE, ACTIVE_REQUEST_PATHS, ACTIVE_REQUEST_ID, ACTIVE_PROCESSING_STARTED
    ACTIVE_PROCESSING_STARTED = False
    started_at = datetime.now()
    request_id = resolve_request_id(args, started_at)
    nonce = secrets.token_bytes(16)
    nonce_hex = nonce.hex()
    paths = build_request_paths(request_id, started_at, args)
    if paths["request_dir"].exists():
        raise RuntimeError(f"Refusing to overwrite request directory: {paths['request_dir']}")
    paths["data_dir"].mkdir(parents=True)
    paths["results_dir"].mkdir()
    ACTIVE_REQUEST_PATHS = paths
    ACTIVE_REQUEST_ID = request_id
    ACTIVE_LOG_FILE = paths["log"].open("w", encoding="utf-8", newline="\n")
    evidence = None
    signature = None
    benchmark_timing = None
    benchmark_seen = False
    done_received = False
    idle_received = False
    reference_client = None
    pico_client = None
    pico_timing = None
    reference_sample_rate = 44100
    reference_channels = 1
    reference_security = None
    host_timing = {
        "protocol": REFERENCE_CAPTURE_PROTOCOL,
        "request_id": request_id,
        "nonce": nonce_hex,
        "refdb_url": args.refdb_url,
        "ref_pre_roll_s": args.ref_pre_roll,
        "ref_duration_s": args.ref_duration,
        "host_ref_health_send_utc": None,
        "host_ref_health_recv_utc": None,
        "health_rtt_ms": None,
        "host_ref_prepare_send_utc": None,
        "host_ref_prepare_recv_utc": None,
        "host_ref_start_send_utc": None,
        "host_ref_start_recv_utc": None,
        "host_ref_capturing_confirmed_utc": None,
        "fpga_get_send_utc": None,
        "fpga_get_send_perf_ns": None,
        "fpga_done_recv_perf_ns": None,
        "board_attestation_elapsed_s": None,
        "host_ref_complete_seen_utc": None,
        "download_completed_utc": None,
        "manifest_sha256": None,
        "downloaded_sha256": None,
        "sha256_match": None,
    }

    log_print(f"[BOARD ATTESTATION] Request ID: {request_id}")
    with serial.Serial(PORT, BAUD, bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                       stopbits=serial.STOPBITS_ONE, timeout=1.0) as ser:
        reset_ascii_rx_buffer()
        synchronize_persistent_service(ser)
        if not args.fpga_only:
            reference_client = ReferenceDbClient(args.refdb_url, args.ref_http_timeout)
            log_print("[REFERENCE-NODE CAPTURE] Checking reference-node health")
            host_timing["host_ref_health_send_utc"] = utc_now_iso()
            health_start = time.perf_counter_ns()
            health = reference_client.health()
            host_timing["host_ref_health_recv_utc"] = utc_now_iso()
            host_timing["health_rtt_ms"] = (
                time.perf_counter_ns() - health_start
            ) / 1_000_000.0
            if not isinstance(health, dict) or health.get("service") != REFERENCE_SERVICE_ID:
                raise RuntimeError(f"Unexpected REF_CITYA Reference DB service: {health!r}")
            if health.get("state") == "ERROR" or health.get("status", "OK") != "OK":
                raise RuntimeError(f"REF_CITYA health failed: {health!r}")
            log_print("[REFERENCE-NODE CAPTURE] Health check: PASS")
            pico_client = PicoReferenceClient(args.pico_ref_url, args.ref_http_timeout)
            pico_timing = {
                "service": PICO_REF_SERVICE_ID, "node_id": PICO_REF_NODE_ID,
                "authenticated": False, "request_id": request_id, "nonce": nonce_hex,
                "verifier_id": VERIFIER_ID, "pico_ref_url": args.pico_ref_url,
                "ref_pre_roll_s": args.ref_pre_roll,
                "capture_duration_s": PICO_REF_DURATION_SECONDS,
                "timing_authority": "verifier_perf_counter",
                "sha256_match": None,
            }
            log_print("[PICO REFERENCE CAPTURE] Checking Pico reference health")
            pico_health = pico_timed_call(
                pico_timing, paths["pico_host_timing"], "health", pico_client.health
            )
            require_pico_fields(pico_health, {
                "service": PICO_REF_SERVICE_ID, "node_id": PICO_REF_NODE_ID,
                "capture_duration_s": PICO_REF_DURATION_SECONDS,
                "target_sample_rate_hz": PICO_REF_TARGET_SAMPLE_RATE_HZ,
            }, "health")
            if pico_health.get("state") == "ERROR" or pico_health.get("status", "OK") != "OK":
                raise RuntimeError(f"REF_PICO_CITYA health failed: {pico_health!r}")
            log_print("[PICO REFERENCE CAPTURE] Health check: PASS")
            host_timing["host_ref_prepare_send_utc"] = utc_now_iso()
            host_timing["e2e_start_perf_ns"] = time.perf_counter_ns()
            prepared = reference_client.prepare(request_id, nonce_hex, args.ref_duration)
            host_timing["host_ref_prepare_recv_utc"] = utc_now_iso()
            if prepared.get("request_id") != request_id or prepared.get("state") != "READY":
                raise RuntimeError(f"Reference PREPARE did not return READY: {prepared!r}")
            log_print("[REFERENCE-NODE CAPTURE] Capture preparation: READY")
            reference_sample_rate = int(prepared.get("sample_rate", 44100))
            reference_channels = int(prepared.get("channels", 1))
            pico_prepared = pico_timed_call(
                pico_timing, paths["pico_host_timing"], "prepare",
                pico_client.prepare, request_id, nonce_hex
            )
            require_pico_fields(pico_prepared, {
                "request_id": request_id, "state": "READY", "node_id": PICO_REF_NODE_ID,
            }, "PREPARE")
            for name in ("actual_sample_interval_ns", "actual_sample_rate_hz"):
                pico_timing[name] = require_pico_positive(pico_prepared, name)
            write_json_atomic(paths["pico_host_timing"], pico_timing)
            log_print("[PICO REFERENCE CAPTURE] Capture preparation: READY")
            host_timing["host_ref_start_send_utc"] = utc_now_iso()
            host_timing["ref_citya_start_send_perf_ns"] = time.perf_counter_ns()
            started = reference_client.start(request_id, nonce_hex)
            host_timing["ref_citya_start_recv_perf_ns"] = time.perf_counter_ns()
            host_timing["host_ref_start_recv_utc"] = utc_now_iso()
            if started.get("request_id") != request_id:
                raise RuntimeError("Reference START request-ID mismatch")
            if started.get("state") == "ERROR":
                raise RuntimeError(f"REF_CITYA START failed: {started!r}")
            log_print("[REFERENCE-NODE CAPTURE] Capture started")
            pico_started = pico_timed_call(
                pico_timing, paths["pico_host_timing"], "start",
                pico_client.start, request_id, nonce_hex
            )
            require_pico_fields(pico_started, {"request_id": request_id}, "START")
            if pico_started.get("state") == "ERROR":
                raise RuntimeError(f"REF_PICO_CITYA START failed: {pico_started!r}")
            log_print("[PICO REFERENCE CAPTURE] Capture started")
            capture_deadline = time.monotonic() + max(30.0, args.ref_http_timeout * 4.0)
            while True:
                if time.monotonic() >= capture_deadline:
                    raise RuntimeError("Timed out waiting for Reference DB CAPTURING")
                status = reference_client.status(request_id)
                if status.get("state") == "CAPTURING":
                    host_timing["ref_citya_capturing_confirmed_perf_ns"] = time.perf_counter_ns()
                    host_timing["host_ref_capturing_confirmed_utc"] = utc_now_iso()
                    log_print("[REFERENCE-NODE CAPTURE] Capture state: CAPTURING")
                    break
                if status.get("state") == "ERROR":
                    raise RuntimeError(f"Reference DB capture failed: {status!r}")
                time.sleep(args.ref_poll_interval)
            pico_timing["pico_ref_capturing_confirmed_perf_ns"] = wait_for_pico_state(
                pico_client, request_id, "CAPTURING",
                max(30.0, args.ref_http_timeout * 4.0), args.ref_poll_interval
            )
            pico_timing["pico_ref_capturing_confirmed_utc"] = utc_now_iso()
            log_print("[PICO REFERENCE CAPTURE] Capture state: CAPTURING")
            both_refs_capturing_perf_ns = time.perf_counter_ns()
            host_timing["both_refs_capturing_perf_ns"] = both_refs_capturing_perf_ns
            pico_timing["both_refs_capturing_perf_ns"] = both_refs_capturing_perf_ns
            time.sleep(args.ref_pre_roll)
            write_json_atomic(paths["host_timing"], host_timing)
            write_json_atomic(paths["pico_host_timing"], pico_timing)

        perform_attest_handshake(ser, request_id, nonce_hex)
        host_timing["fpga_get_send_utc"] = utc_now_iso()
        host_timing["fpga_get_send_perf_ns"] = time.perf_counter_ns()
        send_command(ser, f"GET {request_id} ENF")
        wait_for_started(ser, request_id)
        if not args.fpga_only:
            host_timing["ref_citya_observed_pre_roll_s"] = (
                host_timing["fpga_get_send_perf_ns"]
                - host_timing["ref_citya_capturing_confirmed_perf_ns"]
            ) / 1e9
            pico_timing["fpga_get_send_perf_ns"] = host_timing["fpga_get_send_perf_ns"]
            pico_timing["pico_ref_observed_pre_roll_s"] = (
                pico_timing["fpga_get_send_perf_ns"]
                - pico_timing["pico_ref_capturing_confirmed_perf_ns"]
            ) / 1e9
            write_json_atomic(paths["host_timing"], host_timing)
            write_json_atomic(paths["pico_host_timing"], pico_timing)
        deadline = time.monotonic() + args.board_evidence_timeout_s
        while not done_received:
            line = read_nonempty_line(ser, deadline, "Timed out waiting for authenticated ZB evidence and DONE.")
            line_recv_perf_ns = time.perf_counter_ns()
            check_error_line(line)
            if line.startswith("ZB_ENF_EVIDENCE "):
                log_board_line(line)
                if evidence is not None:
                    raise RuntimeError("Duplicate ZB ENF evidence record.")
                evidence = parse_zb_transport_record(line, line.split(" ", 1)[0], request_id, BOARD_EVIDENCE_SIZE)
            elif line.startswith("ZB_SIGNATURE "):
                log_board_line(line)
                if evidence is None:
                    raise RuntimeError("ZB_SIGNATURE arrived before ZB_EVIDENCE.")
                if signature is not None:
                    raise RuntimeError("Duplicate ZB_SIGNATURE record.")
                signature = parse_zb_transport_record(line, "ZB_SIGNATURE", request_id, ZB_SIGNATURE_SIZE)
            elif line.split()[:1] == ["ZB_BENCHMARK"]:
                # Diagnostic failures must never reject otherwise valid evidence.
                if benchmark_seen:
                    log_print("[BOARD ATTESTATION] Ignoring duplicate ZB_BENCHMARK diagnostic")
                else:
                    benchmark_seen = True
                    try:
                        benchmark_timing = parse_zb_benchmark_record(line, request_id)
                    except ValueError as exc:
                        log_print(f"[BOARD ATTESTATION] Ignoring invalid ZB_BENCHMARK diagnostic: {exc}")
            elif line.startswith("DONE "):
                log_board_line(line)
                if evidence is None or signature is None:
                    raise RuntimeError("DONE arrived before authenticated ZB evidence records.")
                parts = line.split()
                if parts != ["DONE", str(request_id), "ENF"]:
                    raise RuntimeError(f"Malformed or mismatched DONE line: {line!r}")
                host_timing["fpga_done_recv_perf_ns"] = line_recv_perf_ns
                host_timing["board_attestation_elapsed_s"] = (
                    line_recv_perf_ns - host_timing["fpga_get_send_perf_ns"]
                ) / 1e9
                done_received = True
            elif line == "IDLE":
                log_board_line(line)
                raise RuntimeError("IDLE arrived before DONE validation completed.")
            else:
                log_board_line(line)

        while not idle_received:
            line = read_nonempty_line(ser, deadline, "Timed out waiting for IDLE before the board evidence deadline.")
            check_error_line(line)
            log_board_line(line)
            if line == "IDLE":
                idle_received = True
            elif line.split()[:1] == ["ZB_BENCHMARK"]:
                log_print("[BOARD ATTESTATION] Ignoring ZB_BENCHMARK diagnostic after DONE")
            elif line.startswith(("ZB_ENF_EVIDENCE ", "ZB_SIGNATURE ", "DONE ")):
                raise RuntimeError(f"Unexpected protocol record while waiting for IDLE: {line!r}")

    # Board evidence is authenticated before it is compared with reference data.
    try:
        parsed, evidence_sha256 = authenticate_zb_evidence(evidence, signature, request_id, nonce)
    except Exception as exc:
        raise RuntimeError(f"ZB_CITYA evidence authentication failed: {exc}") from exc
    paths["zb_evidence"].write_bytes(evidence)
    paths["zb_signature"].write_bytes(signature)
    write_arm_enf_csv(paths["arm_enf_csv"], parsed["enf_values_nhz"])
    write_json_atomic(paths["zb_metadata"], {
        "protocol": BOARD_ATTESTATION_PROTOCOL,
        "device_id": parsed["device_id"],
        "verifier_id": parsed["verifier_id"],
        "request_id": parsed["request_id"],
        "nonce": parsed["nonce"].hex(),
        "board_evidence_version": BOARD_EVIDENCE_VERSION,
        "evidence_type": "ENF_ONLY",
        "evidence_sha256": evidence_sha256,
        "public_key_sha256": ZB_EXPECTED_PUBLIC_KEY_SHA256,
        "signature_bytes": len(signature),
        **({"benchmark_timing": benchmark_timing} if benchmark_timing is not None else {}),
    })
    log_print("[BOARD EVIDENCE VERIFICATION] Canonical evidence and ECDSA verification: PASS")
    log_print(f"Evidence bytes          : {len(evidence)}")
    log_print(f"Signature bytes         : {len(signature)}")
    log_print(f"Evidence SHA-256        : {evidence_sha256}")
    log_print(f"Signed ENF frames       : {parsed['frame_count']}")
    log_print(f"Board samples captured : {TOTAL_SAMPLES}")
    if benchmark_timing is not None:
        write_json_atomic(paths["zb_benchmark"], benchmark_timing)
        log_print("[BOARD ATTESTATION] Diagnostic timing (unsigned)")
        log_print("ENF processing per 8-s frame:")
        log_print(f"  mean : {1000 * benchmark_timing['frame_mean_seconds']:.3f} ms")
        log_print(f"  min  : {1000 * benchmark_timing['frame_min_seconds']:.3f} ms")
        log_print(f"  max  : {1000 * benchmark_timing['frame_max_seconds']:.3f} ms")
        log_print(f"SHA-256 + ECDSA P-256: {benchmark_timing['sha256_ecdsa_ms']:.3f} ms")
    write_json_atomic(paths["host_timing"], host_timing)
    if args.fpga_only:
        write_json_atomic(paths["verifier_result"], {
            "authenticated_enf_evidence": "PASS",
            "request_id": request_id,
            "reference_capture": "SKIPPED",
            "reference_enf_extraction": "SKIPPED",
            "fpga_reference_comparison": "SKIPPED",
            "board_attestation_elapsed_s": host_timing["board_attestation_elapsed_s"],
        })
        log_print(f"Evidence directory       : {paths['request_dir']}")
        log_print("[ATTESTATION DECISION] FPGA-only ENF attestation: PASS")
        return 0

    completion_deadline = time.monotonic() + max(
        REF_COMPLETE_TIMEOUT_MARGIN_SECONDS,
        args.ref_duration + REF_COMPLETE_TIMEOUT_MARGIN_SECONDS,
    )
    while True:
        if time.monotonic() >= completion_deadline:
            raise RuntimeError("Timed out waiting for Reference DB COMPLETE")
        status = reference_client.status(request_id)
        if status.get("state") == "COMPLETE":
            host_timing["host_ref_complete_seen_utc"] = utc_now_iso()
            break
        if status.get("state") == "ERROR":
            raise RuntimeError(f"Reference DB capture failed: {status!r}")
        time.sleep(args.ref_poll_interval)

    manifest = reference_client.manifest(request_id)
    log_print("[REFERENCE-NODE CAPTURE] Signed manifest retrieved")
    try:
        reference_security = authenticate_reference_manifest(
            manifest, request_id, nonce_hex, reference_sample_rate, reference_channels
        )
    except Exception as exc:
        raise RuntimeError(f"REF_CITYA manifest authentication failed: {exc}") from exc
    if parsed["request_id"] != reference_security["request_id"]:
        raise RuntimeError("ZB/REF request cross-binding failed")
    if not hmac.compare_digest(parsed["nonce"], reference_security["nonce"]):
        raise RuntimeError("ZB/REF nonce cross-binding failed")
    if parsed["verifier_id"] != reference_security["verifier_id"]:
        raise RuntimeError("ZB/REF verifier cross-binding failed")
    log_print("[REFERENCE EVIDENCE VERIFICATION] Manifest signature and transaction bindings: PASS")

    write_json_atomic(paths["reference_manifest"], manifest)
    host_timing["manifest_sha256"] = sha256_file(paths["reference_manifest"])
    host_timing["manifest_capture_timestamps"] = {
        "start_command_received_utc": manifest.get("start_command_received_utc"),
        "capture_call_before_utc": manifest.get("capture_call_before_utc"),
        "capture_call_after_utc": manifest.get("capture_call_after_utc"),
        "capture_call_before_perf_ns": manifest.get("capture_call_before_perf_ns"),
        "capture_call_after_perf_ns": manifest.get("capture_call_after_perf_ns"),
        "capture_completed_utc": manifest.get("capture_completed_utc"),
        "wav_save_started_utc": manifest.get("wav_save_started_utc"),
        "wav_save_completed_utc": manifest.get("wav_save_completed_utc"),
    }
    reference_client.download_trace(request_id, paths["reference_wav"])
    log_print("[REFERENCE-NODE CAPTURE] Reference trace retrieved")
    host_timing["download_completed_utc"] = utc_now_iso()
    downloaded_sha256 = sha256_file(paths["reference_wav"])
    signed_sha256 = manifest.get("wav_sha256")
    decode_fixed_hex(signed_sha256, "wav_sha256", 32)
    if not hmac.compare_digest(downloaded_sha256, signed_sha256.lower()):
        raise RuntimeError("Downloaded Reference WAV SHA-256 mismatch")
    if paths["reference_wav"].stat().st_size != require_manifest_uint(
        manifest, "wav_size_bytes", 64
    ):
        raise RuntimeError("Downloaded Reference WAV size mismatch")
    host_timing["downloaded_sha256"] = downloaded_sha256
    host_timing["sha256_match"] = True
    log_print("[REFERENCE EVIDENCE VERIFICATION] Trace digest and size: PASS")
    write_json_atomic(paths["host_timing"], host_timing)

    pico_timing["pico_ref_complete_seen_perf_ns"] = wait_for_pico_state(
        pico_client, request_id, "COMPLETE",
        PICO_REF_DURATION_SECONDS + PICO_COMPLETE_TIMEOUT_MARGIN_SECONDS,
        args.ref_poll_interval
    )
    pico_timing["pico_ref_complete_seen_utc"] = utc_now_iso()
    write_json_atomic(paths["pico_host_timing"], pico_timing)
    pico_metadata = pico_timed_call(
        pico_timing, paths["pico_host_timing"], "metadata",
        pico_client.metadata, request_id, paths["pico_ref_metadata"]
    )
    validate_pico_metadata(pico_metadata, request_id, nonce_hex)
    pico_timing["metadata_sha256"] = sha256_file(paths["pico_ref_metadata"])
    pico_timing["metadata_actual_sample_interval_ns"] = pico_metadata["actual_sample_interval_ns"]
    pico_timing["metadata_actual_sample_rate_hz"] = pico_metadata["actual_sample_rate_hz"]
    write_json_atomic(paths["pico_host_timing"], pico_timing)
    log_print("[PICO REFERENCE VERIFICATION] Unsigned metadata consistency: PASS")
    pico_timed_call(
        pico_timing, paths["pico_host_timing"], "download",
        pico_client.download_trace, request_id, paths["pico_ref_trace"]
    )
    if paths["pico_ref_trace"].stat().st_size != pico_metadata["trace_size_bytes"]:
        raise RuntimeError("REF_PICO_CITYA binary trace size mismatch")
    pico_sha256 = sha256_file(paths["pico_ref_trace"])
    pico_timing["downloaded_sha256"] = pico_sha256
    pico_timing["sha256_match"] = hmac.compare_digest(
        pico_sha256, pico_metadata["trace_sha256"].lower()
    )
    write_json_atomic(paths["pico_host_timing"], pico_timing)
    if not pico_timing["sha256_match"]:
        raise RuntimeError("REF_PICO_CITYA binary trace SHA-256 mismatch")
    log_print("[PICO REFERENCE VERIFICATION] Trace digest and size: PASS")

    host_timing["acquisition_end_perf_ns"] = time.perf_counter_ns()
    host_timing["multi_source_acquisition_elapsed_s"] = (
        host_timing["acquisition_end_perf_ns"] - host_timing["e2e_start_perf_ns"]
    ) / 1e9
    write_json_atomic(paths["host_timing"], host_timing)
    log_print("[MULTI-SOURCE ACQUISITION] ZedBoard + REF_CITYA + REF_PICO_CITYA: PASS")
    ACTIVE_PROCESSING_STARTED = True
    metrics = run_reference_processing(args, paths)
    log_print("[MULTI-SOURCE ENF PROCESSING] ENF extraction: PASS")
    log_print("============================================================")
    log_print("[Pairwise ENF Comparison]")
    log_print("============================================================")
    for name, label in (
        ("zedboard_vs_ref_citya", "ZedBoard vs REF_CITYA"),
        ("zedboard_vs_ref_pico_citya", "ZedBoard vs REF_PICO_CITYA"),
        ("ref_citya_vs_ref_pico_citya", "REF_CITYA vs REF_PICO_CITYA"),
    ):
        pair = metrics["pairwise"][name]
        log_print(label)
        log_print(f"  Pearson correlation    : {pair['pearson_r']:.17g}")
        log_print(f"  RMSE                   : {pair['rmse_hz']:.17g} Hz")
        log_print(f"  Mean absolute error    : {pair['mae_hz']:.17g} Hz")
        log_print(f"  Maximum absolute error : {pair['max_abs_error_hz']:.17g} Hz")
        log_print(f"  Mean signed difference : {pair['mean_signed_difference_hz']:.17g} Hz")
    result = {
        "request_id": request_id,
        "multi_source_acquisition": "PASS",
        "zedboard_authenticated_enf_evidence": "PASS",
        "ref_citya_capture": "PASS",
        "ref_citya_authentication": "PASS",
        "ref_citya_trace_integrity": "PASS",
        "pico_ref_capture": "PASS",
        "pico_ref_authenticated": False,
        "pico_ref_metadata_validation": "PASS",
        "pico_ref_trace_integrity": "PASS",
        "three_source_enf_processing": "PASS",
        "pairwise_comparison": "PASS",
        "pairwise": metrics["pairwise"],
        "outputs": metrics["outputs"],
        "board_attestation_elapsed_s": host_timing["board_attestation_elapsed_s"],
        "multi_source_acquisition_elapsed_s": host_timing["multi_source_acquisition_elapsed_s"],
    }
    # Stop after successful processing, artifact checks, and final result construction.
    host_timing["e2e_end_perf_ns"] = time.perf_counter_ns()
    host_timing["end_to_end_location_verification_s"] = (
        host_timing["e2e_end_perf_ns"] - host_timing["e2e_start_perf_ns"]
    ) / 1e9
    result["end_to_end_location_verification_s"] = host_timing["end_to_end_location_verification_s"]
    write_json_atomic(paths["host_timing"], host_timing)
    write_json_atomic(paths["verifier_result"], result)
    log_print(f"Evidence directory       : {paths['request_dir']}")
    log_print("[MULTI-SOURCE ENF PROCESSING] Acquisition and numerical comparison workflow: PASS")
    log_print("[ATTESTATION DECISION] End-to-end verification time : "
              f"{host_timing['end_to_end_location_verification_s']:.3f} s")
    return 0


# STEP_6: Entrypoint, output and error handling
def main():
    """Run the selected live verifier mode and report acquisition or verification failures."""
    global ACTIVE_LOG_FILE
    args = parse_args()
    try:
        if args.ping_only:
            return run_ping_only()
        return run_attestation(args)
    except KeyboardInterrupt:
        log_print("[ATTESTATION DECISION] FAIL: interrupted")
        return 1
    except Exception as exc:
        log_print(f"[ATTESTATION DECISION] FAIL: {exc}")
        if ACTIVE_REQUEST_PATHS is not None:
            try:
                write_json_atomic(ACTIVE_REQUEST_PATHS["verifier_result"], {
                    **({"authenticated_enf_evidence": "FAIL"} if args.fpga_only else {
                        "multi_source_acquisition": "PASS" if ACTIVE_PROCESSING_STARTED else "FAIL",
                        "pico_ref_authenticated": False,
                        "three_source_enf_processing": "FAIL" if ACTIVE_PROCESSING_STARTED else "NOT_RUN",
                        "pairwise_comparison": "NOT_COMPLETED" if ACTIVE_PROCESSING_STARTED else "NOT_RUN",
                    }),
                    "request_id": ACTIVE_REQUEST_ID,
                    "error": str(exc),
                })
            except Exception:
                pass
        return 1
    finally:
        if ACTIVE_LOG_FILE is not None:
            ACTIVE_LOG_FILE.close()
            ACTIVE_LOG_FILE = None


if __name__ == "__main__":
    raise SystemExit(main())
