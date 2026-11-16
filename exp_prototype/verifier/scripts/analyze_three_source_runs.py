"""Aggregate explicitly selected saved three-source runs without hardware.

Reads verifier logs, optional metrics JSON, and frame CSVs; writes aggregate
tables and diagnostic plots to the selected output directory. Workflow PASS
and pairwise numerical agreement do not constitute geographic acceptance or
independent authentication of the recorded measurements.
"""

# STEP_1: Dependencies and configuration
from __future__ import annotations

import argparse
import csv
from datetime import datetime
import json
import math
from pathlib import Path
import re
import statistics

DEFAULT_ROOT = Path(__file__).resolve().parents[2] / "fpga_enf_data"
PASS_MARKER = (
    "[MULTI-SOURCE ENF PROCESSING] Acquisition and numerical comparison workflow: PASS"
)
PAIRS = (
    ("ZedBoard vs REF_CITYA", "zb_ref_citya", "zedboard_vs_ref_citya",
     "zedboard_minus_ref_citya", "ZedBoard - REF_CITYA"),
    ("ZedBoard vs REF_PICO_CITYA", "zb_pico", "zedboard_vs_ref_pico_citya",
     "zedboard_minus_ref_pico_citya", "ZedBoard - REF_PICO_CITYA"),
    ("REF_CITYA vs REF_PICO_CITYA", "ref_citya_pico", "ref_citya_vs_ref_pico_citya",
     "ref_citya_minus_ref_pico_citya", "REF_CITYA - REF_PICO_CITYA"),
)
METRICS = {
    "Pearson correlation": "pearson_r",
    "RMSE": "rmse_hz",
    "Mean absolute error": "mae_hz",
    "Maximum absolute error": "max_abs_error_hz",
    "Mean signed difference": "mean_signed_difference_hz",
}
TIMING_FIELDS = (
    "enf_frame_mean_ms", "enf_frame_min_ms", "enf_frame_max_ms",
    "sha256_ecdsa_ms", "end_to_end_verification_s",
)
COLUMNS = (
    ["experiment_date", "request_id", "log_path"]
    + [f"{pair[1]}_{metric}" for pair in PAIRS for metric in METRICS.values()]
    + list(TIMING_FIELDS)
    + ["offset_closure_error_hz", "offset_closure_error_mhz"]
    + [f"{pair[1]}_offset_ppm" for pair in PAIRS]
    + ["metrics_json_crosscheck"]
)
SKIP_COLUMNS = ["experiment_date", "request_directory", "log_path", "reason"]
NUMBER = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
REQUEST_DIRECTORY = re.compile(r"reqid_(\d+)")


class InvalidRun(ValueError):
    """A discovered run cannot supply a complete, unambiguous numerical row."""


# STEP_2: Saved numerical input validation
def finite_number(text: str, description: str, unit: str = "") -> float:
    """Parse one finite numeric metric with its optional unit, rejecting malformed log text."""
    suffix = rf"(?:\s*{re.escape(unit)})?" if unit else ""
    match = re.fullmatch(rf"\s*({NUMBER}){suffix}\s*", text)
    if not match:
        raise InvalidRun(f"malformed numeric metric: {description}: {text!r}")
    value = float(match.group(1))
    if not math.isfinite(value):
        raise InvalidRun(f"non-finite numeric metric: {description}")
    return value


def parse_pairwise(lines: list[str]) -> dict[str, float]:
    """Extract each required pairwise numeric metric from completed-run log sections."""
    values = {}
    pair_names = {pair[0] for pair in PAIRS}
    for name, prefix, *_ in PAIRS:
        starts = [i for i, line in enumerate(lines) if line.strip() == name]
        if len(starts) != 1:
            raise InvalidRun(f"pairwise block {'missing' if not starts else 'duplicated'}: {name}")
        found = {}
        for line in lines[starts[0] + 1:]:
            stripped = line.strip()
            if stripped in pair_names or stripped.startswith("["):
                break
            if not stripped or set(stripped) == {"="}:
                continue
            if ":" not in stripped:
                break
            label, text = (part.strip() for part in stripped.split(":", 1))
            if label not in METRICS:
                break
            field = METRICS[label]
            if field in found:
                raise InvalidRun(f"duplicate metric: {name}: {label}")
            value = finite_number(text, f"{name}: {label}", "" if field == "pearson_r" else "Hz")
            if field == "pearson_r" and not -1 <= value <= 1:
                raise InvalidRun(f"Pearson correlation outside [-1, 1]: {name}")
            if field not in ("pearson_r", "mean_signed_difference_hz") and value < 0:
                raise InvalidRun(f"negative error magnitude: {name}: {label}")
            found[field] = value
        missing = set(METRICS.values()) - found.keys()
        if missing:
            raise InvalidRun(f"incomplete pairwise block: {name}: missing {', '.join(sorted(missing))}")
        values.update({f"{prefix}_{key}": value for key, value in found.items()})
    return values


def parse_timing(text: str) -> tuple[dict, list[str]]:
    """Return optional timing diagnostics and warnings; absent or ambiguous values remain unavailable."""
    values = dict.fromkeys(TIMING_FIELDS)
    warnings = []

    def read(field, matches, unit):
        if not matches:
            return
        if len(matches) != 1:
            warnings.append(f"duplicate optional timing: {field}; stored null")
            return
        try:
            value = finite_number(matches[0], field, unit)
            if value < 0:
                raise InvalidRun(f"negative optional timing: {field}")
            values[field] = value
        except InvalidRun as exc:
            warnings.append(f"{exc}; stored null")

    blocks = re.findall(
        r"(?m)^\s*ENF processing per 8-s frame:\s*\n((?:[ \t]+(?:mean|min|max)\s*:[^\n]*\n?)+)",
        text,
    )
    for label in ("mean", "min", "max"):
        matches = [m for block in blocks for m in re.findall(
            rf"(?m)^[ \t]*{label}\s*:\s*([^\n]+)", block
        )]
        read(f"enf_frame_{label}_ms", matches, "ms")
    read("sha256_ecdsa_ms", re.findall(
        r"(?m)^[ \t]*SHA-256 \+ ECDSA P-256:\s*([^\n]+)", text
    ), "ms")
    read("end_to_end_verification_s", re.findall(
        r"(?m)^\[ATTESTATION DECISION\]\s*End-to-end verification time\s*:\s*([^\n]+)", text
    ), "s")
    return values, warnings


def crosscheck_json(path: Path, row: dict) -> tuple[str, list[str]]:
    """Cross-check logged metrics against optional saved JSON; return status and warnings."""
    if not path.exists():
        return "NOT_AVAILABLE", []
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict) or data.get("request_id") != row["request_id"]:
            raise ValueError("metrics JSON request ID mismatch or invalid object")
        differences = []
        for _, prefix, json_key, *_ in PAIRS:
            pair = data["pairwise"][json_key]
            for metric in METRICS.values():
                value = pair[metric]
                if type(value) not in (int, float) or not math.isfinite(value):
                    raise ValueError(f"invalid JSON metric: {json_key}.{metric}")
                if not math.isclose(row[f"{prefix}_{metric}"], value, rel_tol=1e-12, abs_tol=1e-14):
                    differences.append(f"{json_key}.{metric}")
        return ("FAIL", differences) if differences else ("PASS", [])
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, OverflowError) as exc:
        return "FAIL", [str(exc)]


# STEP_3: Run selection and metric loading
def analyze_run(directory: Path) -> tuple[dict, list[str]]:
    """Validate a completed run's log and optional JSON, returning its metrics and warnings."""
    log = directory / "enf_verifier.log"
    request_match = REQUEST_DIRECTORY.fullmatch(directory.name)
    if not request_match:
        raise InvalidRun("malformed request directory")
    # Dates are provenance from the saved transaction, not directory selectors.
    date = ""
    timing_paths = [p for p in (directory / "data").glob("*_host_timing.json")
                    if p.name != "pico_ref_host_timing.json"]
    if len(timing_paths) == 1:
        try:
            timing = json.loads(timing_paths[0].read_text(encoding="utf-8-sig"))
            date = datetime.fromisoformat(timing["fpga_get_send_utc"]).strftime("%Y_%m_%d")
        except (OSError, ValueError, TypeError, KeyError):
            pass
    request_id = int(request_match.group(1))
    if not log.is_file():
        raise InvalidRun("missing log")
    try:
        text = log.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as exc:
        raise InvalidRun(f"unreadable log: {exc}") from exc
    lines = text.splitlines()
    ids = re.findall(r"(?m)^\[BOARD ATTESTATION\]\s*Request ID:\s*(\d+)\s*$", text)
    if not ids:
        raise InvalidRun("request ID missing from log")
    if len(ids) != 1:
        raise InvalidRun("multiple request ID records in log")
    if int(ids[0]) != request_id:
        raise InvalidRun(f"request ID mismatch: directory={request_id}, log={ids[0]}")
    if any(re.search(r"^\[[^]]+\]\s*FAIL(?:\s|:|$)", line) for line in lines):
        raise InvalidRun("failed run: explicit FAIL record")
    if sum(line.strip() == PASS_MARKER for line in lines) != 1:
        raise InvalidRun("workflow PASS marker missing or duplicated (board-only or incomplete run)")
    row = {"experiment_date": date, "request_id": request_id, "log_path": str(log.resolve())}
    row.update(parse_pairwise(lines))
    timing, warnings = parse_timing(text)
    row.update(timing)
    offsets = [row[f"{pair[1]}_mean_signed_difference_hz"] for pair in PAIRS]
    closure = offsets[1] - offsets[2] - offsets[0]
    row["offset_closure_error_hz"] = closure
    row["offset_closure_error_mhz"] = closure * 1000.0
    for pair, offset in zip(PAIRS, offsets):
        row[f"{pair[1]}_offset_ppm"] = offset / 60.0 * 1e6
    status, differences = crosscheck_json(directory / "data" / "three_source_enf_metrics.json", row)
    row["metrics_json_crosscheck"] = status
    if differences:
        warnings.append("metrics JSON cross-check FAIL: " + "; ".join(differences))
    return row, warnings


# STEP_4: Aggregate statistics
def offset_statistics(values: list[float]) -> dict:
    """Summarize signed offsets in Hz and mHz using sample standard deviation when defined."""
    count = len(values)
    hz = {
        "mean": statistics.mean(values) if count else None,
        "std": statistics.stdev(values) if count >= 2 else None,
        "min": min(values) if count else None,
        "max": max(values) if count else None,
        "median": statistics.median(values) if count else None,
    }
    result = {"count": count}
    for key, value in hz.items():
        result[f"{key}_hz"] = value
        result[f"{key}_mhz"] = None if value is None else value * 1000.0
    return result


def correlation_statistics(values: list[float]) -> dict:
    """Return count, mean, sample deviation, and extrema; undefined statistics are None."""
    count = len(values)
    return {
        "count": count,
        "mean": statistics.mean(values) if count else None,
        "std": statistics.stdev(values) if count >= 2 else None,
        "min": min(values) if count else None,
        "max": max(values) if count else None,
        "median": statistics.median(values) if count else None,
        "standard_deviation_ddof": 1,
    }


def discover_runs(root: Path) -> list[Path]:
    """Find request directories immediately below the explicit input root."""
    # One explicit input directory; never recurse into other experiments.
    if not root.is_dir():
        raise ValueError(f"Input directory does not exist: {root}")
    return sorted((p for p in root.glob("reqid_*") if p.is_dir()),
                  key=lambda p: (int(p.name[6:]) if p.name[6:].isdigit() else -1, p.name))


def select_runs(runs: list[Path], request_ids: list[int]) -> list[Path]:
    """Select distinct positive request IDs and reject missing or ambiguous directories."""
    if not request_ids or any(rid <= 0 for rid in request_ids) or len(set(request_ids)) != len(request_ids):
        raise ValueError("Request IDs must be distinct positive integers")
    available = {int(p.name[6:]): p for p in runs if REQUEST_DIRECTORY.fullmatch(p.name)}
    if len(available) != sum(bool(REQUEST_DIRECTORY.fullmatch(p.name)) for p in runs):
        raise ValueError("Ambiguous numeric request directories")
    missing = set(request_ids) - available.keys()
    if missing:
        raise ValueError(f"Requested run directories missing: {sorted(missing)}")
    return [available[rid] for rid in sorted(request_ids)]


def validate_output_directory(output: Path, runs: list[Path]) -> None:
    """Reject output paths inside selected measurement directories."""
    for run in runs:
        if output == run.resolve() or run.resolve() in output.parents:
            raise ValueError("Output directory cannot be inside an experiment run")


def write_csv(path: Path, columns: list[str], rows: list[dict]) -> None:
    """Write the supplied rows using the declared CSV columns."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    if path.is_symlink() or temporary.is_symlink():
        raise ValueError(f"Refusing to write through an output symlink: {path}")
    with temporary.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        # Python's float repr preserves round-trip precision; None becomes blank.
        writer.writerows(rows)
    temporary.replace(path)


# The original log-derived summaries remain independent of frame availability.
FRAME_FILES = (
    ("fpga_vs_mains_enf_comparison.csv", "fpga_arm_enf_hz", "mains_reference_enf_hz"),
    ("fpga_vs_pico_enf_comparison.csv", "zb_citya_enf_hz", "ref_pico_citya_enf_hz"),
    ("mains_vs_pico_enf_comparison.csv", "ref_citya_enf_hz", "ref_pico_citya_enf_hz"),
)
FRAME_COLUMNS = [
    "experiment_date", "request_id", "frame_index", "frame_start_seconds", "pair",
    "sequence_a_enf_hz", "sequence_b_enf_hz", "mean_pair_enf_hz",
    "signed_difference_hz", "signed_difference_mhz",
    "absolute_difference_hz", "absolute_difference_mhz",
]
WITHIN_COLUMNS = [
    "experiment_date", "request_id", "pair",
    "mean_difference_hz", "mean_difference_mhz", "std_difference_hz", "std_difference_mhz",
    "min_difference_hz", "min_difference_mhz", "max_difference_hz", "max_difference_mhz",
    "range_difference_hz", "range_difference_mhz",
]
DRIFT_COLUMNS = [
    "experiment_date", "request_id", "pair", "slope_hz_per_second",
    "slope_mhz_per_second", "intercept_hz", "pearson_r", "r_squared",
]
FRAME_STATUS_COLUMNS = [
    "experiment_date", "request_id", "log_path", "frame_analysis", "reason",
]


def linear_regression(x, y):
    """Centered unweighted OLS with intercept; undefined statistics are null."""
    if len(x) != len(y) or any(not math.isfinite(v) for v in (*x, *y)):
        raise ValueError("Regression inputs must have equal length and finite values")
    result = dict(n=len(x), slope=None, intercept=None, pearson_r=None, r_squared=None)
    if len(x) < 2:
        return {**result, "status": "insufficient_observations"}
    mx, my = statistics.mean(x), statistics.mean(y)
    dx, dy = [v-mx for v in x], [v-my for v in y]
    xx, yy = math.fsum(v*v for v in dx), math.fsum(v*v for v in dy)
    if xx == 0:
        return {**result, "status": "constant_predictor"}
    xy = math.fsum(a*b for a, b in zip(dx, dy))
    slope = xy / xx
    result.update(slope=slope, intercept=my-slope*mx)
    if yy == 0:
        return {**result, "status": "constant_response"}
    r = max(-1.0, min(1.0, xy / math.sqrt(xx * yy)))
    result.update(pearson_r=r, r_squared=r*r, status="ok")
    if any(not math.isfinite(v) for v in result.values() if isinstance(v, (int, float))):
        raise ValueError("Non-finite regression result")
    return result


def scaled(value, factor):
    return None if value is None else value * factor


def load_run_frames(run):
    """Load saved frame comparisons and validate their relationship to aggregate run metrics."""
    rows = []
    data_dir = Path(run["log_path"]).parent / "data"
    for pair, (filename, column_a, column_b) in zip(PAIRS, FRAME_FILES):
        path = data_dir / filename
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            fields = reader.fieldnames or []
            # Generic columns are also accepted when their declared order is A-B.
            if column_a not in fields or column_b not in fields:
                column_a, column_b = "sequence_a_enf_hz", "sequence_b_enf_hz"
            required = ["frame_index", "frame_start_seconds", column_a, column_b,
                        "difference_hz", "absolute_difference_hz"]
            if len(set(fields)) != len(fields) or not set(required).issubset(fields):
                raise ValueError(f"{filename}: missing or duplicate columns")
            records = list(reader)
        if len(records) != 25:
            raise ValueError(f"{filename}: expected 25 rows, found {len(records)}")
        differences = []
        for i, record in enumerate(records):
            if int(record["frame_index"]) != i:
                raise ValueError(f"{filename}: frame index mismatch at row {i}")
            values = {key: finite_number(record[key], f"{filename} row {i} {key}")
                      for key in required if key != "frame_index"}
            t, a, b = values["frame_start_seconds"], values[column_a], values[column_b]
            d, ad = values["difference_hz"], values["absolute_difference_hz"]
            if not math.isclose(t, i * 8.0, rel_tol=0, abs_tol=1e-9):
                raise ValueError(f"{filename}: frame time mismatch at row {i}")
            if not math.isclose(d, a-b, rel_tol=1e-12, abs_tol=1e-12):
                raise ValueError(f"{filename}: signed A-B difference mismatch at row {i}")
            if ad < 0 or not math.isclose(ad, abs(d), rel_tol=1e-12, abs_tol=1e-12):
                raise ValueError(f"{filename}: absolute difference mismatch at row {i}")
            differences.append(d)
            rows.append({
                "experiment_date": run["experiment_date"], "request_id": run["request_id"],
                "frame_index": i, "frame_start_seconds": t, "pair": pair[3],
                "sequence_a_enf_hz": a, "sequence_b_enf_hz": b,
                "mean_pair_enf_hz": (a+b)/2,
                "signed_difference_hz": d, "signed_difference_mhz": d*1000,
                "absolute_difference_hz": ad, "absolute_difference_mhz": ad*1000,
            })
        if not math.isclose(statistics.mean(differences),
                            run[f"{pair[1]}_mean_signed_difference_hz"],
                            rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f"{filename}: frame mean disagrees with log mean")
    # Check that each source has the same samples in its two comparison files.
    for i in range(25):
        ar, br, cr = rows[i], rows[25+i], rows[50+i]
        for a, b in ((ar["sequence_a_enf_hz"], br["sequence_a_enf_hz"]),
                     (ar["sequence_b_enf_hz"], cr["sequence_a_enf_hz"]),
                     (br["sequence_b_enf_hz"], cr["sequence_b_enf_hz"])):
            if not math.isclose(a, b, rel_tol=0, abs_tol=1e-12):
                raise ValueError(f"Source frequency differs between pair CSVs at frame {i}")
    return rows


def run_timestamp(run):
    """Use only an existing timezone-aware verifier preparation timestamp."""
    candidates, issues = [], []
    for path in sorted((Path(run["log_path"]).parent / "data").glob("*host_timing.json")):
        if path.name == "pico_ref_host_timing.json":
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
            if payload.get("request_id") != run["request_id"]:
                raise ValueError("request ID mismatch")
            value = payload.get("host_ref_prepare_send_utc")
            if value is None:
                continue
            stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if stamp.tzinfo is None or stamp.utcoffset() is None:
                raise ValueError("timestamp lacks timezone")
            candidates.append((stamp, str(path)))
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            issues.append(f"{path.name}: {exc}")
    if len(candidates) == 1:
        return candidates[0][0], candidates[0][1], issues
    if len(candidates) > 1:
        issues.append("multiple preparation timestamps; no timestamp selected")
    return None, None, issues


def write_diagnostic_json(path, payload):
    """Write finite diagnostic JSON atomically, refusing destination or temporary symlinks."""
    temporary = path.with_suffix(".json.tmp")
    if path.is_symlink() or temporary.is_symlink():
        raise ValueError(f"Refusing output symlink: {path}")
    temporary.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def save_diagnostic_plot(fig, output, basename, plt):
    """Save PNG/SVG diagnostics, refusing output symlinks."""
    png, svg = output / f"{basename}.png", output / f"{basename}.svg"
    if png.is_symlink() or svg.is_symlink():
        plt.close(fig)
        raise ValueError(f"Refusing plot output symlink: {basename}")
    fig.tight_layout()
    try:
        fig.savefig(png, dpi=300)
        fig.savefig(svg)
    finally:
        plt.close(fig)
    for path in (png, svg):
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Plot missing or empty: {path}")
    return {"png": png.name, "svg": svg.name}


def diagnostic_plots(output, frames, ordered, frequency, across):
    """Write pairwise offset and frequency diagnostics from the supplied saved-frame summaries."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plots = {}
    def fmt(value):
        return "N/A" if value is None else f"{value:.5g}"
    for pair in PAIRS:
        _, prefix, _, key, label = pair
        observations = [r for r in frames if r["pair"] == key]
        reg = frequency[key]
        fig, ax = plt.subplots(figsize=(8, 4.8))
        x = [r["mean_pair_enf_hz"] for r in observations]
        ax.scatter(x, [r["signed_difference_mhz"] for r in observations],
                   s=16, alpha=0.65, label="Frame observations")
        if x and reg["slope_hz_per_hz"] is not None:
            limits = [min(x), max(x)]
            ax.plot(limits, [1000*(reg["intercept_hz"] + reg["slope_hz_per_hz"]*v)
                             for v in limits], color="black", label="Least-squares fit")
        ax.set(xlabel="Mean pair ENF frequency (Hz)", ylabel="Signed difference (mHz)",
               title=label)
        ax.text(0.02, 0.98, f"Slope: {fmt(reg['slope_ppm'])} ppm\n"
                f"r: {fmt(reg['pearson_r'])}   R^2: {fmt(reg['r_squared'])}",
                transform=ax.transAxes, va="top")
        ax.grid(alpha=0.25)
        if x:
            ax.legend(loc="lower right")
        plots[f"offset_vs_frequency_{prefix}"] = save_diagnostic_plot(
            fig, output, f"offset_vs_frequency_{prefix}", plt)
        fig, ax = plt.subplots(figsize=(8, 4.8))
        for run in ordered:
            series = [r for r in observations if
                      (r["experiment_date"], r["request_id"]) ==
                      (run["experiment_date"], run["request_id"])]
            if series:
                ax.plot([r["frame_start_seconds"] for r in series],
                        [r["signed_difference_mhz"] for r in series],
                        linewidth=0.8, alpha=0.45)
        if observations:
            mean_trace = [statistics.mean(r["signed_difference_mhz"] for r in observations
                                          if r["frame_index"] == i) for i in range(25)]
            ax.plot(range(0, 200, 8), mean_trace, color="black",
                    linewidth=2.2, label="Mean across runs")
            ax.legend()
        ax.set(xlabel="Frame start time (s)", ylabel="Signed difference (mHz)",
               title=label, xlim=(0, 192))
        ax.grid(alpha=0.25)
        plots[f"offset_vs_frame_time_{prefix}"] = save_diagnostic_plot(
            fig, output, f"offset_vs_frame_time_{prefix}", plt)
        reg = across[key]
        fig, ax = plt.subplots(figsize=(8, 4.8))
        x = list(range(len(ordered)))
        y = [1000 * r["offsets"][key] for r in ordered]
        ax.plot(x, y, "o-", linewidth=1, label="Run mean")
        if reg["slope_hz_per_run"] is not None:
            ax.plot(x, [1000*(reg["intercept_hz"] + reg["slope_hz_per_run"]*v) for v in x],
                    "--", color="black", label="Least-squares trend")
        ax.set(xlabel="Run index", ylabel="Run mean signed difference (mHz)", title=label)
        ax.text(0.02, 0.98, f"Slope: {fmt(reg['slope_mhz_per_run'])} mHz/run\n"
                f"r: {fmt(reg['pearson_r'])}   R^2: {fmt(reg['r_squared'])}",
                transform=ax.transAxes, va="top")
        ax.grid(alpha=0.25)
        ax.legend(loc="lower right")
        plots[f"run_mean_offset_{prefix}"] = save_diagnostic_plot(
            fig, output, f"run_mean_offset_{prefix}", plt)
    fig, ax = plt.subplots(figsize=(9, 5))
    for pair in PAIRS:
        ax.plot(range(len(ordered)), [r["offsets"][pair[3]]*1000 for r in ordered],
                "o-", markersize=4, linewidth=1.4, label=pair[4])
    ax.set(xlabel="Run index", ylabel="Run mean signed difference (mHz)",
           title="Run-level mean offsets")
    ax.grid(alpha=0.25)
    ax.legend()
    plots["run_mean_offsets_all_pairs"] = save_diagnostic_plot(
        fig, output, "run_mean_offsets_all_pairs", plt)
    return plots


# STEP_5: Frequency-offset and drift diagnostics
def analyze_frame_diagnostics(runs, output):
    """Validate saved frames and report within-run offsets, drift, and across-run diagnostics."""
    frames, within, drifts, statuses, ordered, timestamp_issues = [], [], [], [], [], []
    for run in runs:
        status = {k: run[k] for k in ("experiment_date", "request_id", "log_path")}
        means = {}
        try:
            run_frames = load_run_frames(run)
            run_within, run_drifts = [], []
            for pair in PAIRS:
                series = [r for r in run_frames if r["pair"] == pair[3]]
                differences = [r["signed_difference_hz"] for r in series]
                mean, std = statistics.mean(differences), statistics.stdev(differences)
                low, high = min(differences), max(differences)
                means[pair[3]] = mean
                identity = {**{k: run[k] for k in ("experiment_date", "request_id")}, "pair": pair[3]}
                stats = dict(identity)
                for name, value in (("mean",mean),("std",std),("min",low),("max",high),("range",high-low)):
                    stats[f"{name}_difference_hz"] = value
                    stats[f"{name}_difference_mhz"] = value*1000
                run_within.append(stats)
                reg = linear_regression([r["frame_start_seconds"] for r in series], differences)
                run_drifts.append({**identity, "slope_hz_per_second": reg["slope"],
                               "slope_mhz_per_second": scaled(reg["slope"],1000),
                               "intercept_hz": reg["intercept"],
                               "pearson_r": reg["pearson_r"], "r_squared": reg["r_squared"]})
            frames.extend(run_frames)
            within.extend(run_within)
            drifts.extend(run_drifts)
            status.update(frame_analysis="AVAILABLE", reason="")
        except (OSError, UnicodeError, ValueError, KeyError, TypeError, csv.Error) as exc:
            means.clear()
            status.update(frame_analysis="UNAVAILABLE", reason=str(exc))
        statuses.append(status)
        stamp, source, issues = run_timestamp(run)
        timestamp_issues.extend({"log_path": run["log_path"], "reason": issue} for issue in issues)
        ordered.append({
            "experiment_date": run["experiment_date"], "request_id": run["request_id"],
            "timestamp": stamp.isoformat() if stamp else None,
            "timestamp_source": source,
            "offset_source": "frame CSV means" if status["frame_analysis"] == "AVAILABLE" else "log means",
            "offsets": {pair[3]: means.get(pair[3], run[f"{pair[1]}_mean_signed_difference_hz"])
                        for pair in PAIRS},
        })
    use_timestamps = bool(ordered) and all(r["timestamp"] for r in ordered)
    ordered.sort(key=lambda r: (
        datetime.fromisoformat(r["timestamp"]) if use_timestamps else r["experiment_date"],
        r["experiment_date"], r["request_id"]))
    for i, run in enumerate(ordered):
        run["run_index"] = i
    frequency, across, diagnostics = {}, {}, {}
    for pair in PAIRS:
        key = pair[3]
        series = [r for r in frames if r["pair"] == key]
        reg = linear_regression([r["mean_pair_enf_hz"] for r in series],
                                [r["signed_difference_hz"] for r in series])
        frequency[key] = {
            "n": reg["n"], "slope_hz_per_hz": reg["slope"],
            "slope_ppm": scaled(reg["slope"],1e6),
            "intercept_hz": reg["intercept"], "intercept_mhz": scaled(reg["intercept"],1000),
            "pearson_r": reg["pearson_r"], "r_squared": reg["r_squared"], "status": reg["status"],
        }
        reg = linear_regression(list(range(len(ordered))), [r["offsets"][key] for r in ordered])
        timed = [r for r in ordered if r["timestamp"]]
        first = min((datetime.fromisoformat(r["timestamp"]) for r in timed), default=None)
        hours = [(datetime.fromisoformat(r["timestamp"])-first).total_seconds()/3600 for r in timed]
        hourly = linear_regression(hours, [r["offsets"][key] for r in timed])
        across[key] = {
            "number_of_runs": len(ordered), "slope_hz_per_run": reg["slope"],
            "slope_mhz_per_run": scaled(reg["slope"],1000), "intercept_hz": reg["intercept"],
            "pearson_r": reg["pearson_r"], "r_squared": reg["r_squared"], "status": reg["status"],
            "timestamped_run_count": len(timed),
            "slope_hz_per_hour": hourly["slope"], "slope_mhz_per_hour": scaled(hourly["slope"],1000),
            "hourly_pearson_r": hourly["pearson_r"], "hourly_r_squared": hourly["r_squared"],
            "hourly_status": hourly["status"],
        }
        stds = [r["std_difference_mhz"] for r in within if r["pair"] == key]
        slopes = [r["slope_mhz_per_second"] for r in drifts if r["pair"] == key
                  and r["slope_mhz_per_second"] is not None]
        diagnostics[key] = {
            "within_run": {
                "mean_of_run_std_mhz": statistics.mean(stds) if stds else None,
                "median_run_std_mhz": statistics.median(stds) if stds else None,
                "max_run_std_mhz": max(stds) if stds else None,
            },
            "offset_vs_frequency": frequency[key],
            "within_run_time_drift": {
                "mean_slope_mhz_per_s": statistics.mean(slopes) if slopes else None,
                "std_slope_mhz_per_s": statistics.stdev(slopes) if len(slopes)>1 else None,
                "median_slope_mhz_per_s": statistics.median(slopes) if slopes else None,
            },
            "across_run_drift": across[key],
        }
    write_csv(output/"three_source_frame_offsets.csv", FRAME_COLUMNS, frames)
    write_csv(output/"three_source_within_run_offset_stats.csv", WITHIN_COLUMNS, within)
    write_csv(output/"three_source_within_run_drift.csv", DRIFT_COLUMNS, drifts)
    write_csv(output/"three_source_frame_run_status.csv", FRAME_STATUS_COLUMNS, statuses)
    write_diagnostic_json(output/"three_source_offset_vs_frequency.json", {
        "model": "signed_difference_hz = intercept_hz + slope_hz_per_hz * mean_pair_enf_hz",
        "method": "pooled unweighted ordinary least squares with intercept",
        "pairs": frequency,
    })
    write_diagnostic_json(output/"three_source_across_run_drift.json", {
        "ordering": "verifier UTC preparation timestamp" if use_timestamps else "experiment_date, request_id",
        "run_order": ordered, "timestamp_issues": timestamp_issues, "pairs": across,
    })
    plots = diagnostic_plots(output, frames, ordered, frequency, across)
    valid = sum(r["frame_analysis"] == "AVAILABLE" for r in statuses)
    write_diagnostic_json(output/"three_source_offset_diagnostics.json", {
        "valid_frame_runs": valid, "valid_log_runs": len(runs), "frames_per_run":25,
        "total_frame_pair_rows":len(frames), "standard_deviation_ddof":1,
        "regression_method":"unweighted OLS with intercept; pooled frames are descriptive observations",
        "undefined_statistics":"null for insufficient observations/zero predictor variance; r and R^2 null for zero response variance",
        "frame_validation_tolerance":{"relative":1e-12,"absolute_hz":1e-12},
        "units":{"mhz":"mHz (millihertz)","slope_ppm":"frequency slope * 1e6; diagnostic only"},
        "frame_run_status":statuses, "pairs":diagnostics, "plots":plots,
        "timestamp_issues":timestamp_issues,
    })
    print(f"\nOffset diagnostics\n==================\nValid frame runs: {valid}/{len(runs)}")
    def fmt(value):
        return "N/A" if value is None else format(value, ".10g")
    for pair in PAIRS:
        d = diagnostics[pair[3]]
        print(f"\n{pair[4]}")
        print(f"  pooled frame count          : {d['offset_vs_frequency']['n']}")
        print(f"  mean within-run std         : {fmt(d['within_run']['mean_of_run_std_mhz'])} mHz")
        print(f"  offset-vs-frequency slope   : {fmt(d['offset_vs_frequency']['slope_ppm'])} ppm")
        print(f"  offset-vs-frequency r / R^2 : {fmt(d['offset_vs_frequency']['pearson_r'])} / {fmt(d['offset_vs_frequency']['r_squared'])}")
        print(f"  mean within-run drift slope : {fmt(d['within_run_time_drift']['mean_slope_mhz_per_s'])} mHz/s")
        print(f"  across-run slope            : {fmt(d['across_run_drift']['slope_mhz_per_run'])} mHz/run")
    if valid < len(runs):
        print("Unavailable frame data: see three_source_frame_run_status.csv")


# STEP_6: Analysis CLI and output
def main(argv=None) -> int:
    """Aggregate explicitly requested saved runs and write tables and frame diagnostics."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", "--input-dir", dest="root", type=Path, default=DEFAULT_ROOT,
                        help="Directory directly containing reqid_N groups; default: fpga_enf_data/.")
    parser.add_argument("--request-ids", type=int, nargs="+", required=True,
                        help="Explicit numeric request IDs to analyze; no automatic cohort selection.")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args(argv)
    root = args.root.expanduser().resolve()
    if not root.is_dir():
        parser.error(f"Root directory does not exist: {root}")
    output = (args.output_dir or root / "analysis").expanduser().resolve()
    discovered_runs = discover_runs(root)
    try:
        runs = select_runs(discovered_runs, args.request_ids)
    except ValueError as exc:
        parser.error(str(exc))
    validate_output_directory(output, discovered_runs)
    rows, skips, warnings = [], [], []
    for run in runs:
        try:
            row, notices = analyze_run(run)
            rows.append(row)
            warnings.extend({"log_path": row["log_path"], "reason": notice} for notice in notices)
        except InvalidRun as exc:
            skips.append({
                "experiment_date": "",
                "request_directory": str(run.resolve()),
                "log_path": str((run / "enf_verifier.log").resolve()),
                "reason": str(exc),
            })
    summary = {
        "root": str(root),
        "experiment_directory": str(root),
        "request_id_count_config": len(args.request_ids),
        "evaluated_request_ids": [run.name.removeprefix("reqid_") for run in runs],
        "experiment_folder_count": len({run.parent for run in runs}),
        "discovered_run_count": len(discovered_runs),
        "selected_run_count": len(runs),
        "valid_run_count": len(rows),
        "skipped_run_count": len(skips),
        "standard_deviation_ddof": 1,
        "units": {"hz": "Hz", "mhz": "mHz (millihertz, not megahertz)"},
        "ppm_diagnostic": "approximate frequency offset relative to nominal 60 Hz; diagnostic only",
        "offset_statistics": {
            pair[3]: offset_statistics([row[f"{pair[1]}_mean_signed_difference_hz"] for row in rows])
            for pair in PAIRS
        },
        "correlation_statistics": {
            pair[3]: correlation_statistics([row[f"{pair[1]}_pearson_r"] for row in rows])
            for pair in PAIRS
        },
        "closure_error_definition": "(ZedBoard - Pico) - (REF_CITYA - Pico) - (ZedBoard - REF_CITYA)",
        "closure_error_statistics": offset_statistics([row["offset_closure_error_hz"] for row in rows]),
        "metrics_json_crosscheck": {
            "primary_source": "enf_verifier.log",
            "relative_tolerance": 1e-12, "absolute_tolerance": 1e-14,
            "failure_policy": "flag discrepancy; retain log-derived values and valid-log run",
            **{status: sum(row["metrics_json_crosscheck"] == status for row in rows)
               for status in ("PASS", "FAIL", "NOT_AVAILABLE")},
        },
        "warnings": warnings,
    }
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "three_source_run_metrics.csv", COLUMNS, rows)
    write_csv(output / "three_source_run_skips.csv", SKIP_COLUMNS, skips)
    json_path = output / "three_source_offset_summary.json"
    temporary = json_path.with_suffix(".json.tmp")
    if json_path.is_symlink() or temporary.is_symlink():
        raise ValueError("Refusing to write through a summary symlink")
    temporary.write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(json_path)
    print("Three-source ENF run analysis\n=============================")
    print(f"Input run roots         : {summary['experiment_folder_count']}")
    print(f"Run folders discovered  : {len(discovered_runs)}")
    print(f"Run folders selected    : {len(runs)}")
    print(f"Explicit request IDs    : {sorted(args.request_ids)}")
    print(f"Valid runs              : {len(rows)}\nSkipped                 : {len(skips)}")
    print("\nMean signed offset across valid runs:")
    for _, _, _, key, label in PAIRS:
        stats = summary["offset_statistics"][key]
        mean = "N/A" if stats["mean_mhz"] is None else f"{stats['mean_mhz']:+.9g} mHz"
        std = "N/A" if stats["std_mhz"] is None else f"{stats['std_mhz']:.9g} mHz"
        print(f"\n{label}\n  mean : {mean}\n  std  : {std}")
    print("\nPearson correlation across valid runs:")
    for _, _, _, key, label in PAIRS:
        stats = summary["correlation_statistics"][key]
        mean = "N/A" if stats["mean"] is None else f"{stats['mean']:.17g}"
        std = "N/A" if stats["std"] is None else f"{stats['std']:.17g}"
        print(f"\n{label}\n  mean       : {mean}\n  sample std : {std}")
    closure = summary["closure_error_statistics"]
    print("\nClosure error (mHz):")
    for field in ("mean_mhz", "std_mhz", "min_mhz", "max_mhz", "median_mhz"):
        value = closure[field]
        print(f"  {field}: {'N/A' if value is None else format(value, '.17g')}")
    print(f"\nJSON cross-check: {summary['metrics_json_crosscheck']}")
    if warnings:
        print(f"Warnings: {len(warnings)}; see summary JSON")
    analyze_frame_diagnostics(rows, output)
    print(f"Output directory: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
