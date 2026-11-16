# ENF Prototype Reproduction

## 1. Prototype Overview

This directory contains the end-to-end ENF-based location attestation prototype. A Zynq-7000 ZedBoard measures ENF in TrustZone Secure World; mains and PicoScope reference nodes provide comparison recordings; and a Python verifier checks the saved evidence and compares the ENF traces. The included dataset contains 15 prototype requests. **Offline reproduction uses saved recordings and requires no hardware or network services.**

**Demonstration key:** `zedboard/secure_world/src/secure_attestation_key.c` includes a public test signing key for reproducibility.

## 2. Directory Structure

- `zedboard/`: FPGA project, Secure/Normal World sources, platform configuration, and build helpers.
- `reference/mains/` and `reference/pico/`: reference acquisition services and the bundled PicoSDK Python wrapper.
- `verifier/`: live verifier, data-processing scripts, and trusted public keys.
- `data/paper_runs/reqid_1/` through `reqid_15/`: seven evidence/recording/metadata files per request (105 total).
- `data/expected_correlations.csv`: full-precision reference values for all 45 pairwise comparisons.
- `data/offline_reproduction_metadata.csv`: 15 rows of request/nonce bindings, integrity hashes, and retained timing diagnostics.
- `reproduce/`: the offline entrypoint `reproduce_paper_results.py` and its required helper `verification.py`.

The 30 original host-timing JSON files are **not published** because they include private-network endpoints. Required reproduction fields are retained in the compact metadata CSV; original records are archived privately. The recordings, signed manifests, signatures, and board evidence are unchanged.

## 3. Dependencies

For **offline reproduction**, use Python 3.14 and install `requirements.txt` (NumPy, SciPy, Matplotlib, cryptography, and additional live-acquisition dependencies). The documented package versions reflect observed environments. Offline reproduction does not need Vivado/Vitis, a ZedBoard, audio hardware, PicoSDK, or access to the original reference servers.

For **live operation**, the prototype additionally requires a ZedBoard (`xc7z020clg484-1`), Vivado/Vitis 2025.2 with Zynq-7000 and Cortex-A9 support, UART/JTAG, a suitable mains acquisition front end and audio driver, and a compatible PicoScope with its native `ps3000a` driver. Drivers and AMD toolchains are not bundled.

## 4. Offline Reproduction Instructions

From the repository root, run the following commands in **Windows PowerShell**:

```powershell
Set-Location exp_prototype
py -3.14 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe reproduce\reproduce_paper_results.py --output-dir ..\..\enf_prototype_results
```

The script reproduces the ENF correlations for all 15 prototype runs using saved recordings, without requiring physical hardware. It verifies ZedBoard and mains signatures, Pico recording integrity, and transaction bindings, then compares **45 Pearson correlations** against `data/expected_correlations.csv` with an absolute tolerance of `1e-10`.

Results are saved to the specified output directory, including `summary.json`, `verification_results.json`, `recomputed_correlations.csv`, and `regression_comparison.csv`. Use a new output directory for each execution.

The `data/offline_reproduction_metadata.csv` file contains the transaction identifiers, integrity hashes, and timing metadata required for offline verification. Original host-timing JSON files containing private-network addresses are excluded from the public artifact.

## 5. Expected Correlation Values

| ENF comparison | Mean Pearson correlation |
|---|---:|
| ZedBoard–mains | 0.9964305171818482 |
| ZedBoard–Pico | 0.9963877105163071 |
| Mains–Pico | 0.9997494161329915 |

## 6. Hardware Requirements

The prototype uses a **Zynq-7000 ZedBoard** with its on-chip XADC for ambient EM sensing. Live experiments require:

- **ZedBoard:** USB UART and JTAG connections to the verifier computer.
- **Mains reference:** An audio acquisition interface with an appropriate mains-sensing front end.
- **PicoScope reference:** A compatible PicoScope with the native `ps3000a` driver and supplied Python wrapper.

The verifier uses **COM4 at 115200 baud** by default. Configure the appropriate serial port and hardware connections before acquisition.

## 7. Vivado/Vitis Build Instructions

The ZedBoard hardware and Secure/Normal World firmware can be built using **Vivado/Vitis 2025.2** and the supplied scripts:

- `zedboard/build_hardware.tcl`
- `zedboard/build_software.py`

From `exp_prototype/`, run the following commands in Windows PowerShell, replacing the placeholders with local paths:

```powershell
$repo = (Get-Location).Path
$tools = '<AMD_2025_2_INSTALL_DIR>'
$env:ENF_BUILD_DIR = '<NEW_BUILD_DIRECTORY_OUTSIDE_REPO>'

if (Test-Path $env:ENF_BUILD_DIR) {
    throw 'Choose a new build directory.'
}
New-Item -ItemType Directory -Path $env:ENF_BUILD_DIR | Out-Null

Push-Location $env:ENF_BUILD_DIR
try {
    & "$tools\Vivado\bin\vivado.bat" -mode batch -source "$repo\zedboard\build_hardware.tcl"
    if ($LASTEXITCODE -ne 0) { throw 'Vivado build failed.' }

    & "$tools\Vitis\bin\vitis.bat" -s "$repo\zedboard\build_software.py"
    $status = Get-Content "$env:ENF_BUILD_DIR\software_build_status.json" -Raw | ConvertFrom-Json
    if ($status.status -ne 'PASS') { throw 'Vitis build failed.' }
} finally {
    Pop-Location
}
```

The scripts generate the FPGA bitstream, hardware XSA, Secure World firmware, and Normal World firmware in the specified build directory. Inspect the generated build-status file, utilization reports, and timing reports before programming the board.

These scripts prepare the hardware and firmware artifacts; board programming and live attestation are performed separately.

## 8. Reference Laptop Setup

Live experiments use separate mains and PicoScope reference services. Install the required drivers and Python dependencies on the respective computers.

**Mains reference:**

```powershell
python reference\mains\enf_refdb_server.py --host '<MAINS_IP>' --port 8765 --device '<AUDIO_DEVICE>' --private-key '<MAINS_PRIVATE_KEY_PEM>' --save-dir '<OUTPUT_DIR>'
```

The mains reference requires a signing key corresponding to the verifier's enrolled public key. The private mains key is not included in the repository.

**PicoScope reference:**

```powershell
python -m pip install .\reference\pico\vendor\picosdk-python-wrappers
python reference\pico\pico_ref_server.py --bind '<PICO_IP>' --port 8766 --trace-directory '<OUTPUT_DIR>'
```

Both services acquire reference recordings for ENF comparison. The acquisition configuration and corresponding metadata are maintained by the supplied scripts.

## 9. Verifier Configuration

The verifier communicates with the ZedBoard over **UART (COM4, 115200 baud)** and connects to the reference services using `--refdb-url` and `--pico-ref-url`.

Public verification keys and enrollment information are provided under `verifier/keys/trusted/`.

For board programming, the loader accepts the following environment variables:

| Variable | Purpose |
|---|---|
| `ENF_XSCT` | XSCT executable |
| `ENF_BITSTREAM` | FPGA bitstream |
| `ENF_PS7_INIT` | Zynq PS initialization script |
| `ENF_NORMAL_ELF` | Normal World firmware |
| `ENF_SECURE_ELF` | Secure World firmware |

Configure these paths according to the generated build artifacts.

## 10. Live Experiment Instructions

After building the firmware and starting the reference services, configure the board-programming paths:

```powershell
$env:ENF_XSCT = '<XSCT_BAT_PATH>'
$env:ENF_BITSTREAM = '<BITSTREAM_PATH>'
$env:ENF_PS7_INIT = '<PS7_INIT_TCL_PATH>'
$env:ENF_NORMAL_ELF = '<NORMAL_ELF_PATH>'
$env:ENF_SECURE_ELF = '<SECURE_ELF_PATH>'
```

To program the board and launch attestation:

```powershell
python verifier\scripts\zb_attester_reload_bit_elf.py --refdb-url 'http://<MAINS_IP>:8765' --pico-ref-url 'http://<PICO_IP>:8766'
```

For an already initialized board, use `verifier/scripts/enf_verifier.py` directly. The repository also includes `run_three_source_batch.py` for repeated acquisitions and `analyze_three_source_runs.py` for analyzing saved live experiments.

For reproducing the **paper's saved prototype results**, use the offline procedure in Section 4 instead. It does not require the hardware or reference services.

## 11. Licensing

The original prototype source code and accompanying `data/paper_runs/` dataset are released under the [MIT License](LICENSE). Bundled third-party components retain their own terms and attribution, including [micro-ecc BSD 2-Clause](zedboard/secure_world/src/micro-ecc-LICENSE.txt) and the [PicoSDK wrapper license](reference/pico/vendor/picosdk-python-wrappers/LICENSE.md). AMD/Xilinx and other dependency notices remain with their respective files; separately installed toolchains and drivers are not bundled.
