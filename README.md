# Electric Network Frequency Signatures for Semiconductor Chip Geolocation Open Science Artifact

## 1. Overview

This repository accompanies the paper titled **Dude, Where's My Chip? Electric Network Frequency Signatures for Semiconductor Chip Geolocation**, prepared for IEEE Symposium on Security and Privacy (S&P) 2027. It studies power-grid-level chip geolocation through Electric Network Frequency (ENF) signatures sensed from the ambient electromagnetic (EM) emissions of DC-powered boards and compared with mains references.

This repository provides the experimental data, analysis scripts, and ZedBoard prototype implementation supporting our study of ENF-based chip geolocation. The following sections describe the experimental evaluations, reproduction procedures, and corresponding outputs.

## 2. Repository Structure

```text
opensci_repo_enf_chip_geoloc/
    README.md
    exp_validation/
        exp_inputs/
        exp_scripts/
        exp_logs/
        exp_results/
    exp_evaluation/
        exp_inputs/
        exp_scripts/
        exp_logs/
        exp_results/
    exp_prototype/
        README.md
        LICENSE
        zedboard/
            hardware/
            secure_world/
            normal_world/
            platform/
        reference/
            mains/
            pico/
        verifier/
            scripts/
            keys/
        data/
            paper_runs/
            expected_correlations.csv
            offline_reproduction_metadata.csv
        reproduce/
            reproduce_paper_results.py
            verification.py
```

- [`exp_validation/`](exp_validation/) contains the experimental data and MATLAB scripts used to **validate the ENF leakage hypothesis** (Section 4). It includes ambient EM measurements from the Sakura-G and ChipWhisperer-305 (CW305) FPGA boards, AC–DC adapter and power-rail measurements, and experiments characterizing ENF recovery near active PCBs. The ENF extraction pipeline is provided through `exp_scripts/proc_enf_analysis.p`.

- [`exp_evaluation/`](exp_evaluation/) contains the datasets and six MATLAB scripts supporting the **temporal reliability, robustness, grid-level discrimination, and security evaluation** (Section 6). The evaluations examine ENF recovery across different recording times, sensing conditions in a high-density computing environment, discrimination between power grids, and resilience against replay, relay, and synthetic ENF forgery attacks.

- [`exp_prototype/`](exp_prototype/) contains the **end-to-end ENF-based location attestation prototype** implemented on a Zynq-7000 ZedBoard (Section 5). It includes the hardware and TrustZone software implementation for trusted ENF sensing, the reference acquisition services, the verifier, and the recorded prototype dataset. Offline reproduction scripts support verification of saved attestation evidence and reproduction of the reported ENF correlations. See the [prototype README](exp_prototype/README.md) for setup and reproduction instructions.

Input recordings for the MATLAB experiments are organized under each experiment's `exp_inputs/` directory, with the corresponding analysis scripts in `exp_scripts/`. The `exp_logs/` and `exp_results/` directories contain generated logs and results and may be empty in a source-only release. The cached relay-analysis mode requires previously generated raw-result CSV files.

**Note:** Our core analysis function, originally developed under authors' university policy that restricts source release, is provided here as a compiled MATLAB function (`proc_enf_analysis.p`) rather than in source form. The top-level scripts in this repository call that compiled function so that all analyses in the paper can be reproduced without exposing proprietary internals.

## 3. Software Requirements

### MATLAB Analysis

The MATLAB experiments use **MATLAB R2018b (9.5)**, matching the supplied `proc_enf_analysis.p`. Required toolboxes depend on the experiment:

- **Signal Processing Toolbox:** ENF processing, resampling, and filtering.
- **Image Processing Toolbox:** Spectrum combining and high-resolution ENF extraction.
- **Statistics and Machine Learning Toolbox:** Statistical analyses and hypothesis testing.
- **Parallel Computing Toolbox:** Parallel relay and synthetic-forgery evaluation (serial execution is also supported).

MATLAB requires read/write access to the experiment directories. The original source of `proc_enf_analysis.p` is not required.

### Prototype Offline Reproduction

Requires **Python 3.14.0** and packages listed in [`exp_prototype/requirements.txt`](exp_prototype/requirements.txt). Offline reproduction uses NumPy, SciPy, Matplotlib, and cryptography without requiring physical hardware or reference services. See the [prototype README](exp_prototype/README.md#3-dependencies).

### FPGA and Firmware Builds

Rebuilding the ZedBoard implementation requires **Vivado/Vitis 2025.2**, Zynq-7000 support, and the Cortex-A9 toolchain/platform components. See the [prototype build instructions](exp_prototype/README.md#7-vivadovitis-build-instructions). These tools are not required for MATLAB experiments or offline prototype reproduction.

## 4. Reproducing the Experiments

Sections 5.1–5.2 provide reproduction instructions for ENF sensing validation (`exp_validation/`), while Sections 5.3–5.8 cover temporal reliability, server-room robustness, grid-level discrimination, and attack evaluation (`exp_evaluation/`). The end-to-end ZedBoard prototype is introduced in Section 6, with detailed reproduction instructions in the [prototype README](exp_prototype/README.md).

Run the MATLAB entrypoints from the repository root using MATLAB R2018b.

## 5. Experimental Reproduction

The repository provides eight MATLAB entrypoints for reproducing the experimental validation and evaluation results. Open MATLAB R2018b, set the Current Folder to the repository root, and run the corresponding commands below. Evaluation figures and numerical output files are saved under exp_evaluation/exp_results/, while execution logs are saved under each experiment's exp_logs/ directory.

### 5.1 Pairwise ENF Analysis

**Script:** [`enf_analysis_top_pair_wise.m`](exp_validation/exp_scripts/enf_analysis_top_pair_wise.m)  
**Paper:** Sections 4.3–4.4

Compares two recordings and visualizes their spectrograms, extracted ENF traces, and Pearson correlation. In `STEP_1`, select the input paths and filenames (without `.wav`) from `exp_validation/exp_inputs/`. The default configuration uses the Sakura-G ambient-EM recordings.

```matlab
run(fullfile(pwd, 'exp_validation', 'exp_scripts', 'enf_analysis_top_pair_wise.m'));
```

**Outputs:** Pearson correlation, interactive figures, and an execution log. Optional chunk processing can be enabled through `SCRP_CFG_DO_CHUNK_PROCESSING`.

### 5.2 Consolidated Validation and Sensing Characterization

**Script:** [`enf_analysis_top_validation_summary.m`](exp_validation/exp_scripts/enf_analysis_top_validation_summary.m)  
**Paper:** Sections 4.3–4.4 and Additional Artifacts A–D/F

Processes the supplied 77 recording comparisons covering ambient-EM sensing, power-rail measurements, adapters, shielding, and probe characterization. The input inventory and ENF extraction configurations are predefined.

```matlab
run(fullfile(pwd, 'exp_validation', 'exp_scripts', 'enf_analysis_top_validation_summary.m'));
```

**Outputs:** Per-comparison correlations and summary statistics in the console and execution log.

### 5.3 Temporal Reliability

**Script:** [`enf_analysis_top_reliability_stat.m`](exp_evaluation/exp_scripts/enf_analysis_top_reliability_stat.m)  
**Paper:** Section 6.1

Analyzes 160 recording pairs from `exp_evaluation/exp_inputs/TREND/` across recording times, days, and weeks. The supplied dataset requires no configuration changes.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_reliability_stat.m'));
```

**Outputs:** Correlation statistics, repeated-measures analyses, and the inferential figure under `exp_results/enf_temporal_reliability/`.

### 5.4 Server-Room Robustness

**Script:** [`enf_analysis_top_reliability_stat_server.m`](exp_evaluation/exp_scripts/enf_analysis_top_reliability_stat_server.m)  
**Paper:** Section 6.2

Evaluates ENF sensing across two sensor placements and recording days using 20 pairs from `exp_evaluation/exp_inputs/SRV_L/`. The supplied dataset requires no configuration changes.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_reliability_stat_server.m'));
```

**Outputs:** Correlation statistics, repeated-measures analyses, and the inferential figure under `exp_results/srv_room_robustness/`.

### 5.5 Multi-Location and Cross-Grid Discrimination

**Script:** [`enf_analysis_top_multi_loc_stat.m`](exp_evaluation/exp_scripts/enf_analysis_top_multi_loc_stat.m)  
**Paper:** Section 6.3

Evaluates intra-grid and inter-grid ENF correlations using the `MULTI/` dataset, containing US (60 Hz) and German (50 Hz) recordings. The script automatically selects the corresponding ENF configurations.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_multi_loc_stat.m'));
```

**Outputs:** Correlation distributions, statistical tests, EER estimates, and figures under `exp_results/multiloc_validation/`.

### 5.6 Replay Attacks

**Script:** [`enf_analysis_top_replay_attacks.m`](exp_evaluation/exp_scripts/enf_analysis_top_replay_attacks.m)  
**Paper:** Section 6.4

Evaluates replay attacks using the `TREND/` dataset with eight authentic targets and 124 replay comparisons. The target selection and detection threshold are predefined.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_replay_attacks.m'));
```

**Outputs:** Replay correlation statistics, detection results, CSV files, and the ENF overlay figure under `exp_results/replay_attack_resilience/`.

### 5.7 Relay Attacks

**Script:** [`enf_analysis_top_relay_attacks.m`](exp_evaluation/exp_scripts/enf_analysis_top_relay_attacks.m)  
**Paper:** Section 6.4

Evaluates relay-induced timing offsets using high-resolution ENF extraction over 160 recording pairs. For full reproduction, retain `config.RUN_ENF_EXTRACTION=true` and `config.RUN_BASELINE=false`. Parallel processing can be disabled with `config.USE_PARALLEL=false`.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_relay_attacks.m'));
```

**Outputs:** Delay estimates, detection thresholds, TPR results, CSV files, and the relay-delay figure under `exp_results/relay_attacks/`.

Setting `config.RUN_ENF_EXTRACTION=false` enables downstream analysis using previously generated raw-result CSV files.

### 5.8 Synthetic ENF Forgery

**Script:** [`enf_analysis_top_syn_forgery_attacks.m`](exp_evaluation/exp_scripts/enf_analysis_top_syn_forgery_attacks.m)  
**Paper:** Section 6.4

Evaluates synthetic ENF forgery against 160 authentic recordings from the `TREND/` dataset. The attack-generation parameters and detection threshold are predefined. Set `config.USE_PARALLEL=false` for serial execution.

```matlab
run(fullfile(pwd, 'exp_evaluation', 'exp_scripts', 'enf_analysis_top_syn_forgery_attacks.m'));
```

**Outputs:** Authentic/forged correlation statistics, detection results, CSV files, and the ENF overlay figure under `exp_results/syn_forgery_attacks/`.

## 6. End-to-End Prototype

The [`exp_prototype/`](exp_prototype/) directory contains the ZedBoard TrustZone implementation, reference acquisition services, verifier, and 15-run experimental dataset. Its offline reproduction scripts verify saved attestation evidence and reproduce the ENF correlation results.

See the [prototype README](exp_prototype/README.md) for software dependencies, build instructions, and offline reproduction.

## 7. Licensing

The prototype source code and dataset are distributed under the [`exp_prototype/LICENSE`](exp_prototype/LICENSE) MIT License. Bundled third-party components retain their respective licenses and attribution notices, as documented in the [prototype README](exp_prototype/README.md#11-licensing).
