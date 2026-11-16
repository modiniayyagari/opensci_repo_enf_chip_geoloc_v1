"""Serve live audio mains captures and signed reference manifests over HTTP.

Requests bind a nonce and request ID to a WAV capture and canonical ECDSA-P256
evidence. Requires an audio input, sounddevice, and an externally provisioned
private key matching the enrolled fingerprint; writes WAV and JSON artifacts.
Signed host timestamps do not establish physical synchronization with the board.
"""

# STEP_1: Dependencies and configuration
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import threading
import time
import wave
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import numpy as np
import sounddevice as sd
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    Prehashed,
    decode_dss_signature,
    encode_dss_signature,
)


REFERENCE_SERVICE_ID = "ENF_REFERENCE_SERVICE"
SERVICE_VERSION = "2.0"
REFERENCE_CAPTURE_PROTOCOL = "ENF_REFERENCE_CAPTURE"
EXPECTED_PUBLIC_KEY_SHA256 = (
    "ac7fc19851a55f58915eb7b71a250d17d807f340ec7f4f95c3714a932f72cfc5"
)
EXPECTED_VERIFIER_ID = "VERIF_CITYA"
SIGNATURE_ALGORITHM = "ECDSA_P256_SHA256"
SIGNATURE_FORMAT = "RAW_R_S_64"
REFERENCE_EVIDENCE_DOMAIN = b"ENF_REFERENCE_EVIDENCE"
REFERENCE_EVIDENCE_VERSION = 1
REFERENCE_EVIDENCE_SIZE = 149
CONTAINER_FORMAT_WAV_PCM = 1
SAMPLE_FORMAT_SIGNED_INT16_LE = 1
SIGNED_EVIDENCE_FIELDS = (
    "reference_evidence_version",
    "reference_node_id",
    "verifier_id",
    "request_id",
    "nonce",
    "sample_rate_hz",
    "channels",
    "container_format",
    "sample_format",
    "requested_duration_ms",
    "expected_samples",
    "actual_samples",
    "wav_size_bytes",
    "wav_sha256",
    "start_command_unix_ns",
    "capture_call_unix_ns",
    "capture_complete_unix_ns",
)
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
DEFAULT_SAMPLE_RATE = 44100
DEFAULT_CHANNELS = 1
DEFAULT_DTYPE = "int16"
DEFAULT_REFERENCE_NODE_ID = "REF_CITYA"
DEFAULT_STREAM_CHUNK_BYTES = 64 * 1024
DEFAULT_PRIVATE_KEY_PATH = (
    Path(__file__).resolve().parent / "keys" / "private" / "ref_citya_private.pem"
)

VALID_STATES = ("IDLE", "READY", "STARTING", "CAPTURING", "COMPLETE", "ERROR")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().isoformat()


def utc_filename_stamp() -> str:
    return utc_now().strftime("%Y%m%dT%H%M%SZ")


def print_service_header(config: "AgentConfig") -> None:
    """Print configured audio capture and HTTP service settings."""
    print("============================================================")
    print(" Reference ENF RefDB Server")
    print("============================================================")
    print(f"Service        : {REFERENCE_SERVICE_ID}")
    print(f"Protocol       : {REFERENCE_CAPTURE_PROTOCOL}")
    print(f"Listen address : {config.host}:{config.port}")
    print(f"Sample rate    : {config.sample_rate} Hz")
    print(f"Channels       : {config.channels}")
    print(f"Format         : {config.dtype}")
    print("State          : IDLE")
    print("")


def safe_atomic_json_write(path: Path, payload: dict[str, Any]) -> None:
    """Flush JSON to a sibling temporary file and atomically replace the destination."""
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temp_path.replace(path)


def sha256_file(path: Path) -> str:
    """Stream a file into SHA-256 and return its hexadecimal digest."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(DEFAULT_STREAM_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def list_input_devices() -> None:
    print(sd.query_devices())


# STEP_2: Challenge and key configuration validation
def validate_nonce_hex(nonce: Any) -> bytes:
    """Decode a 16-byte request nonce from hexadecimal text; reject malformed values."""
    if not isinstance(nonce, str):
        raise ValueError("nonce must be a string containing exactly 32 hex characters.")
    if len(nonce) != 32:
        raise ValueError("nonce must contain exactly 32 hex characters.")
    try:
        nonce_bytes = bytes.fromhex(nonce)
    except ValueError as exc:
        raise ValueError("nonce must contain exactly 32 hex characters.") from exc
    if len(nonce_bytes) != 16:
        raise ValueError("nonce must decode to exactly 16 bytes.")
    return nonce_bytes


def duration_seconds_to_milliseconds(duration_s: float) -> int:
    """Return an exact positive millisecond duration; reject unrepresentable seconds."""
    requested_duration_ms = round(duration_s * 1000.0)
    if requested_duration_ms <= 0:
        raise ValueError("duration_s must represent at least one millisecond.")
    normalized_duration_s = requested_duration_ms / 1000.0
    if not math.isclose(duration_s, normalized_duration_s, rel_tol=0.0, abs_tol=1e-9):
        raise ValueError("duration_s must be representable to millisecond precision.")
    return requested_duration_ms

def load_and_validate_private_key(
    private_key_path: Path,
) -> tuple[ec.EllipticCurvePrivateKey, ec.EllipticCurvePublicKey, str]:
    """Load an unencrypted P-256 key and require its public fingerprint to match enrollment."""
    private_key = serialization.load_pem_private_key(
        private_key_path.read_bytes(), password=None
    )
    if not isinstance(private_key, ec.EllipticCurvePrivateKey):
        raise TypeError("REF_CITYA private key is not an EC private key.")
    if not isinstance(private_key.curve, ec.SECP256R1):
        raise ValueError("REF_CITYA private key does not use SECP256R1 / NIST P-256.")

    public_key = private_key.public_key()
    public_der = public_key.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    fingerprint = hashlib.sha256(public_der).hexdigest()
    if fingerprint != EXPECTED_PUBLIC_KEY_SHA256:
        raise ValueError(
            "REF_CITYA public-key fingerprint mismatch: "
            f"expected {EXPECTED_PUBLIC_KEY_SHA256}, got {fingerprint}."
        )
    return private_key, public_key, fingerprint


def _require_uint(name: str, value: Any, bits: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{name} must be an integer.")
    maximum = (1 << bits) - 1
    if not 0 <= value <= maximum:
        raise ValueError(f"{name} must be in the uint{bits} range.")
    return value


# STEP_3: Canonical metadata and signature processing
def serialize_ref_citya_evidence(record: "CaptureRecord") -> bytes:
    """Serialize capture identity, media digest, and timing fields into canonical evidence bytes."""
    if record.reference_node_id != DEFAULT_REFERENCE_NODE_ID:
        raise ValueError(f"reference_node_id must be {DEFAULT_REFERENCE_NODE_ID}.")
    if record.verifier_id != EXPECTED_VERIFIER_ID:
        raise ValueError(f"verifier_id must be {EXPECTED_VERIFIER_ID}.")
    if record.sample_format != DEFAULT_DTYPE:
        raise ValueError(f"sample_format must be {DEFAULT_DTYPE}.")

    node_id = record.reference_node_id.encode("ascii")
    verifier_id = record.verifier_id.encode("ascii")
    if len(REFERENCE_EVIDENCE_DOMAIN) != 22 or len(node_id) != 9 or len(verifier_id) != 11:
        raise ValueError("Reference evidence identity or domain length is invalid.")

    nonce_bytes = validate_nonce_hex(record.nonce)
    if record.wav_sha256 is None or len(record.wav_sha256) != 64:
        raise ValueError("wav_sha256 must contain exactly 64 hex characters.")
    try:
        wav_sha256_bytes = bytes.fromhex(record.wav_sha256)
    except ValueError as exc:
        raise ValueError("wav_sha256 must contain exactly 64 hex characters.") from exc
    if len(wav_sha256_bytes) != 32:
        raise ValueError("wav_sha256 must decode to exactly 32 bytes.")

    request_id = _require_uint("request_id", record.request_id, 32)
    sample_rate_hz = _require_uint("sample_rate_hz", record.sample_rate_hz, 32)
    channels = _require_uint("channels", record.channels, 8)
    requested_duration_ms = _require_uint(
        "requested_duration_ms", record.requested_duration_ms, 32
    )
    expected_samples = _require_uint("expected_samples", record.expected_samples, 32)
    actual_samples = _require_uint("actual_samples", record.actual_samples, 32)
    wav_size_bytes = _require_uint("wav_size_bytes", record.wav_size_bytes, 64)
    start_command_unix_ns = _require_uint(
        "start_command_unix_ns", record.start_command_unix_ns, 64
    )
    capture_call_unix_ns = _require_uint(
        "capture_call_unix_ns", record.capture_call_unix_ns, 64
    )
    capture_complete_unix_ns = _require_uint(
        "capture_complete_unix_ns", record.capture_complete_unix_ns, 64
    )

    canonical_evidence = struct.pack(
        "!22sHB9sB11sI16sIBBBIIIQ32sQQQ",
        REFERENCE_EVIDENCE_DOMAIN,
        REFERENCE_EVIDENCE_VERSION,
        len(node_id),
        node_id,
        len(verifier_id),
        verifier_id,
        request_id,
        nonce_bytes,
        sample_rate_hz,
        channels,
        CONTAINER_FORMAT_WAV_PCM,
        SAMPLE_FORMAT_SIGNED_INT16_LE,
        requested_duration_ms,
        expected_samples,
        actual_samples,
        wav_size_bytes,
        wav_sha256_bytes,
        start_command_unix_ns,
        capture_call_unix_ns,
        capture_complete_unix_ns,
    )
    if len(canonical_evidence) != REFERENCE_EVIDENCE_SIZE:
        raise ValueError(f"Canonical REF_CITYA evidence must be exactly {REFERENCE_EVIDENCE_SIZE} bytes.")
    return canonical_evidence


def sign_ref_citya_evidence(
    record: "CaptureRecord", private_key: ec.EllipticCurvePrivateKey
) -> tuple[bytes, str, bytes]:
    """Return canonical evidence, its hex digest, and a deterministic raw P-256 signature."""
    canonical_evidence = serialize_ref_citya_evidence(record)
    evidence_digest = hashlib.sha256(canonical_evidence).digest()
    evidence_sha256 = evidence_digest.hex()
    try:
        signature_der = private_key.sign(
            evidence_digest,
            ec.ECDSA(Prehashed(hashes.SHA256()), deterministic_signing=True),
        )
    except (TypeError, RuntimeError, UnsupportedAlgorithm) as exc:
        raise RuntimeError(
            "Deterministic ECDSA signing is unsupported by this cryptography/OpenSSL environment."
        ) from exc

    r, s = decode_dss_signature(signature_der)
    try:
        signature_raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    except OverflowError as exc:
        raise ValueError("ECDSA P-256 signature component exceeds 32 bytes.") from exc
    if len(signature_raw) != 64:
        raise ValueError("RAW r||s signature must be exactly 64 bytes.")
    return canonical_evidence, evidence_sha256, signature_raw


def verify_ref_citya_evidence(
    canonical_evidence: bytes,
    signature_raw: bytes,
    public_key: ec.EllipticCurvePublicKey,
) -> None:
    """Verify a raw 64-byte ECDSA signature over canonical evidence; raise on failure."""
    if len(signature_raw) != 64:
        raise ValueError("RAW r||s signature must be exactly 64 bytes.")
    r = int.from_bytes(signature_raw[:32], "big")
    s = int.from_bytes(signature_raw[32:], "big")
    signature_der = encode_dss_signature(r, s)
    try:
        evidence_digest = hashlib.sha256(canonical_evidence).digest()
        public_key.verify(
            signature_der,
            evidence_digest,
            ec.ECDSA(Prehashed(hashes.SHA256())),
        )
    except InvalidSignature as exc:
        raise ValueError("Local REF_CITYA evidence signature verification failed.") from exc

@dataclass
class AgentConfig:
    host: str
    port: int
    save_dir: Path
    device: int | str | None
    sample_rate: int
    channels: int
    dtype: str
    reference_node_id: str
    private_key_path: Path


@dataclass
class CaptureRecord:
    request_id: int
    nonce: str
    duration_s: float
    sample_rate_hz: int
    channels: int
    sample_format: str
    reference_node_id: str
    verifier_id: str
    requested_duration_ms: int = 0
    state: str = "READY"
    error: str | None = None
    service_version: str = SERVICE_VERSION
    protocol: str = REFERENCE_CAPTURE_PROTOCOL
    expected_samples: int = 0
    actual_samples: int = 0
    start_command_received_utc: str | None = None
    capture_call_before_utc: str | None = None
    capture_call_after_utc: str | None = None
    capture_call_before_perf_ns: int | None = None
    capture_call_after_perf_ns: int | None = None
    capture_completed_utc: str | None = None
    wav_save_started_utc: str | None = None
    wav_save_completed_utc: str | None = None
    wav_filename: str | None = None
    wav_size_bytes: int = 0
    wav_sha256: str | None = None
    wav_path: str | None = None
    manifest_path: str | None = None
    prepared_utc: str | None = None
    start_command_unix_ns: int | None = None
    capture_call_unix_ns: int | None = None
    capture_complete_unix_ns: int | None = None
    signature_algorithm: str | None = None
    signature_format: str | None = None
    signed_evidence_sha256: str | None = None
    signature_hex: str | None = None

    def to_status_dict(self) -> dict[str, Any]:
        """Return capture state and timing metadata for an HTTP status response."""
        return {
            "request_id": self.request_id,
            "state": self.state,
            "nonce": self.nonce,
            "verifier_id": self.verifier_id,
            "duration_s": self.duration_s,
            "requested_duration_ms": self.requested_duration_ms,
            "sample_rate": self.sample_rate_hz,
            "channels": self.channels,
            "dtype": self.sample_format,
            "start_command_received_utc": self.start_command_received_utc,
            "capture_call_before_utc": self.capture_call_before_utc,
            "capture_call_after_utc": self.capture_call_after_utc,
            "capture_call_before_perf_ns": self.capture_call_before_perf_ns,
            "capture_call_after_perf_ns": self.capture_call_after_perf_ns,
            "capture_completed_utc": self.capture_completed_utc,
            "wav_save_started_utc": self.wav_save_started_utc,
            "wav_save_completed_utc": self.wav_save_completed_utc,
            "actual_samples": self.actual_samples,
            "wav_filename": self.wav_filename,
            "wav_size_bytes": self.wav_size_bytes,
            "wav_sha256": self.wav_sha256,
            "start_command_unix_ns": self.start_command_unix_ns,
            "capture_call_unix_ns": self.capture_call_unix_ns,
            "capture_complete_unix_ns": self.capture_complete_unix_ns,
            "signature_algorithm": self.signature_algorithm,
            "signature_format": self.signature_format,
            "signed_evidence_sha256": self.signed_evidence_sha256,
            "signature_hex": self.signature_hex,
            "error": self.error,
        }

    def to_manifest_dict(self) -> dict[str, Any]:
        """Return capture metadata including evidence-signature fields for the manifest response."""
        manifest = {
            "protocol": self.protocol,
            "reference_evidence_version": REFERENCE_EVIDENCE_VERSION,
            "request_id": self.request_id,
            "nonce": self.nonce,
            "reference_node_id": self.reference_node_id,
            "verifier_id": self.verifier_id,
            "sample_rate_hz": self.sample_rate_hz,
            "channels": self.channels,
            "sample_format": self.sample_format,
            "requested_duration_s": self.duration_s,
            "requested_duration_ms": self.requested_duration_ms,
            "expected_samples": self.expected_samples,
            "actual_samples": self.actual_samples,
            "start_command_received_utc": self.start_command_received_utc,
            "capture_call_before_utc": self.capture_call_before_utc,
            "capture_call_after_utc": self.capture_call_after_utc,
            "capture_call_before_perf_ns": self.capture_call_before_perf_ns,
            "capture_call_after_perf_ns": self.capture_call_after_perf_ns,
            "capture_completed_utc": self.capture_completed_utc,
            "wav_save_started_utc": self.wav_save_started_utc,
            "wav_save_completed_utc": self.wav_save_completed_utc,
            "wav_filename": self.wav_filename,
            "wav_size_bytes": self.wav_size_bytes,
            "wav_sha256": self.wav_sha256,
            "start_command_unix_ns": self.start_command_unix_ns,
            "capture_call_unix_ns": self.capture_call_unix_ns,
            "capture_complete_unix_ns": self.capture_complete_unix_ns,
            "signature_algorithm": self.signature_algorithm,
            "signature_format": self.signature_format,
            "signed_evidence_sha256": self.signed_evidence_sha256,
            "signature_hex": self.signature_hex,
            "signed_evidence_fields": list(SIGNED_EVIDENCE_FIELDS),
            "diagnostic_fields_not_signed": [
                "service_version",
                "requested_duration_s",
                "prepared_utc",
                "start_command_received_utc",
                "capture_call_before_utc",
                "capture_call_after_utc",
                "capture_call_before_perf_ns",
                "capture_call_after_perf_ns",
                "capture_completed_utc",
                "wav_save_started_utc",
                "wav_save_completed_utc",
                "wav_filename",
            ],
            "service_version": self.service_version,
        }
        if self.error is not None:
            manifest["error"] = self.error
        return manifest


class AgentStateError(RuntimeError):
    pass


# STEP_4: Capture transaction state and acquisition
class ReferenceCaptureAgent:
    def __init__(self, config: AgentConfig) -> None:
        """Validate the signing key, create capture directories, and initialize locked state."""
        self.config = config
        (
            self.private_key,
            self.public_key,
            self.public_key_sha256,
        ) = load_and_validate_private_key(config.private_key_path)
        self.data_dir = config.save_dir
        self.traces_dir = self.data_dir / "traces"
        self.manifests_dir = self.data_dir / "manifests"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.traces_dir.mkdir(parents=True, exist_ok=True)
        self.manifests_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.current_record: CaptureRecord | None = None
        self.completed_records: dict[int, CaptureRecord] = {}
        self.worker_thread: threading.Thread | None = None

    def get_state(self) -> str:
        """Return the active capture state while holding the service lock."""
        with self.lock:
            if self.current_record is None:
                return "IDLE"
            return self.current_record.state

    def describe_input_device(self) -> dict[str, Any] | None:
        """Return available audio-input metadata, or None if the device query fails."""
        try:
            device = sd.query_devices(self.config.device, "input")
        except Exception:
            return None

        return {
            "name": device.get("name"),
            "max_input_channels": device.get("max_input_channels"),
            "default_samplerate": device.get("default_samplerate"),
        }

    def health(self) -> dict[str, Any]:
        response = {
            "service": REFERENCE_SERVICE_ID,
            "status": "OK",
            "state": self.get_state(),
            "utc": utc_now_iso(),
            "sample_rate": self.config.sample_rate,
            "channels": self.config.channels,
            "dtype": self.config.dtype,
        }
        device_info = self.describe_input_device()
        if device_info is not None:
            response["input_device"] = device_info
        return response

    def _get_record_unlocked(self, request_id: int) -> CaptureRecord | None:
        """Look up an active or completed capture; the caller must hold the service lock."""
        if self.current_record is not None and self.current_record.request_id == request_id:
            return self.current_record
        return self.completed_records.get(request_id)

    def get_record(self, request_id: int) -> CaptureRecord | None:
        """Return the identified active or completed capture under the service lock."""
        with self.lock:
            return self._get_record_unlocked(request_id)

    def prepare_capture(
        self, request_id: int, nonce: str, verifier_id: str, duration_s: float
    ) -> CaptureRecord:
        """Validate capture parameters and prepare device/session state without starting sample collection."""
        nonce_bytes = validate_nonce_hex(nonce)
        requested_duration_ms = duration_seconds_to_milliseconds(duration_s)
        if verifier_id != EXPECTED_VERIFIER_ID:
            raise ValueError(f"verifier_id must be exactly {EXPECTED_VERIFIER_ID}.")

        sd.check_input_settings(
            device=self.config.device,
            channels=self.config.channels,
            samplerate=self.config.sample_rate,
            dtype=self.config.dtype,
        )

        with self.lock:
            if self.current_record is not None and self.current_record.state in ("STARTING", "CAPTURING"):
                raise AgentStateError(
                    f"Cannot PREPARE request {request_id} while request "
                    f"{self.current_record.request_id} is {self.current_record.state}."
                )

            record = CaptureRecord(
                request_id=request_id,
                nonce=nonce_bytes.hex(),
                duration_s=duration_s,
                sample_rate_hz=self.config.sample_rate,
                channels=self.config.channels,
                sample_format=self.config.dtype,
                reference_node_id=self.config.reference_node_id,
                verifier_id=verifier_id,
                requested_duration_ms=requested_duration_ms,
                prepared_utc=utc_now_iso(),
                expected_samples=(requested_duration_ms * self.config.sample_rate) // 1000,
            )
            self.current_record = record

        print(f"[REFDB] PREPARE request {request_id}")
        print(f"[REFDB] READY request {request_id}")
        return record

    def start_capture(
        self, request_id: int, nonce: str, verifier_id: str
    ) -> CaptureRecord:
        """Start a prepared transaction after checking identity and state; return its record."""
        with self.lock:
            if self.current_record is None:
                raise AgentStateError("No prepared request is available.")
            if self.current_record.state in ("STARTING", "CAPTURING"):
                raise AgentStateError(
                    f"Request {self.current_record.request_id} is already {self.current_record.state}."
                )
            if self.current_record.request_id != request_id:
                raise AgentStateError(
                    f"START request ID mismatch: got {request_id}, expected {self.current_record.request_id}."
                )
            if validate_nonce_hex(self.current_record.nonce) != validate_nonce_hex(nonce):
                raise AgentStateError("START nonce mismatch.")
            if self.current_record.verifier_id != verifier_id:
                raise AgentStateError("START verifier_id mismatch.")

            self.current_record.state = "STARTING"
            self.current_record.start_command_received_utc = utc_now_iso()
            self.current_record.start_command_unix_ns = time.time_ns()
            record = self.current_record
            self.worker_thread = threading.Thread(
                target=self._capture_worker,
                args=(record,),
                daemon=True,
                name=f"refdb-capture-{request_id}",
            )
            self.worker_thread.start()

        print(f"[REFDB] START request {request_id}")
        return record

    def _capture_worker(self, record: CaptureRecord) -> None:
        """Complete device capture and persist trace metadata; publish failures in transaction state."""
        request_id = record.request_id
        timestamp_tag = utc_filename_stamp()
        wav_path = self.traces_dir / f"ref_{request_id}_{timestamp_tag}.wav"
        manifest_path = self.manifests_dir / f"ref_{request_id}_{timestamp_tag}.json"

        try:
            record.capture_call_before_utc = utc_now_iso()
            record.capture_call_before_perf_ns = time.perf_counter_ns()
            record.capture_call_unix_ns = time.time_ns()

            recording = sd.rec(
                record.expected_samples,
                samplerate=record.sample_rate_hz,
                channels=record.channels,
                dtype=record.sample_format,
                device=self.config.device,
            )

            record.capture_call_after_utc = utc_now_iso()
            record.capture_call_after_perf_ns = time.perf_counter_ns()

            with self.lock:
                if self.current_record is record:
                    self.current_record.state = "CAPTURING"

            print(f"[REFDB] CAPTURING request {request_id}")

            sd.wait()
            record.capture_complete_unix_ns = time.time_ns()
            record.capture_completed_utc = utc_now_iso()

            if not isinstance(recording, np.ndarray):
                recording = np.asarray(recording)

            if recording.dtype != np.int16:
                raise RuntimeError(f"Unexpected recording dtype: {recording.dtype}")

            if record.channels == 1 and recording.ndim == 1:
                frames = recording
            elif recording.ndim == 2 and recording.shape[1] == record.channels:
                frames = recording
            else:
                raise RuntimeError(
                    f"Unexpected recording shape for {record.channels} channels: {recording.shape}"
                )

            record.actual_samples = int(recording.shape[0])
            record.wav_save_started_utc = utc_now_iso()
            self._write_wav(wav_path, recording, record)
            record.wav_save_completed_utc = utc_now_iso()

            record.wav_filename = wav_path.name
            record.wav_path = str(wav_path)
            record.manifest_path = str(manifest_path)
            record.wav_size_bytes = wav_path.stat().st_size
            record.wav_sha256 = sha256_file(wav_path)

            canonical_evidence, evidence_sha256, signature_raw = (
                sign_ref_citya_evidence(record, self.private_key)
            )
            verify_ref_citya_evidence(
                canonical_evidence, signature_raw, self.public_key
            )
            record.signature_algorithm = SIGNATURE_ALGORITHM
            record.signature_format = SIGNATURE_FORMAT
            record.signed_evidence_sha256 = evidence_sha256
            record.signature_hex = signature_raw.hex()

            manifest = record.to_manifest_dict()
            safe_atomic_json_write(manifest_path, manifest)

            with self.lock:
                record.state = "COMPLETE"
                self.completed_records[request_id] = record
                if self.current_record is record:
                    self.current_record = record

            print(f"[REFDB] Capture complete request {request_id}")
            print(f"[REFDB] WAV saved: {wav_path}")
            print(f"[REFDB] SHA256: {record.wav_sha256}")
            print(f"[REFDB] COMPLETE request {request_id}")
        except Exception as exc:
            with self.lock:
                record.state = "ERROR"
                record.error = str(exc)
                if self.current_record is record:
                    self.current_record = record
            print(f"[REFDB] ERROR request {request_id}: {exc}")

    def _write_wav(self, wav_path: Path, recording: np.ndarray, record: CaptureRecord) -> None:
        """Persist captured int16 audio using the record's channel count and sample rate."""
        with wave.open(str(wav_path), "wb") as wav_handle:
            wav_handle.setnchannels(record.channels)
            wav_handle.setsampwidth(2)
            wav_handle.setframerate(record.sample_rate_hz)
            wav_handle.writeframes(recording.tobytes())


# STEP_5: HTTP request and response contract
class ReferenceRequestHandler(BaseHTTPRequestHandler):
    server_version = REFERENCE_SERVICE_ID

    @property
    def agent(self) -> ReferenceCaptureAgent:
        return self.server.agent  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        """Serve health or capture resources, returning HTTP errors for invalid requests."""
        try:
            path = urlparse(self.path).path
            if path == "/health":
                self._send_json(HTTPStatus.OK, self.agent.health())
                return

            if path.startswith("/capture/"):
                request_id, resource = self._parse_capture_path(path)
                record = self.agent.get_record(request_id)
                if record is None:
                    self._send_json_error(HTTPStatus.NOT_FOUND, "Unknown request_id.")
                    return

                if resource == "status":
                    self._send_json(HTTPStatus.OK, record.to_status_dict())
                    return

                if resource == "manifest":
                    if record.state != "COMPLETE" or record.manifest_path is None:
                        self._send_json_error(
                            HTTPStatus.CONFLICT,
                            "Manifest is only available when capture state is COMPLETE.",
                        )
                        return
                    manifest_path = Path(record.manifest_path)
                    with manifest_path.open("r", encoding="utf-8") as handle:
                        manifest = json.load(handle)
                    self._send_json(HTTPStatus.OK, manifest)
                    return

                if resource == "trace":
                    if record.state != "COMPLETE" or record.wav_path is None:
                        self._send_json_error(
                            HTTPStatus.CONFLICT,
                            "Trace is only available when capture state is COMPLETE.",
                        )
                        return
                    self._stream_wav(Path(record.wav_path))
                    return

                self._send_json_error(HTTPStatus.NOT_FOUND, "Unknown capture resource.")
                return

            self._send_json_error(HTTPStatus.NOT_FOUND, "Unknown endpoint.")
        except ValueError as exc:
            self._send_json_error(HTTPStatus.BAD_REQUEST, str(exc))
        except Exception as exc:
            self._send_json_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))

    def do_POST(self) -> None:
        """Dispatch capture PREPARE/START requests and report validation or state errors."""
        try:
            path = urlparse(self.path).path
            if path == "/capture/prepare":
                payload = self._read_json_body()
                request_id = self._require_positive_int(payload, "request_id")
                nonce = self._require_nonce(payload, "nonce")
                verifier_id = self._require_nonempty_string(payload, "verifier_id")
                duration_s = self._require_positive_float(payload, "duration_s")
                record = self.agent.prepare_capture(
                    request_id, nonce, verifier_id, duration_s
                )
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "request_id": record.request_id,
                        "state": record.state,
                        "duration_s": record.duration_s,
                        "sample_rate": record.sample_rate_hz,
                        "channels": record.channels,
                        "verifier_id": record.verifier_id,
                    },
                )
                return

            if path == "/capture/start":
                payload = self._read_json_body()
                request_id = self._require_positive_int(payload, "request_id")
                nonce = self._require_nonce(payload, "nonce")
                verifier_id = self._require_nonempty_string(payload, "verifier_id")
                record = self.agent.start_capture(request_id, nonce, verifier_id)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "request_id": record.request_id,
                        "state": record.state,
                        "nonce": record.nonce,
                    },
                )
                return

            self._send_json_error(HTTPStatus.NOT_FOUND, "Unknown endpoint.")
        except AgentStateError as exc:
            self._send_json_error(HTTPStatus.CONFLICT, str(exc))
        except ValueError as exc:
            self._send_json_error(HTTPStatus.BAD_REQUEST, str(exc))
        except Exception as exc:
            self._send_json_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))

    def log_message(self, format: str, *args: Any) -> None:
        """Suppress the default HTTP access log; explicit service diagnostics remain."""
        return

    def _parse_capture_path(self, path: str) -> tuple[int, str]:
        """Parse a capture resource URL and require a positive request ID."""
        parts = [part for part in path.split("/") if part]
        if len(parts) != 3 or parts[0] != "capture":
            raise ValueError("Malformed capture path.")
        try:
            request_id = int(parts[1], 10)
        except ValueError as exc:
            raise ValueError("request_id must be a positive integer.") from exc
        if request_id <= 0:
            raise ValueError("request_id must be a positive integer.")
        return request_id, parts[2]

    def _read_json_body(self) -> dict[str, Any]:
        """Read and validate the HTTP JSON request body; reject malformed input."""
        content_length_text = self.headers.get("Content-Length")
        if content_length_text is None:
            raise ValueError("Missing Content-Length header.")
        content_length = int(content_length_text, 10)
        if content_length <= 0:
            raise ValueError("Request body must not be empty.")
        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON body: {exc}") from exc
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object.")
        return payload

    def _require_positive_int(self, payload: dict[str, Any], field: str) -> int:
        value = payload.get(field)
        if not isinstance(value, int) or value <= 0:
            raise ValueError(f"{field} must be a positive integer.")
        return value

    def _require_nonce(self, payload: dict[str, Any], field: str) -> str:
        value = payload.get(field)
        validate_nonce_hex(value)
        return value
    def _require_nonempty_string(self, payload: dict[str, Any], field: str) -> str:
        value = payload.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f"{field} must be a non-empty string.")
        return value

    def _require_positive_float(self, payload: dict[str, Any], field: str) -> float:
        value = payload.get(field)
        if not isinstance(value, (int, float)) or float(value) <= 0.0:
            raise ValueError(f"{field} must be a positive number.")
        return float(value)

    def _send_json(self, status_code: HTTPStatus, payload: dict[str, Any]) -> None:
        """Write an HTTP JSON response with its status and byte length."""
        encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _send_json_error(self, status_code: HTTPStatus, message: str) -> None:
        """Return a structured HTTP error response with a UTC timestamp."""
        self._send_json(
            status_code,
            {
                "service": REFERENCE_SERVICE_ID,
                "status": "ERROR",
                "message": message,
                "utc": utc_now_iso(),
            },
        )

    def _stream_wav(self, wav_path: Path) -> None:
        """Stream the saved WAV to the HTTP client."""
        file_size = wav_path.stat().st_size
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(file_size))
        self.end_headers()
        with wav_path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(DEFAULT_STREAM_CHUNK_BYTES), b""):
                self.wfile.write(chunk)


def run_crypto_self_test(private_key_path: Path) -> None:
    """Exercise reference signing and verification with the configured private key, without audio capture."""
    private_key, public_key, fingerprint = load_and_validate_private_key(
        private_key_path
    )
    record = CaptureRecord(
        request_id=1,
        nonce="00112233445566778899aabbccddeeff",
        duration_s=220.0,
        sample_rate_hz=44100,
        channels=1,
        sample_format="int16",
        reference_node_id=DEFAULT_REFERENCE_NODE_ID,
        verifier_id=EXPECTED_VERIFIER_ID,
        requested_duration_ms=220000,
        expected_samples=9702000,
        actual_samples=9702000,
        wav_size_bytes=19404044,
        wav_sha256=(
            "000102030405060708090a0b0c0d0e0f"
            "101112131415161718191a1b1c1d1e1f"
        ),
        start_command_unix_ns=1000000000,
        capture_call_unix_ns=1000001000,
        capture_complete_unix_ns=221000001000,
    )
    canonical_evidence, evidence_sha256, signature_raw = sign_ref_citya_evidence(
        record, private_key
    )
    second_evidence, second_hash, second_signature = sign_ref_citya_evidence(
        record, private_key
    )
    if (
        second_evidence != canonical_evidence
        or second_hash != evidence_sha256
        or second_signature != signature_raw
    ):
        raise RuntimeError("Deterministic ECDSA repeatability self-test failed.")
    verify_ref_citya_evidence(canonical_evidence, signature_raw, public_key)

    print(f"[REFERENCE EVIDENCE VERIFICATION] Protocol           : {REFERENCE_CAPTURE_PROTOCOL}")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Reference node     : {DEFAULT_REFERENCE_NODE_ID}")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Verifier           : {EXPECTED_VERIFIER_ID}")
    print("[REFERENCE EVIDENCE VERIFICATION] Algorithm          : ECDSA P-256 + SHA-256")
    print("[REFERENCE EVIDENCE VERIFICATION] Curve              : SECP256R1")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Public key SHA-256 : {fingerprint}")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Nonce bytes        : {len(validate_nonce_hex(record.nonce))}")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Canonical evidence : {len(canonical_evidence)} bytes")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Evidence SHA-256   : {evidence_sha256}")
    print("[REFERENCE EVIDENCE VERIFICATION] Signature format   : RAW r||s")
    print(f"[REFERENCE EVIDENCE VERIFICATION] Signature bytes    : {len(signature_raw)}")
    print("[REFERENCE EVIDENCE VERIFICATION] Local verification : PASS")
    print("[ATTESTATION DECISION] REF_CITYA cryptographic self-test: PASS")

def parse_positive_int_arg(text: str) -> int:
    value = int(text, 10)
    if value <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return value


def parse_device_arg(text: str) -> int | str:
    if text.isdigit():
        return int(text, 10)
    return text


def parse_reference_node_id_arg(text: str) -> str:
    if text != DEFAULT_REFERENCE_NODE_ID:
        raise argparse.ArgumentTypeError(
            f"Reference-evidence identity must be {DEFAULT_REFERENCE_NODE_ID}"
        )
    return text

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reference ENF RefDB Server for the ZedBoard attestation project."
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument(
        "--private-key",
        type=Path,
        default=DEFAULT_PRIVATE_KEY_PATH,
    )
    parser.add_argument(
        "--crypto-self-test",
        action="store_true",
        help="Run the reference-evidence cryptographic self-test without starting the server.",
    )
    parser.add_argument("--port", type=parse_positive_int_arg, default=DEFAULT_PORT)
    parser.add_argument(
        "--save-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "data",
    )
    parser.add_argument("--device", type=parse_device_arg, default=None)
    parser.add_argument(
        "--sample-rate",
        type=parse_positive_int_arg,
        default=DEFAULT_SAMPLE_RATE,
    )
    parser.add_argument(
        "--channels",
        type=parse_positive_int_arg,
        default=DEFAULT_CHANNELS,
    )
    parser.add_argument("--dtype", default=DEFAULT_DTYPE)
    parser.add_argument(
        "--reference-node-id",
        type=parse_reference_node_id_arg,
        default=DEFAULT_REFERENCE_NODE_ID,
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List sounddevice devices and exit.",
    )
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> AgentConfig:
    """Construct server configuration from validated CLI options and resolved paths."""
    if args.reference_node_id != DEFAULT_REFERENCE_NODE_ID:
        raise ValueError(
            f"Reference-evidence identity must be {DEFAULT_REFERENCE_NODE_ID}."
        )
    return AgentConfig(
        host=args.host,
        port=args.port,
        save_dir=args.save_dir.resolve(),
        device=args.device,
        sample_rate=args.sample_rate,
        channels=args.channels,
        dtype=args.dtype,
        reference_node_id=args.reference_node_id,
        private_key_path=args.private_key.resolve(),
    )


# STEP_6: Reference service entrypoint
def main() -> int:
    """Parse server options, optionally list devices or self-test crypto, then serve live audio requests."""
    args = parse_args()

    if args.crypto_self_test:
        run_crypto_self_test(args.private_key.resolve())
        return 0

    if args.list_devices:
        list_input_devices()
        return 0

    config = build_config(args)
    print_service_header(config)

    agent = ReferenceCaptureAgent(config)
    server = ThreadingHTTPServer((config.host, config.port), ReferenceRequestHandler)
    server.agent = agent  # type: ignore[attr-defined]

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[REFDB] Shutdown requested.")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
