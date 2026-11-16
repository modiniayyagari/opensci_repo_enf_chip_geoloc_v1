"""Validate saved board and mains evidence for offline reproduction.

The reproduction entrypoint loads this helper by path to avoid importing the
live UART verifier. Functions decode canonical evidence, check enrolled public
keys, verify ECDSA signatures and request/nonce bindings, validate unsigned
Pico metadata, and export signed board ENF values to CSV. No hardware, network,
or standalone CLI is provided. A public demo board key cannot prove exclusive
hardware origin.
"""

# STEP_1: Dependencies and configuration
import csv, hashlib, hmac, json, math, struct
from pathlib import Path
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed, encode_dss_signature

TRUST_STORE_PATH = Path(__file__).resolve().parents[1] / 'verifier' / 'keys' / 'trusted' / 'trust_store.json'

BOARD_ATTESTATION_PROTOCOL = "ENF_LOCATION_ATTESTATION"

REFERENCE_CAPTURE_PROTOCOL = "ENF_REFERENCE_CAPTURE"

VERIFIER_ID = "VERIF_CITYA"

REF_NODE_ID = "REF_CITYA"

PICO_REF_NODE_ID = "REF_PICO_CITYA"

PICO_REF_SERVICE_ID = "ENF_PICO_REFERENCE_SERVICE"

PICO_REF_DURATION_SECONDS = 220

PICO_REF_TARGET_SAMPLE_RATE_HZ = 44100

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

# STEP_2: Canonical board evidence validation
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

# STEP_3: Board identity and signature verification
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
    # Prehashed ECDSA consumes this digest once; raw transport r/s needs DER encoding.
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

# STEP_4: Canonical mains evidence reconstruction
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

# STEP_5: Mains signature and transaction binding
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
    # Reconstruct signed fields rather than trusting a manifest's claimed digest.
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

# STEP_6: Signed board ENF output and Pico consistency helpers
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
