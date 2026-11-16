"""Run sequential live three-source acquisitions and record batch outcomes.

CLI options select reference services, capture root, run count, and gap.
The loader may program the board; UART and both reference devices are needed.
Writes batch JSON/CSV under verifier/batch_runs and request artifacts in the
capture root. Successful workflow markers do not imply geographic acceptance.
"""

# STEP_1: Dependencies and configuration
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

VERIFIER_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = VERIFIER_ROOT.parent / "fpga_enf_data"
WRAPPER = VERIFIER_ROOT / "scripts" / "zb_attester_reload_bit_elf.py"
ACQUISITION_PASS = "[MULTI-SOURCE ACQUISITION] ZedBoard + REF_CITYA + REF_PICO_CITYA: PASS"
PROCESSING_PASS = "[MULTI-SOURCE ENF PROCESSING] Acquisition and numerical comparison workflow: PASS"
CSV_COLUMNS = [
    "batch_run_index", "configured_count", "start_utc", "end_utc", "elapsed_s",
    "exit_code", "status", "experiment_date", "request_id", "request_directory",
    "configured_gap_after_s", "actual_gap_after_s", "error",
]


def positive_count(text):
    try:
        value = int(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("count must be a positive integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("count must be a positive integer")
    return value


def nonnegative_gap(text):
    try:
        value = float(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("gap must be finite and non-negative") from exc
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("gap must be finite and non-negative")
    return value


# STEP_2: Batch configuration
def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=positive_count, default=10)
    parser.add_argument("--gap-s", type=nonnegative_gap, default=10.0)
    parser.add_argument("--refdb-url", default=os.environ.get("ENF_REFDB_URL"))
    parser.add_argument("--pico-ref-url", default=os.environ.get("ENF_PICO_REF_URL"))
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
                        help="Capture root containing reqid_N groups; default: fpga_enf_data/.")
    reload_mode = parser.add_mutually_exclusive_group()
    reload_mode.add_argument("--no-reload", dest="no_reload", action="store_true",
                             help="Use the already programmed board (default).")
    reload_mode.add_argument("--reload", dest="no_reload", action="store_false",
                             help="Ask the existing wrapper to reload before every attempt.")
    parser.set_defaults(no_reload=True)
    parser.add_argument("--continue-on-failure", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if not args.refdb_url or not args.pico_ref_url:
        parser.error("configure --refdb-url/ENF_REFDB_URL and --pico-ref-url/ENF_PICO_REF_URL")
    args.output_dir = args.output_dir.expanduser().resolve()
    return args


def build_child_command(args):
    """Build the loader command from batch options using the configured output root."""
    command = [
        sys.executable, str(WRAPPER),
        "--refdb-url", args.refdb_url,
        "--pico-ref-url", args.pico_ref_url,
        "--output-dir", str(args.output_dir),
    ]
    if args.no_reload:
        command.append("--no-reload")
    # No request ID or pre-roll override: retain the validated verifier defaults.
    return command


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def discover_request_directories(output_dir):
    # Observe only the configured capture root; never scan unrelated experiments.
    return {directory.resolve() for directory in output_dir.glob("reqid_*") if directory.is_dir()}


# STEP_3: Completed-transaction validation
def validate_completed_run(row, new_directories, previously_used):
    """Record child-process and output validation failures; require one new successful request."""
    row["new_request_directories"] = [str(path) for path in sorted(new_directories)]
    problems = []
    if row["exit_code"] != 0:
        problems.append(f"child exit code: {row['exit_code']}")
    if len(new_directories) != 1:
        problems.append(
            "no new request directory" if not new_directories else
            "ambiguous new request directories: " + ", ".join(row["new_request_directories"])
        )
    else:
        directory = next(iter(new_directories))
        row["request_directory"] = str(directory)
        request = re.fullmatch(r"reqid_(\d+)", directory.name)
        if not request:
            problems.append("malformed request directory name")
        else:
            row["experiment_date"] = datetime.fromisoformat(row["start_utc"]).strftime("%Y_%m_%d")
            row["request_id"] = int(request.group(1))
        if directory in previously_used:
            problems.append("request directory was already used in this batch")
        try:
            lines = (directory / "enf_verifier.log").read_text(encoding="utf-8-sig").splitlines()
            stripped = [line.strip() for line in lines]
            for marker in (ACQUISITION_PASS, PROCESSING_PASS):
                if stripped.count(marker) != 1:
                    problems.append(f"missing or duplicated success marker: {marker}")
            ids = re.findall(r"(?m)^\[BOARD ATTESTATION\]\s*Request ID:\s*(\d+)\s*$", "\n".join(lines))
            if len(ids) != 1 or int(ids[0]) != row["request_id"]:
                problems.append("log request ID missing, duplicated, or mismatched")
            if any(re.search(r"^\[[^]]+\]\s*FAIL(?:\s|:|$)", line) for line in stripped):
                problems.append("explicit FAIL record in verifier log")
        except (OSError, UnicodeError) as exc:
            problems.append(f"could not read verifier log: {exc}")
    row["status"] = "FAIL" if problems else "PASS"
    row["error"] = "; ".join(problems)


# STEP_4: Batch result output
def save_summary(summary, json_path, csv_path):
    """Update batch success counts and atomically write JSON and CSV summaries."""
    summary["successful_runs"] = sum(row["status"] == "PASS" for row in summary["runs"])
    summary["failed_runs"] = sum(row["status"] in ("FAIL", "INTERRUPTED")
                                 for row in summary["runs"])
    temporary = json_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(json_path)
    temporary = csv_path.with_suffix(".csv.tmp")
    with temporary.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(summary["runs"])
    temporary.replace(csv_path)


def wait_for_exit(process):
    """Wait synchronously, including on Ctrl+C; never start another child on interruption."""
    interrupted = False
    while True:
        try:
            return process.wait(), interrupted
        except KeyboardInterrupt:
            # The inherited console also delivers Ctrl+C to the wrapper/verifier.
            # Do not kill only the wrapper and leave its verifier running.
            interrupted = True
            print("[BATCH] Interrupted; waiting for the current child to exit. No further runs will start.",
                  flush=True)


# STEP_5: Sequential live workflow orchestration
def run_batch(args, command):
    """Launch sequential live acquisitions, validate each result, and persist batch summaries."""
    batch_start = time.monotonic()
    batch_id = "three_source_batch_" + datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f") + "_" + uuid.uuid4().hex[:6]
    output = VERIFIER_ROOT / "batch_runs"
    output.mkdir(parents=True, exist_ok=True)
    json_path, csv_path = output / f"{batch_id}.json", output / f"{batch_id}.csv"
    summary = {
        "batch_id": batch_id, "configured_count": args.count, "configured_gap_s": args.gap_s,
        "refdb_url": args.refdb_url, "pico_ref_url": args.pico_ref_url,
        "no_reload": args.no_reload, "continue_on_failure": args.continue_on_failure,
        "command": command, "batch_start_utc": utc_now(), "batch_end_utc": None,
        "batch_elapsed_s": None, "status": "RUNNING", "runs": [],
        "gap_definition": "observed previous child exit to next child launch; monotonic seconds",
    }
    previous_exit = None
    used = set()
    interrupted = False
    save_summary(summary, json_path, csv_path)
    try:
        for index in range(1, args.count + 1):
            if previous_exit is not None:
                print(f"[BATCH] Waiting {args.gap_s:.1f} s between requests...", flush=True)
                # Validation and summary-writing time already counts toward the gap.
                deadline = previous_exit + args.gap_s
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    time.sleep(remaining)
            before = discover_request_directories(args.output_dir)
            print("\n" + "=" * 60, flush=True)
            print(f"[BATCH] Starting run {index} / {args.count}", flush=True)
            print("=" * 60, flush=True)
            row = dict.fromkeys(CSV_COLUMNS)
            row.update(batch_run_index=index, configured_count=args.count, status="RUNNING",
                       start_utc=utc_now(), configured_gap_after_s=0, error="")
            summary["runs"].append(row)
            start = time.monotonic()
            if previous_exit is not None:
                summary["runs"][-2]["actual_gap_after_s"] = start - previous_exit
            try:
                # No pipes: inherit the console for live stdout/stderr.
                process = subprocess.Popen(command, cwd=VERIFIER_ROOT, shell=False)
            except OSError as exc:
                exit_time = time.monotonic()
                row.update(status="FAIL", error=f"Could not launch child: {exc}")
            else:
                # No next iteration can occur until this child has fully exited.
                row["exit_code"], interrupted = wait_for_exit(process)
                exit_time = time.monotonic()
            row.update(end_utc=utc_now(), elapsed_s=exit_time - start)
            previous_exit = exit_time
            new_directories = discover_request_directories(args.output_dir) - before
            launch_error = row["error"]
            validate_completed_run(row, new_directories, used)
            used.update(new_directories)
            if launch_error:
                row.update(status="FAIL", error=launch_error + "; " + row["error"])
            if interrupted:
                row.update(status="INTERRUPTED", error="Batch interrupted during child execution; " + row["error"])
            can_continue = (index < args.count and not interrupted and
                            (row["status"] == "PASS" or args.continue_on_failure))
            row["configured_gap_after_s"] = args.gap_s if can_continue else 0
            save_summary(summary, json_path, csv_path)
            print(f"[BATCH] Run {index} / {args.count}: {row['status']}", flush=True)
            if row["request_directory"]:
                print(f"[BATCH] Request directory: {row['request_directory']}", flush=True)
            if row["error"]:
                print(f"[BATCH] {row['error']}", flush=True)
            if not can_continue:
                break
    except KeyboardInterrupt:
        interrupted = True
        print("[BATCH] Interrupted between requests; no further runs will start.", flush=True)
    except Exception as exc:
        summary["error"] = str(exc)
        print(f"[BATCH] Batch error: {exc}", flush=True)
        if summary["runs"] and summary["runs"][-1]["status"] == "RUNNING":
            summary["runs"][-1].update(status="FAIL", error=str(exc), end_utc=utc_now())
    finally:
        # A stopped batch also has no gap after its final attempted request.
        if summary["runs"]:
            summary["runs"][-1]["configured_gap_after_s"] = 0
            summary["runs"][-1]["actual_gap_after_s"] = None
        summary["batch_end_utc"] = utc_now()
        summary["batch_elapsed_s"] = time.monotonic() - batch_start
        success_count = sum(row["status"] == "PASS" for row in summary["runs"])
        summary["status"] = ("INTERRUPTED" if interrupted else
                             "PASS" if success_count == args.count and not summary.get("error") else "FAIL")
        save_summary(summary, json_path, csv_path)
    print("\n" + "=" * 60, flush=True)
    print("[BATCH] COMPLETE" if summary["status"] == "PASS" else
          f"[BATCH] Batch stopped; completed valid runs: {summary['successful_runs']} / {args.count}",
          flush=True)
    print("=" * 60, flush=True)
    print(f"Requested runs  : {args.count}\nSuccessful runs : {summary['successful_runs']}\n"
          f"Failed runs     : {summary['failed_runs']}\nBatch summary   : {json_path}\nBatch CSV       : {csv_path}",
          flush=True)
    return 130 if interrupted else (0 if summary["status"] == "PASS" else 1)


# STEP_6: Batch entrypoint
def main(argv=None):
    """Validate CLI options and run or preview the configured acquisition batch."""
    args = parse_args(argv)
    command = build_child_command(args)
    if args.dry_run:
        print(f"Batch count : {args.count}\nGap         : {args.gap_s:.1f} s\n"
              f"Working dir : {VERIFIER_ROOT}\nCommand     : {subprocess.list2cmdline(command)}\n"
              "DRY RUN: no verifier processes started")
        return 0
    if not WRAPPER.is_file():
        print(f"[BATCH] Wrapper not found: {WRAPPER}", file=sys.stderr)
        return 1
    return run_batch(args, command)


if __name__ == "__main__":
    raise SystemExit(main())
