"""Extract reference ENF and compare saved board, mains, and Pico sequences.

Reads a mains WAV and manifest, host timing, board ENF CSV, and optional Pico
trace metadata. Writes aligned data, frame/comparison CSVs, metrics, and plots.
Processing uses eight-second frames, a nominal 1050-Hz rate, a 32768-point FFT,
and power-cubed weighting. This offline processor checks numerical/media
consistency; it does not verify evidence signatures or establish physical
synchronization or geographic acceptance.
"""

# STEP_1: Dependencies and configuration
from __future__ import annotations

import argparse
import csv
import json
import math
import wave
from datetime import datetime
from fractions import Fraction
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np

try:
    from scipy.signal import resample_poly
except ModuleNotFoundError as exc:
    resample_poly = None
    SCIPY_IMPORT_ERROR = exc
else:
    SCIPY_IMPORT_ERROR = None


SCRIPT_DIR = Path(__file__).resolve().parent
PNG_DPI = 300
NOMINAL_PRE_ROLL_S = 10.0
PICO_RATIO_MAX_DENOMINATOR = 10000

REFERENCE_CAPTURE_PROTOCOL = "ENF_REFERENCE_CAPTURE"
DEFAULT_REF_TRACE_BASENAME = "mains_pow_trace_220s_reference"
EXPECTED_FPGA_DURATION_S = 200.0
EXPECTED_FRAME_COUNT = 25
FRAME_DURATION_S = 8.0
REFERENCE_SAMPLE_RATE_HZ = 44100
RESAMPLED_SAMPLE_RATE_HZ = 1050.0
RESAMPLE_UP = 1
RESAMPLE_DOWN = 42
REFERENCE_FRAME_SAMPLES = int(REFERENCE_SAMPLE_RATE_HZ * FRAME_DURATION_S)
FRAME_SAMPLES = 8400
FFT_LENGTH = 32768
NORMALIZATION_PEAK = 0.95
SEARCH_BIN_FIRST = 1862
SEARCH_BIN_COUNT = 20
POWER_EXPONENT = 3
EXPECTED_TIME_VALUES = np.arange(
    0.0,
    EXPECTED_FRAME_COUNT * FRAME_DURATION_S,
    FRAME_DURATION_S,
    dtype=np.float64,
)


def parse_nonnegative_float_arg(text: str) -> float:
    value = float(text)
    if value < 0.0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return value


# STEP_2: Offline input and output configuration
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract both reference ENF sequences and compare all three sources."
    )
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--reference-manifest", type=Path, required=True)
    parser.add_argument("--host-timing", type=Path, required=True)
    parser.add_argument("--arm-enf-csv", type=Path, required=True)
    parser.add_argument("--pico-bin", type=Path, required=True)
    parser.add_argument("--pico-metadata", type=Path, required=True)
    parser.add_argument("--pico-host-timing", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument(
        "--ref-pre-roll",
        type=parse_nonnegative_float_arg,
        default=10.0,
        help="Configured reference pre-roll in seconds.",
    )
    parser.add_argument(
        "--ref-trace-basename",
        default=DEFAULT_REF_TRACE_BASENAME,
        help="Canonical basename for the 220-second reference trace.",
    )
    return parser.parse_args()


def ensure_valid_basename(text: str) -> str:
    """Reject empty names or path separators before constructing output filenames."""
    if not text or text in {".", ".."}:
        raise ValueError("reference trace basename must not be empty")
    if "/" in text or "\\" in text:
        raise ValueError(
            "reference trace basename must not contain path separators"
        )
    return text


def derive_aligned_trace_basename(trace_basename: str) -> str:
    if "220s" in trace_basename:
        return trace_basename.replace("220s", "200s", 1)
    return f"{trace_basename}_200s"


def derive_output_paths(data_dir: Path, results_dir: Path, trace_basename: str) -> dict[str, Path]:
    """Construct data and figure destinations from the supplied directories and trace basename."""
    aligned_basename = derive_aligned_trace_basename(trace_basename)
    return {
        "aligned_wav": data_dir / f"{aligned_basename}_aligned.wav",
        "reference_enf_csv": data_dir / f"{aligned_basename}_enf.csv",
        "comparison_csv": data_dir / "fpga_vs_mains_enf_comparison.csv",
        "metrics_json": data_dir / "fpga_vs_mains_enf_metrics.json",
        "comparison_png": results_dir / "fpga_vs_mains_enf_correlation.png",
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


def read_json_file(path: Path, description: str) -> dict:
    """Read a JSON object from disk or raise with the supplied context."""
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise RuntimeError(f"{description} must contain a JSON object: {path}")
    return payload


def write_json_atomic(path: Path, payload: dict) -> None:
    """Write JSON through a sibling temporary file before replacing the destination."""
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temp_path.replace(path)


def write_pcm16_wav(path: Path, samples: np.ndarray, sample_rate_hz: int) -> None:
    """Write mono int16 PCM samples at the supplied sample rate in Hz."""
    if samples.dtype != np.int16:
        raise RuntimeError("Aligned WAV samples must be int16.")
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate_hz)
        wav_file.writeframes(samples.tobytes())


def require_existing_file(path: Path, description: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"{description} does not exist: {resolved}")
    return resolved


def ensure_directory(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    resolved.mkdir(parents=True, exist_ok=True)
    if not resolved.is_dir():
        raise RuntimeError(f"Path is not a directory: {resolved}")
    return resolved


def require_nonempty_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{description} was not created: {path}")
    if path.stat().st_size <= 0:
        raise RuntimeError(f"{description} is empty: {path}")


def parse_iso8601(timestamp_text: str | None) -> datetime | None:
    if not timestamp_text:
        return None
    return datetime.fromisoformat(timestamp_text)


def compute_time_difference_seconds(
    later_timestamp: str | None,
    earlier_timestamp: str | None,
) -> float | None:
    """Return the timestamp difference in seconds, or None when either timestamp is absent."""
    later = parse_iso8601(later_timestamp)
    earlier = parse_iso8601(earlier_timestamp)
    if later is None or earlier is None:
        return None
    return (later - earlier).total_seconds()


def validate_manifest(manifest: dict) -> int:
    """Validate reference media metadata and return the expected sample count; no signature check."""
    if manifest.get("protocol") != REFERENCE_CAPTURE_PROTOCOL:
        raise RuntimeError(
            f"Unexpected attestation protocol: {manifest.get('protocol')!r}"
        )
    if manifest.get("sample_format") != "int16":
        raise RuntimeError(
            f"Reference manifest sample_format must be 'int16', found {manifest.get('sample_format')!r}."
        )

    sample_rate_hz = int(manifest.get("sample_rate_hz", 0))
    if sample_rate_hz != REFERENCE_SAMPLE_RATE_HZ:
        raise RuntimeError(
            f"Reference manifest sample_rate_hz mismatch: {sample_rate_hz} != {REFERENCE_SAMPLE_RATE_HZ}"
        )

    channels = int(manifest.get("channels", 0))
    if channels != 1:
        raise RuntimeError(f"Reference manifest channels mismatch: {channels} != 1")

    actual_samples = int(manifest.get("actual_samples", 0))
    if actual_samples <= 0:
        raise RuntimeError("Reference manifest actual_samples must be > 0.")
    return actual_samples


# STEP_3: Recording interpretation and nominal alignment
def load_reference_wav(reference_wav_path: Path, manifest: dict) -> tuple[np.ndarray, dict[str, int]]:
    """Return mono int16 PCM samples and rate metadata after checking manifest consistency."""
    with wave.open(str(reference_wav_path), "rb") as wav_file:
        if wav_file.getcomptype() != "NONE":
            raise RuntimeError(
                f"Reference WAV must be PCM/uncompressed, found compression {wav_file.getcomptype()!r}."
            )
        if wav_file.getnchannels() != 1:
            raise RuntimeError(
                f"Reference WAV must be mono, found {wav_file.getnchannels()} channels."
            )
        if wav_file.getsampwidth() != 2:
            raise RuntimeError(
                f"Reference WAV must be 16-bit PCM, found {wav_file.getsampwidth() * 8}-bit."
            )
        if wav_file.getframerate() != int(manifest["sample_rate_hz"]):
            raise RuntimeError(
                f"Reference WAV sample rate mismatch: {wav_file.getframerate()} != {manifest['sample_rate_hz']}"
            )

        frame_count = wav_file.getnframes()
        raw_frames = wav_file.readframes(frame_count)

    if len(raw_frames) != frame_count * 2:
        raise RuntimeError(
            f"Reference WAV byte count mismatch in PCM payload: {len(raw_frames)} != {frame_count * 2}"
        )

    file_size_bytes = reference_wav_path.stat().st_size
    expected_file_size_bytes = int(manifest.get("wav_size_bytes", 0))
    if expected_file_size_bytes > 0 and file_size_bytes != expected_file_size_bytes:
        raise RuntimeError(
            f"Reference WAV file size mismatch: {file_size_bytes} != {expected_file_size_bytes}"
        )

    manifest_sample_count = int(manifest["actual_samples"])
    if frame_count != manifest_sample_count:
        raise RuntimeError(
            f"Reference WAV sample count mismatch: {frame_count} != {manifest_sample_count}"
        )

    samples = np.frombuffer(raw_frames, dtype="<i2").copy()
    if samples.size != frame_count:
        raise RuntimeError(
            f"Reference WAV decoded sample count mismatch: {samples.size} != {frame_count}"
        )

    return samples, {
        "sample_rate_hz": int(manifest["sample_rate_hz"]),
        "sample_count": int(frame_count),
        "channels": 1,
    }


def build_alignment_metadata(
    host_timing: dict,
    sample_rate_hz: int,
    ref_pre_roll_s: float,
) -> dict:
    """Describe a nominal pre-roll crop in source samples; host timing is diagnostic only."""
    aligned_start_sample = int(round(ref_pre_roll_s * sample_rate_hz))
    aligned_sample_count = int(round(EXPECTED_FPGA_DURATION_S * sample_rate_hz))
    aligned_end_sample = aligned_start_sample + aligned_sample_count

    diagnostics = {
        "configured_pre_roll_s": ref_pre_roll_s,
        "host_get_minus_capture_after_s": compute_time_difference_seconds(
            host_timing.get("fpga_get_send_utc"),
            host_timing.get("manifest_capture_timestamps", {}).get(
                "capture_call_after_utc"
            ),
        ),
        "host_get_minus_capture_before_s": compute_time_difference_seconds(
            host_timing.get("fpga_get_send_utc"),
            host_timing.get("manifest_capture_timestamps", {}).get(
                "capture_call_before_utc"
            ),
        ),
        "host_get_minus_capturing_confirmed_s": compute_time_difference_seconds(
            host_timing.get("fpga_get_send_utc"),
            host_timing.get("host_ref_capturing_confirmed_utc"),
        ),
    }

    return {
        "alignment_method": "configured_reference_pre_roll",
        "reference_pre_roll_s": ref_pre_roll_s,
        "reference_sample_rate_hz": sample_rate_hz,
        "aligned_start_sample": aligned_start_sample,
        "aligned_end_sample": aligned_end_sample,
        "aligned_start_seconds": aligned_start_sample / sample_rate_hz,
        "aligned_duration_seconds": EXPECTED_FPGA_DURATION_S,
        "aligned_sample_count": aligned_sample_count,
        "expected_fpga_duration_s": EXPECTED_FPGA_DURATION_S,
        "diagnostic_offsets_s": diagnostics,
    }


def validate_alignment_bounds(
    alignment: dict,
    reference_sample_count: int,
) -> None:
    """Reject a nominal reference crop outside the available recording."""
    if alignment["aligned_start_sample"] < 0:
        raise RuntimeError("Aligned reference crop starts before sample 0.")
    if alignment["aligned_end_sample"] > reference_sample_count:
        raise RuntimeError(
            "Reference WAV does not contain enough samples for the configured 200-second aligned interval."
        )


def require_finite(name: str, values: np.ndarray) -> None:
    if not np.all(np.isfinite(values)):
        raise RuntimeError(f"{name} contains non-finite values.")


def load_arm_enf_csv(arm_enf_csv_path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Load 25 finite board ENF estimates and validate their eight-second frame indices."""
    with arm_enf_csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        required_columns = ["frame_index", "time_seconds", "enf_hz"]
        for column in required_columns:
            if column not in fieldnames:
                raise RuntimeError(
                    f"ARM ENF CSV is missing required column {column!r}: {arm_enf_csv_path}"
                )
        rows = list(reader)

    if len(rows) != EXPECTED_FRAME_COUNT:
        raise RuntimeError(
            f"Expected {EXPECTED_FRAME_COUNT} ARM ENF rows, found {len(rows)}."
        )

    time_seconds = np.empty(EXPECTED_FRAME_COUNT, dtype=np.float64)
    enf_values = np.empty(EXPECTED_FRAME_COUNT, dtype=np.float64)
    for expected_index, row in enumerate(rows):
        frame_index = int(row["frame_index"])
        if frame_index != expected_index:
            raise RuntimeError(
                f"ARM ENF frame_index mismatch at row {expected_index}: {frame_index}"
            )

        frame_time = float(row["time_seconds"])
        expected_time = float(EXPECTED_TIME_VALUES[expected_index])
        if not math.isclose(frame_time, expected_time, rel_tol=0.0, abs_tol=1e-9):
            raise RuntimeError(
                f"ARM ENF time_seconds mismatch at row {expected_index}: {frame_time} != {expected_time}"
            )

        enf_hz = float(row["enf_hz"])
        if not math.isfinite(enf_hz):
            raise RuntimeError(
                f"ARM ENF value at row {expected_index} is non-finite: {enf_hz}"
            )

        time_seconds[expected_index] = frame_time
        enf_values[expected_index] = enf_hz

    return time_seconds, enf_values


# STEP_4: Production windowing and ENF extraction
def get_reference_window(frame_sample_count: int) -> np.ndarray:
    """Return the symmetric Hamming window for the specified frame sample count."""
    n = np.arange(frame_sample_count, dtype=np.float64)
    return 0.54 - 0.46 * np.cos((2.0 * np.pi * n) / (frame_sample_count - 1))


def compute_reference_enf_hz(frame_int16: np.ndarray, hamming_window: np.ndarray) -> float:
    """Estimate Hz from an eight-second mains frame using 1050-Hz resampling and power-cubed FFT weights."""
    if SCIPY_IMPORT_ERROR is not None or resample_poly is None:
        raise RuntimeError(
            "scipy is required for 44100 Hz to 1050 Hz anti-aliased resampling via scipy.signal.resample_poly."
        ) from SCIPY_IMPORT_ERROR

    frame = frame_int16.astype(np.float64) / 32768.0
    frame -= np.mean(frame)
    resampled = resample_poly(frame, up=RESAMPLE_UP, down=RESAMPLE_DOWN)
    if resampled.size != FRAME_SAMPLES:
        raise RuntimeError(
            f"Resampled frame length mismatch: {resampled.size} != {FRAME_SAMPLES}"
        )

    peak = float(np.max(np.abs(resampled)))
    if peak <= 0.0:
        raise RuntimeError("Reference frame normalization peak is zero.")
    normalized = resampled * (NORMALIZATION_PEAK / peak)
    windowed = normalized * hamming_window

    spectrum = np.fft.rfft(windowed, n=FFT_LENGTH)
    power = np.abs(spectrum) ** 2
    search_bins = np.arange(
        SEARCH_BIN_FIRST,
        SEARCH_BIN_FIRST + SEARCH_BIN_COUNT,
        dtype=np.int64,
    )
    search_power = power[search_bins]
    weights = search_power ** POWER_EXPONENT
    weight_sum = float(np.sum(weights))
    if weight_sum <= 0.0 or not math.isfinite(weight_sum):
        raise RuntimeError("Reference ENF centroid weight sum is invalid.")

    frequencies_hz = search_bins.astype(np.float64) * (
        RESAMPLED_SAMPLE_RATE_HZ / FFT_LENGTH
    )
    enf_hz = float(np.sum(frequencies_hz * weights) / weight_sum)
    if not math.isfinite(enf_hz):
        raise RuntimeError("Reference ENF estimate is non-finite.")
    return enf_hz


def write_reference_enf_csv(
    path: Path,
    reference_enf_hz: np.ndarray,
    ref_pre_roll_s: float,
) -> None:
    """Write mains frame estimates with frame-relative times and the source pre-roll offset."""
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "frame_index",
                "frame_start_seconds",
                "reference_wav_start_seconds",
                "mains_enf_hz",
                "time_seconds",
                "enf_hz",
            ]
        )
        for frame_index, enf_hz in enumerate(reference_enf_hz):
            frame_start_seconds = float(EXPECTED_TIME_VALUES[frame_index])
            writer.writerow(
                [
                    frame_index,
                    int(frame_start_seconds),
                    f"{ref_pre_roll_s + frame_start_seconds:.17g}",
                    f"{float(enf_hz):.17g}",
                    int(frame_start_seconds),
                    f"{float(enf_hz):.17g}",
                ]
            )


def write_comparison_csv(
    path: Path,
    time_seconds: np.ndarray,
    sequence_a: np.ndarray,
    sequence_b: np.ndarray,
    column_a: str = "fpga_arm_enf_hz",
    column_b: str = "mains_reference_enf_hz",
) -> None:
    """Write paired Hz values and signed/absolute differences at the supplied frame times."""
    difference_hz = sequence_a - sequence_b
    abs_difference_hz = np.abs(difference_hz)

    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "frame_index",
                "frame_start_seconds",
                column_a,
                column_b,
                "difference_hz",
                "absolute_difference_hz",
            ]
        )
        for frame_index in range(EXPECTED_FRAME_COUNT):
            writer.writerow(
                [
                    frame_index,
                    int(time_seconds[frame_index]),
                    f"{float(sequence_a[frame_index]):.17g}",
                    f"{float(sequence_b[frame_index]):.17g}",
                    f"{float(difference_hz[frame_index]):.17g}",
                    f"{float(abs_difference_hz[frame_index]):.17g}",
                ]
            )


# STEP_5: Pairwise metrics and figure output
def compute_comparison_metrics(
    sequence_a: np.ndarray,
    sequence_b: np.ndarray,
) -> dict[str, float]:
    """Return Pearson r and Hz error metrics for equal finite nonconstant vectors."""
    require_finite("Sequence A ENF", sequence_a)
    require_finite("Sequence B ENF", sequence_b)

    if sequence_a.shape != sequence_b.shape:
        raise RuntimeError(
            f"ENF shape mismatch: {sequence_a.shape} vs {sequence_b.shape}"
        )
    if sequence_a.shape != (EXPECTED_FRAME_COUNT,):
        raise RuntimeError(
            f"Expected {EXPECTED_FRAME_COUNT} ENF values, found {sequence_a.size}."
        )
    if float(np.ptp(sequence_a)) == 0.0:
        raise RuntimeError("Pearson correlation is undefined because Sequence A ENF has zero variance.")
    if float(np.ptp(sequence_b)) == 0.0:
        raise RuntimeError(
            "Pearson correlation is undefined because sequence B ENF has zero variance."
        )

    difference_hz = sequence_a - sequence_b
    abs_difference_hz = np.abs(difference_hz)
    pearson_r = float(np.corrcoef(sequence_a, sequence_b)[0, 1])
    if not math.isfinite(pearson_r):
        raise RuntimeError("Pearson correlation is non-finite.")

    return {
        "pearson_r": pearson_r,
        "rmse_hz": float(np.sqrt(np.mean(np.square(difference_hz)))),
        "mae_hz": float(np.mean(abs_difference_hz)),
        "max_abs_error_hz": float(np.max(abs_difference_hz)),
        "mean_signed_difference_hz": float(np.mean(difference_hz)),
        "sequence_a_min_hz": float(np.min(sequence_a)),
        "sequence_a_max_hz": float(np.max(sequence_a)),
        "sequence_b_min_hz": float(np.min(sequence_b)),
        "sequence_b_max_hz": float(np.max(sequence_b)),
    }


def plot_comparison(
    output_path: Path,
    request_id: int,
    time_seconds: np.ndarray,
    sequence_a: np.ndarray,
    sequence_b: np.ndarray,
    pearson_r: float,
    label_a: str = "ZedBoard",
    label_b: str = "REF_CITYA",
) -> None:
    """Save the supplied pairwise ENF sequences and correlation as a comparison figure."""
    combined = np.concatenate((sequence_a, sequence_b))
    y_min = float(np.min(combined))
    y_max = float(np.max(combined))
    y_span = max(y_max - y_min, 0.001)
    y_margin = max(0.1 * y_span, 0.0005)

    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    ax.plot(
        time_seconds,
        sequence_a,
        marker="o",
        linewidth=1.6,
        markersize=4.2,
        label=label_a,
    )
    ax.plot(
        time_seconds,
        sequence_b,
        marker="s",
        linewidth=1.4,
        markersize=4.0,
        linestyle="--",
        label=label_b,
    )
    ax.set_xlim(float(time_seconds[0]), float(time_seconds[-1]))
    ax.set_ylim(y_min - y_margin, y_max + y_margin)
    ax.set_xlabel("Frame Start Time (seconds)")
    ax.set_ylabel("ENF Frequency (Hz)")
    ax.set_title(
        f"Request {request_id} - {label_a} vs {label_b}\nPearson r = {pearson_r:.9f}"
    )
    ax.grid(True)
    ax.legend(loc="lower left")
    fig.tight_layout()
    save_plot_formats(fig, output_path)


def save_plot_formats(fig, png_path: Path) -> None:
    """Write identical figure content directly to raster and vector formats."""
    svg_path = png_path.with_suffix(".svg")
    try:
        fig.savefig(png_path, dpi=PNG_DPI)
        fig.savefig(svg_path)
    finally:
        plt.close(fig)
    require_nonempty_file(png_path, "PNG plot")
    require_nonempty_file(svg_path, "SVG plot")


def plot_three_sources(path, request_id, times, zedboard, mains, pico):
    """Save an overlay of three ENF sequences on the supplied time coordinates."""
    combined = np.concatenate((zedboard, mains, pico))
    low, high = float(np.min(combined)), float(np.max(combined))
    margin = max(0.1 * max(high - low, 0.001), 0.0005)
    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    for values, label, marker, style in (
        (zedboard, "ZedBoard", "o", "-"),
        (mains, "REF_CITYA", "s", "--"),
        (pico, "REF_PICO_CITYA (unsigned)", "^", "-."),
    ):
        ax.plot(times, values, label=label, marker=marker, linestyle=style,
                linewidth=1.5, markersize=4.0)
    ax.set_xlim(float(times[0]), float(times[-1]))
    ax.set_ylim(low - margin, high + margin)
    ax.set_xlabel("Frame Start Time (seconds)")
    ax.set_ylabel("ENF Frequency (Hz)")
    ax.set_title(f"Request {request_id} - Three-source ENF comparison")
    ax.grid(True)
    ax.legend(loc="lower left")
    fig.tight_layout()
    save_plot_formats(fig, path)


def load_pico_binary(path: Path, metadata: dict):
    """Load little-endian int16 Pico data and validate unsigned metadata counts and actual rate."""
    for field, expected in {
        "trace_format": "raw_int16_le", "sample_format": "int16",
        "byte_order": "little", "bytes_per_sample": 2,
    }.items():
        if metadata.get(field) != expected or isinstance(metadata.get(field), bool):
            raise RuntimeError(f"Pico metadata invalid {field}")
    if metadata.get("authenticated") is not False:
        raise RuntimeError("Pico must remain an unsigned measurement source")
    count = metadata.get("actual_samples")
    if type(count) is not int or count <= 0:
        raise RuntimeError("Pico actual_samples must be a positive integer")
    if path.stat().st_size != count * 2 or metadata.get("trace_size_bytes") != count * 2:
        raise RuntimeError("Pico binary size must equal actual_samples * 2")
    interval = metadata.get("actual_sample_interval_ns")
    reported_rate = metadata.get("actual_sample_rate_hz")
    for name, value in (("interval", interval), ("rate", reported_rate)):
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise RuntimeError(f"Pico actual sample {name} must be finite and positive")
    rate = 1e9 / interval
    if not math.isfinite(rate) or not math.isclose(rate, reported_rate, rel_tol=1e-9, abs_tol=1e-6):
        raise RuntimeError("Pico sample interval and reported sample rate are inconsistent")
    samples = np.fromfile(path, dtype="<i2")
    if samples.size != count:
        raise RuntimeError("Pico loaded sample count mismatch")
    return samples, rate


def compute_pico_enf_hz(frame_int16, up, down, effective_rate):
    """Estimate Hz using rational resampling and the supplied effective rate, preserving actual frame length."""
    if SCIPY_IMPORT_ERROR is not None or resample_poly is None:
        raise RuntimeError("scipy is required for Pico anti-aliased resampling") from SCIPY_IMPORT_ERROR
    frame = frame_int16.astype(np.float64) / 32768.0
    frame -= np.mean(frame)
    resampled = resample_poly(frame, up=up, down=down)
    if not 1 < resampled.size <= FFT_LENGTH:
        raise RuntimeError("Pico resampled frame length is outside FFT capacity")
    peak = float(np.max(np.abs(resampled)))
    if not math.isfinite(peak) or peak <= 0:
        raise RuntimeError("Pico frame normalization peak is invalid")
    normalized = resampled * (NORMALIZATION_PEAK / peak)
    windowed = normalized * get_reference_window(resampled.size)
    spectrum = np.fft.rfft(windowed, n=FFT_LENGTH)
    power = np.abs(spectrum) ** 2
    # Same 20-bin search as REF_CITYA; Hz conversion uses the effective rate.
    search_bins = np.arange(SEARCH_BIN_FIRST, SEARCH_BIN_FIRST + SEARCH_BIN_COUNT,
                            dtype=np.int64)
    weights = power[search_bins] ** POWER_EXPONENT
    weight_sum = float(np.sum(weights))
    if not math.isfinite(weight_sum) or weight_sum <= 0:
        raise RuntimeError("Pico ENF centroid weight sum is invalid")
    frequencies_hz = search_bins.astype(np.float64) * (effective_rate / FFT_LENGTH)
    enf_hz = float(np.sum(frequencies_hz * weights) / weight_sum)
    if not math.isfinite(enf_hz):
        raise RuntimeError("Pico ENF estimate is non-finite")
    return enf_hz, int(resampled.size)


def extract_pico_enf(samples, rate, metadata):
    """Return 25 Pico frame estimates and nominal-crop metadata using its recorded actual sample rate."""
    ratio = Fraction(RESAMPLED_SAMPLE_RATE_HZ / rate).limit_denominator(PICO_RATIO_MAX_DENOMINATOR)
    up, down = ratio.numerator, ratio.denominator
    effective_rate = rate * up / down
    if up <= 0 or not math.isclose(effective_rate, RESAMPLED_SAMPLE_RATE_HZ, rel_tol=1e-5):
        raise RuntimeError("Pico bounded resampling ratio is insufficiently close to 1050 Hz")
    # Absolute times prevent cumulative rounding drift. No observed pre-roll is used.
    boundaries = [
        int(round((NOMINAL_PRE_ROLL_S + i * FRAME_DURATION_S) * rate))
        for i in range(EXPECTED_FRAME_COUNT + 1)
    ]
    if boundaries[0] < 0 or boundaries[-1] > samples.size:
        raise RuntimeError("Pico trace does not cover the nominal 10-to-210-second interval")
    if any(b <= a for a, b in zip(boundaries, boundaries[1:])):
        raise RuntimeError("Pico frame boundaries must be strictly increasing")
    enf = np.empty(EXPECTED_FRAME_COUNT, dtype=np.float64)
    lengths = []
    for i in range(EXPECTED_FRAME_COUNT):
        enf[i], length = compute_pico_enf_hz(
            samples[boundaries[i]:boundaries[i + 1]], up, down, effective_rate
        )
        lengths.append(length)
    require_finite("Pico ENF", enf)
    return enf, {
        "nominal_aligned_start_s": NOMINAL_PRE_ROLL_S,
        "nominal_aligned_duration_s": EXPECTED_FPGA_DURATION_S,
        "actual_sample_interval_ns": metadata["actual_sample_interval_ns"],
        "actual_sample_rate_hz": rate,
        "aligned_start_sample": boundaries[0],
        "aligned_end_sample": boundaries[-1],
        "aligned_sample_count": boundaries[-1] - boundaries[0],
        "sample_range_end_exclusive": True,
        "raw_frame_boundaries": boundaries,
        "resampled_frame_lengths": lengths,
        "pico_input_sample_rate_hz": rate,
        "pico_resample_up": up,
        "pico_resample_down": down,
        "pico_resampled_rate_hz": effective_rate,
        "ratio_max_denominator": PICO_RATIO_MAX_DENOMINATOR,
        "fft_length": FFT_LENGTH, "power_exponent": POWER_EXPONENT,
        "search_bin_first": SEARCH_BIN_FIRST, "search_bin_count": SEARCH_BIN_COUNT,
    }


def write_pico_enf_csv(path, values):
    """Write Pico Hz estimates at eight-second frame offsets."""
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["frame_index", "time_seconds", "enf_hz"])
        for i, value in enumerate(values):
            writer.writerow([i, int(EXPECTED_TIME_VALUES[i]), f"{float(value):.17g}"])


def process_three_sources(args, paths, manifest, host_timing, alignment,
                          times, zedboard, mains, original_metrics, legacy_payload):
    """Load Pico data, compute all three numerical comparisons, and write metrics and figures."""
    pico_path = require_existing_file(args.pico_bin, "Pico binary")
    metadata_path = require_existing_file(args.pico_metadata, "Pico metadata")
    timing_path = require_existing_file(args.pico_host_timing, "Pico host timing")
    metadata = read_json_file(metadata_path, "Pico metadata")
    pico_timing = read_json_file(timing_path, "Pico host timing")
    for field in ("request_id", "nonce", "verifier_id"):
        if metadata.get(field) != manifest.get(field):
            raise RuntimeError(f"Pico/REF_CITYA local artifact association mismatch: {field}")
    if pico_timing.get("request_id") != manifest.get("request_id"):
        raise RuntimeError("Pico timing request ID mismatch")
    samples, rate = load_pico_binary(pico_path, metadata)
    pico, pico_alignment = extract_pico_enf(samples, rate, metadata)
    samples[pico_alignment["aligned_start_sample"]:pico_alignment["aligned_end_sample"]].astype(
        "<i2", copy=False
    ).tofile(paths["pico_aligned_bin"])
    write_pico_enf_csv(paths["pico_enf_csv"], pico)
    request_id = int(manifest["request_id"])
    pairs = (
        ("zedboard_vs_ref_citya", "ZB_CITYA", "REF_CITYA", zedboard, mains,
         "comparison_csv", "comparison_png", "comparison_svg", original_metrics),
        ("zedboard_vs_ref_pico_citya", "ZB_CITYA", "REF_PICO_CITYA", zedboard, pico,
         "fpga_pico_csv", "fpga_pico_png", "fpga_pico_svg", None),
        ("ref_citya_vs_ref_pico_citya", "REF_CITYA", "REF_PICO_CITYA", mains, pico,
         "mains_pico_csv", "mains_pico_png", "mains_pico_svg", None),
    )
    pairwise, plots, comparisons = {}, {}, {}
    for key, source_a, source_b, a, b, csv_key, png_key, svg_key, existing in pairs:
        metrics = existing if existing is not None else compute_comparison_metrics(a, b)
        pairwise[key] = {
            "sequence_a": source_a, "sequence_b": source_b,
            "difference_direction": f"{source_a} - {source_b}",
            "frame_count": EXPECTED_FRAME_COUNT, **metrics,
        }
        if existing is None:
            write_comparison_csv(paths[csv_key], times, a, b,
                                 f"{source_a.lower()}_enf_hz", f"{source_b.lower()}_enf_hz")
            plot_comparison(paths[png_key], request_id, times, a, b, metrics["pearson_r"],
                            source_a, source_b)
        plots[key] = {"png": paths[png_key].name, "svg": paths[svg_key].name}
        comparisons[key] = paths[csv_key].name
    plot_three_sources(paths["three_source_png"], request_id, times, zedboard, mains, pico)
    plots["three_source"] = {"png": paths["three_source_png"].name,
                             "svg": paths["three_source_svg"].name}
    payload = {
        "protocol": manifest["protocol"], "request_id": request_id,
        "frame_count": EXPECTED_FRAME_COUNT,
        "frame_start_seconds": times.tolist(),
        "sources": {
            "zedboard": {"node_id": "ZB_CITYA", "authenticated": True,
                         "input": args.arm_enf_csv.name, "raw_samples_available": False},
            "ref_citya": {"node_id": "REF_CITYA", "authenticated": True,
                          "input": args.reference_wav.name,
                          "sample_rate_hz": REFERENCE_SAMPLE_RATE_HZ,
                          "estimator_constants": legacy_payload["estimator_constants"]},
            "ref_pico_citya": {"node_id": "REF_PICO_CITYA", "authenticated": False,
                               "input": pico_path.name, "metadata": metadata_path.name,
                               "validation": "unsigned consistency and transfer integrity",
                               "trace_format": "raw_int16_le", **pico_alignment},
        },
        "alignment": {
            "nominal_pre_roll_s": NOMINAL_PRE_ROLL_S,
            "aligned_duration_s": EXPECTED_FPGA_DURATION_S,
            "ref_citya": alignment, "ref_pico_citya": pico_alignment,
            "diagnostics": {
                "diagnostic_only": True,
                "ref_citya_observed_pre_roll_s": host_timing.get("ref_citya_observed_pre_roll_s"),
                "pico_ref_observed_pre_roll_s": pico_timing.get("pico_ref_observed_pre_roll_s"),
                "used_as_crop_offsets": False,
            },
        },
        "pairwise": pairwise,
        "outputs": {
            "enf_csv": {"zedboard": args.arm_enf_csv.name,
                        "ref_citya": paths["reference_enf_csv"].name,
                        "ref_pico_citya": paths["pico_enf_csv"].name},
            "comparison_csv": comparisons, "plots": plots,
            "pico_aligned_bin": paths["pico_aligned_bin"].name,
            "legacy_metrics": paths["metrics_json"].name,
        },
    }
    write_json_atomic(paths["three_source_metrics"], payload)
    for name, path in paths.items():
        require_nonempty_file(path, name)


def print_processing_summary(
    reference_wav_name: str,
    sample_rate_hz: int,
    alignment: dict,
    frame_count: int,
    metrics: dict,
) -> None:
    """Print source, crop, frame-count, and numerical-comparison diagnostics."""
    print("============================================================")
    print("[AC Mains Reference ENF Processing]")
    print("============================================================")
    print(f"[ENF MATCHING] Source WAV          : {reference_wav_name}")
    print(f"[ENF MATCHING] Source rate         : {sample_rate_hz} Hz")
    print(f"[ENF MATCHING] Nominal pre-roll    : {alignment['reference_pre_roll_s']:.3f} s")
    print(
        f"[ENF MATCHING] Aligned interval    : {alignment['aligned_start_seconds']:.3f} s -> "
        f"{alignment['aligned_start_seconds'] + alignment['aligned_duration_seconds']:.3f} s"
    )
    print(f"[ENF MATCHING] Aligned samples     : {alignment['aligned_sample_count']}")
    print(f"[ENF MATCHING] Frame count         : {frame_count}")
    print("[ENF MATCHING] ENF extraction      : PASS")
    print()
    print("============================================================")
    print("[FPGA vs AC Mains ENF Correlation]")
    print("============================================================")
    print(f"Frames compared           : {frame_count} / {EXPECTED_FRAME_COUNT}")
    print(f"Pearson correlation       : {metrics['pearson_r']:.17g}")
    print(f"RMSE                      : {metrics['rmse_hz']:.17g} Hz")
    print(f"Mean absolute error       : {metrics['mae_hz']:.17g} Hz")
    print(f"Maximum absolute error    : {metrics['max_abs_error_hz']:.17g} Hz")
    print(
        f"Mean signed difference    : {metrics['mean_signed_difference_hz']:.17g} Hz"
    )


# STEP_6: Offline processing workflow
def main() -> int:
    """Process saved reference recordings and board ENF into comparison artifacts."""
    args = parse_args()
    if args.ref_pre_roll != NOMINAL_PRE_ROLL_S:
        raise RuntimeError("Step 3 requires nominal --ref-pre-roll 10.0 seconds")

    trace_basename = ensure_valid_basename(args.ref_trace_basename)
    reference_wav_path = require_existing_file(args.reference_wav, "Reference WAV")
    reference_manifest_path = require_existing_file(
        args.reference_manifest, "Reference manifest"
    )
    host_timing_path = require_existing_file(args.host_timing, "Reference host timing JSON")
    arm_enf_csv_path = require_existing_file(args.arm_enf_csv, "ARM ENF CSV")
    data_dir = ensure_directory(args.data_dir)
    results_dir = ensure_directory(args.results_dir)
    output_paths = derive_output_paths(data_dir, results_dir, trace_basename)

    manifest = read_json_file(reference_manifest_path, "Reference manifest")
    host_timing = read_json_file(host_timing_path, "Reference host timing JSON")
    manifest_sample_count = validate_manifest(manifest)
    reference_samples_int16, reference_wav_info = load_reference_wav(
        reference_wav_path,
        manifest,
    )

    if reference_samples_int16.size != manifest_sample_count:
        raise RuntimeError(
            f"Decoded reference sample count mismatch: {reference_samples_int16.size} != {manifest_sample_count}"
        )

    alignment = build_alignment_metadata(
        host_timing,
        reference_wav_info["sample_rate_hz"],
        args.ref_pre_roll,
    )
    validate_alignment_bounds(alignment, reference_wav_info["sample_count"])
    alignment["nominal_aligned_start_s"] = NOMINAL_PRE_ROLL_S
    alignment["nominal_aligned_duration_s"] = EXPECTED_FPGA_DURATION_S
    alignment["diagnostic_offsets_s"]["diagnostic_only"] = True
    alignment["diagnostic_offsets_s"]["ref_citya_observed_pre_roll_s"] = host_timing.get(
        "ref_citya_observed_pre_roll_s"
    )

    aligned_samples_int16 = reference_samples_int16[
        alignment["aligned_start_sample"] : alignment["aligned_end_sample"]
    ].copy()
    if aligned_samples_int16.size != alignment["aligned_sample_count"]:
        raise RuntimeError(
            f"Aligned reference sample count mismatch: {aligned_samples_int16.size} != {alignment['aligned_sample_count']}"
        )

    write_pcm16_wav(
        output_paths["aligned_wav"],
        aligned_samples_int16,
        reference_wav_info["sample_rate_hz"],
    )

    time_seconds, fpga_arm_enf_hz = load_arm_enf_csv(arm_enf_csv_path)
    hamming_window = get_reference_window(FRAME_SAMPLES)
    reference_enf_hz = np.empty(EXPECTED_FRAME_COUNT, dtype=np.float64)

    for frame_index in range(EXPECTED_FRAME_COUNT):
        start_sample = frame_index * REFERENCE_FRAME_SAMPLES
        end_sample = start_sample + REFERENCE_FRAME_SAMPLES
        frame_samples_int16 = aligned_samples_int16[start_sample:end_sample]
        if frame_samples_int16.size != REFERENCE_FRAME_SAMPLES:
            raise RuntimeError(
                f"Reference frame {frame_index} sample count mismatch: {frame_samples_int16.size} != {REFERENCE_FRAME_SAMPLES}"
            )
        reference_enf_hz[frame_index] = compute_reference_enf_hz(
            frame_samples_int16,
            hamming_window,
        )

    require_finite("Reference mains ENF", reference_enf_hz)

    write_reference_enf_csv(
        output_paths["reference_enf_csv"],
        reference_enf_hz,
        args.ref_pre_roll,
    )
    write_comparison_csv(
        output_paths["comparison_csv"],
        time_seconds,
        fpga_arm_enf_hz,
        reference_enf_hz,
    )

    metrics = compute_comparison_metrics(fpga_arm_enf_hz, reference_enf_hz)

    plot_comparison(
        output_paths["comparison_png"],
        int(manifest.get("request_id", 0)),
        time_seconds,
        fpga_arm_enf_hz,
        reference_enf_hz,
        metrics["pearson_r"],
    )

    metrics_payload = {
        "sequence_a": "ZB_CITYA",
        "sequence_b": "REF_CITYA",
        "difference_direction": "ZB_CITYA - REF_CITYA",
        "protocol": manifest.get("protocol"),
        "request_id": int(manifest.get("request_id", 0)),
        "alignment_method": alignment["alignment_method"],
        "reference_pre_roll_s": alignment["reference_pre_roll_s"],
        "aligned_start_sample": alignment["aligned_start_sample"],
        "aligned_end_sample": alignment["aligned_end_sample"],
        "aligned_start_seconds": alignment["aligned_start_seconds"],
        "aligned_duration_seconds": alignment["aligned_duration_seconds"],
        "aligned_sample_count": alignment["aligned_sample_count"],
        "expected_fpga_duration_s": alignment["expected_fpga_duration_s"],
        "frame_count": int(EXPECTED_FRAME_COUNT),
        "pearson_r": metrics["pearson_r"],
        "rmse_hz": metrics["rmse_hz"],
        "mae_hz": metrics["mae_hz"],
        "max_abs_error_hz": metrics["max_abs_error_hz"],
        "mean_signed_difference_hz": metrics["mean_signed_difference_hz"],
        "fpga_min_hz": metrics["sequence_a_min_hz"],
        "fpga_max_hz": metrics["sequence_a_max_hz"],
        "reference_min_hz": metrics["sequence_b_min_hz"],
        "reference_max_hz": metrics["sequence_b_max_hz"],
        "fpga_enf_csv": arm_enf_csv_path.name,
        "reference_enf_csv": output_paths["reference_enf_csv"].name,
        "reference_wav_220s": reference_wav_path.name,
        "reference_wav_aligned_200s": output_paths["aligned_wav"].name,
        "reference_manifest_json": reference_manifest_path.name,
        "reference_host_timing_json": host_timing_path.name,
        "comparison_csv": output_paths["comparison_csv"].name,
        "comparison_plot_png": output_paths["comparison_png"].name,
        "comparison_plot_svg": output_paths["comparison_svg"].name,
        "reference_sample_rate_hz": reference_wav_info["sample_rate_hz"],
        "reference_sample_count_220s": reference_wav_info["sample_count"],
        "reference_samples_per_frame": REFERENCE_FRAME_SAMPLES,
        "resampled_samples_per_frame": FRAME_SAMPLES,
        "estimator_constants": {
            "output_sample_rate_hz": RESAMPLED_SAMPLE_RATE_HZ,
            "frame_duration_s": FRAME_DURATION_S,
            "frame_samples": FRAME_SAMPLES,
            "fft_length": FFT_LENGTH,
            "normalization_peak": NORMALIZATION_PEAK,
            "search_bin_first": SEARCH_BIN_FIRST,
            "search_bin_count": SEARCH_BIN_COUNT,
            "power_exponent": POWER_EXPONENT,
        },
        "diagnostic_offsets_s": alignment["diagnostic_offsets_s"],
    }
    write_json_atomic(output_paths["metrics_json"], metrics_payload)
    process_three_sources(
        args, output_paths, manifest, host_timing, alignment, time_seconds,
        fpga_arm_enf_hz, reference_enf_hz, metrics, metrics_payload
    )

    require_nonempty_file(output_paths["aligned_wav"], "Aligned reference WAV")
    require_nonempty_file(output_paths["reference_enf_csv"], "Reference ENF CSV")
    require_nonempty_file(output_paths["comparison_csv"], "FPGA-vs-reference comparison CSV")
    require_nonempty_file(output_paths["metrics_json"], "FPGA-vs-reference metrics JSON")
    require_nonempty_file(output_paths["comparison_png"], "FPGA-vs-reference correlation plot")

    print_processing_summary(
        reference_wav_name=reference_wav_path.name,
        sample_rate_hz=reference_wav_info["sample_rate_hz"],
        alignment=alignment,
        frame_count=EXPECTED_FRAME_COUNT,
        metrics=metrics,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
