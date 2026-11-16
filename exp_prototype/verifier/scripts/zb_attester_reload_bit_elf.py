"""Program the ZedBoard through XSCT and launch the live UART/HTTP verifier.

Environment overrides select the bitstream, PS initialization, and Secure and
Normal ELF images; CLI options are forwarded to the verifier. Requires a board
and UART, plus JTAG when reloading. Writes a temporary XSCT
script and delegates experiment outputs to the verifier. Programming success
does not establish runtime TrustZone isolation.
"""

# STEP_1: Dependencies and configuration
import argparse
import os
import shutil
import sys
import subprocess
import tempfile
import time
from pathlib import Path


VERIFIER_ROOT = Path(__file__).resolve().parent.parent
EXPERIMENT_ROOT = VERIFIER_ROOT.parent
VITIS_ROOT = EXPERIMENT_ROOT / "zedboard"
XSCT = Path(os.environ.get("ENF_XSCT") or shutil.which("xsct.bat") or "xsct.bat")
BITSTREAM = Path(os.environ.get("ENF_BITSTREAM", str(EXPERIMENT_ROOT / "zedboard/hardware/project/zb_fpga_em_trace_200s.runs/impl_1/zb_fpga_em_trace_bd_wrapper.bit")))
PS7_INIT = Path(os.environ.get("ENF_PS7_INIT", str(VITIS_ROOT / "platform/enf_zb_attester_platform/export/enf_zb_attester_platform/hw/sdt/ps7_init.tcl")))
NORMAL_ELF = Path(os.environ.get("ENF_NORMAL_ELF", str(VITIS_ROOT / "normal_world/build/enf_zb_normal.elf")))
SECURE_ELF = Path(os.environ.get("ENF_SECURE_ELF", str(VITIS_ROOT / "secure_world/build/enf_zb_secure.elf")))
VERIFIER_PYTHON = Path(sys.executable)
VERIFIER_SCRIPT = VERIFIER_ROOT / "scripts/enf_verifier.py"
BOARD_BOOT_WAIT_SECONDS = 4.0


# STEP_2: Loader and verifier options
def parse_args():
    parser = argparse.ArgumentParser(
        description="Reload ENF attester FPGA/PS images and run the verifier."
    )
    parser.add_argument("--ping-only", action="store_true")
    parser.add_argument("--refdb-url", default=os.environ.get("ENF_REFDB_URL"))
    parser.add_argument("--pico-ref-url", default=os.environ.get("ENF_PICO_REF_URL"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--request-id")
    parser.add_argument("--board-evidence-timeout-s", type=float)
    parser.add_argument("--ref-duration", type=float)
    parser.add_argument("--ref-pre-roll", type=float)
    parser.add_argument("--ref-poll-interval", type=float)
    parser.add_argument("--ref-http-timeout", type=float)
    parser.add_argument("--ref-trace-basename")
    parser.add_argument(
        "--fpga-only",
        "--board-only",
        dest="fpga_only",
        action="store_true",
    )
    parser.add_argument(
        "--no-reload",
        action="store_true",
        help="Skip XSCT and only run the verifier.",
    )
    args = parser.parse_args()
    if not args.ping_only and not args.fpga_only and (not args.refdb_url or not args.pico_ref_url):
        parser.error("configure --refdb-url/ENF_REFDB_URL and --pico-ref-url/ENF_PICO_REF_URL before deployment")
    return args


# STEP_3: Deployment input validation
def require_files(paths):
    missing = [path for path in paths if not path.is_file()]
    if missing:
        formatted = "\n".join(f"  {path}" for path in missing)
        raise FileNotFoundError(f"Required ENF attester file(s) not found:\n{formatted}")


def tcl_path(path):
    return path.resolve().as_posix()


# STEP_4: FPGA and firmware programming sequence
def build_xsct_script():
    """Construct the FPGA/ELF programming sequence; load Normal then Secure and continue Secure startup."""
    return "\n".join((
        "set rc [catch {", "connect", "targets", "",
        "targets -set 4", f"fpga -file {tcl_path(BITSTREAM)}", "",
        "targets -set 2", "catch {stop}", "bpremove -all", "rst -processor", "",
        f"source {tcl_path(PS7_INIT)}", "ps7_init", "ps7_post_config", "",
        # Load Normal World first; Secure startup establishes TrustZone.
        f"dow {tcl_path(NORMAL_ELF)}", f"dow {tcl_path(SECURE_ELF)}", "",
        # Continuing only the Secure image transfers control to Normal World.
        "bpadd -addr 0x00000010", "bpadd -addr 0x00100010", "", "con",
        "} result]", "", "if {$rc != 0} {",
        "puts stderr \"\\[ENF-RELOAD\\] XSCT ERROR: $result\"",
        "catch {disconnect}", "exit 1", "}", "",
        "catch {disconnect}", "exit 0", "",
    ))

# STEP_5: Hardware loading and verifier command preparation
def run_reload():
    """Program board images through XSCT and remove the temporary Tcl file afterward."""
    require_files((XSCT, BITSTREAM, PS7_INIT, NORMAL_ELF, SECURE_ELF))
    temporary_path = None
    process = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".tcl", prefix="enf_reload_", encoding="utf-8", newline="\n", delete=False) as handle:
            handle.write(build_xsct_script())
            temporary_path = Path(handle.name)
        print("[BOARD PROGRAMMING] Starting FPGA programming and ELF loading", flush=True)
        process = subprocess.Popen([str(XSCT), str(temporary_path)], cwd=VERIFIER_ROOT, shell=False)
        try:
            return_code = process.wait()
        except KeyboardInterrupt:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        print("[BOARD PROGRAMMING] XSCT disconnected/exited", flush=True)
        if return_code == 0:
            print("[BOARD PROGRAMMING] ZedBoard attester started", flush=True)
        return return_code
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

def build_verifier_command(args):
    """Forward loader options to the live verifier using the current Python executable."""
    command = [str(VERIFIER_PYTHON), str(VERIFIER_SCRIPT)]
    if args.ping_only:
        command.append("--ping-only")
    if args.fpga_only:
        command.append("--fpga-only")
    if args.refdb_url:
        command.extend(("--refdb-url", args.refdb_url))
    if args.pico_ref_url:
        command.extend(("--pico-ref-url", args.pico_ref_url))
    for option in (
        "request_id", "board_evidence_timeout_s", "ref_duration", "ref_pre_roll",
        "ref_poll_interval", "ref_http_timeout", "ref_trace_basename", "output_dir",
    ):
        value = getattr(args, option)
        if value is not None:
            command.extend((f"--{option.replace('_', '-')}", str(value)))
    return command


# STEP_6: Live workflow entrypoint
def main():
    """Optionally program board images, then launch the verifier and return its exit status."""
    args = parse_args()
    require_files((VERIFIER_PYTHON, VERIFIER_SCRIPT))

    if not args.no_reload:
        reload_status = run_reload()
        if reload_status != 0:
            print(
                "[BOARD PROGRAMMING] Failed; verifier not started.",
                flush=True,
            )
            return reload_status
        time.sleep(BOARD_BOOT_WAIT_SECONDS)

    command = build_verifier_command(args)
    print("Starting the ENF verifier.", flush=True)
    return subprocess.run(
        command,
        cwd=VERIFIER_ROOT,
        check=False,
        shell=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
