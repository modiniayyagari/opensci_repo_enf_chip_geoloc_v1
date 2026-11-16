"""Verify saved prototype evidence and reproduce the bundled 15-run correlations.

Reads paper_runs, offline_reproduction_metadata.csv, enrolled public keys,
and expected_correlations.csv; writes
verification JSON, ENF/comparison CSVs, and aggregate regression results to a
new output directory. No live hardware or network is used. Board and mains
signatures are checked; Pico hashes establish consistency only. Regression
PASS is not geographic acceptance, and the board signing key is public demo
material.
"""
# STEP_1: Dependencies and configuration
import argparse
import csv
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
REPOSITORY = Path(__file__).resolve().parents[1]
TOLERANCE = 1e-10
PAIRS = (
    ('zedboard_vs_ref_citya', 'zedboard_mains_pearson_r', 'zedboard_minus_ref_citya', 'zedboard', 'mains'),
    ('zedboard_vs_ref_pico_citya', 'zedboard_pico_pearson_r', 'zedboard_minus_ref_pico_citya', 'zedboard', 'pico'),
    ('ref_citya_vs_ref_pico_citya', 'mains_pico_pearson_r', 'ref_citya_minus_ref_pico_citya', 'mains', 'pico'),
)


def require(condition, message):
    """Raise RuntimeError when a reproduction validation condition is false."""
    if not condition:
        raise RuntimeError(message)


# STEP_2: Saved input and output utilities
def read_json(path):
    """Read saved JSON, accepting a UTF-8 byte-order mark."""
    return json.loads(path.read_text(encoding='utf-8-sig'))


def read_offline_metadata(path):
    """Load one compact metadata row per request without discarding independent bindings.

    Reconstruct only the timing fields consumed by existing evidence checks and
    saved diagnostics. The table is unsigned provenance, not replacement signed
    evidence; all board/mains signatures and Pico digest checks still apply.
    """
    fields = (
        'request_id', 'mains_request_id', 'mains_nonce', 'pico_request_id',
        'pico_nonce', 'pico_verifier_id', 'pico_downloaded_sha256',
        'pico_metadata_sha256', 'mains_fpga_get_send_utc',
        'mains_host_ref_capturing_confirmed_utc', 'mains_capture_call_before_utc',
        'mains_capture_call_after_utc', 'mains_observed_pre_roll_s',
        'pico_observed_pre_roll_s',
    )
    with path.open(encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        require(reader.fieldnames is not None and len(reader.fieldnames) == len(fields)
                and set(reader.fieldnames) == set(fields), 'Invalid offline metadata columns')
        rows = list(reader)
    require(len(rows) == 15, 'Offline metadata must contain exactly 15 rows')
    metadata = {}
    for row in rows:
        require(set(row) == set(fields) and all(row[name] for name in fields),
                'Offline metadata row contains missing or extra values')
        request_id = int(row['request_id'])
        require(request_id not in metadata, 'Duplicate offline metadata request ID')
        mains_pre_roll = float(row['mains_observed_pre_roll_s'])
        pico_pre_roll = float(row['pico_observed_pre_roll_s'])
        require(math.isfinite(mains_pre_roll) and math.isfinite(pico_pre_roll),
                'Offline observed pre-roll values must be finite')
        host_timing = {
            'request_id': int(row['mains_request_id']),
            'nonce': row['mains_nonce'],
            'fpga_get_send_utc': row['mains_fpga_get_send_utc'],
            'host_ref_capturing_confirmed_utc': row['mains_host_ref_capturing_confirmed_utc'],
            'manifest_capture_timestamps': {
                'capture_call_before_utc': row['mains_capture_call_before_utc'],
                'capture_call_after_utc': row['mains_capture_call_after_utc'],
            },
            'ref_citya_observed_pre_roll_s': mains_pre_roll,
        }
        pico_timing = {
            'request_id': int(row['pico_request_id']),
            'nonce': row['pico_nonce'],
            'verifier_id': row['pico_verifier_id'],
            'downloaded_sha256': row['pico_downloaded_sha256'],
            'metadata_sha256': row['pico_metadata_sha256'],
            'pico_ref_observed_pre_roll_s': pico_pre_roll,
        }
        metadata[request_id] = (host_timing, pico_timing)
    require(set(metadata) == set(range(1, 16)),
            'Offline metadata request IDs must be exactly 1 through 15')
    return metadata


def digest(path):
    """Return the streaming SHA-256 hex digest of a saved input file."""
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    """Write indented JSON, rejecting NaN and infinite values."""
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def write_csv(path, rows, fields=None):
    """Write the supplied rows using the declared CSV columns."""
    with path.open('w', encoding='utf-8', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields or list(rows[0]))
        w.writeheader()
        w.writerows(rows)


# STEP_3: Safe offline module loading
def import_offline(name, relative):
    """Load a repository-relative numerical or verification module without importing the live verifier."""
    path = REPOSITORY / relative
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# STEP_4: Live-operation exclusion
def prohibit_live_operations(event, args):
    """Reject network, subprocess, and device-module audit events during offline reproduction."""
    if event in ('socket.connect', 'socket.connect_ex', 'socket.bind', 'socket.getaddrinfo',
                 'subprocess.Popen', 'os.system'):
        raise RuntimeError('Live operation prohibited in offline reproduction: ' + event)
    if event == 'import' and str(args[0]).split('.')[0] in ('serial', 'sounddevice', 'picosdk'):
        raise RuntimeError('Device module prohibited in offline reproduction: ' + str(args[0]))


# STEP_5: Verification, production DSP and regression output
def main():
    """Validate saved evidence, recompute correlations, and export regression results; fail on any mismatch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, help='New output directory outside the repository; default: ignored reproduction_output/.')
    args = parser.parse_args()
    output = (args.output_dir or REPOSITORY / 'reproduction_output').expanduser().resolve()
    if args.output_dir is not None:
        require(output != REPOSITORY and REPOSITORY not in output.parents,
                '--output-dir must be outside the repository')
    require(not output.exists() or not any(output.iterdir()),
            'Output directory must be new or empty; choose --output-dir to preserve earlier results')
    output.mkdir(parents=True, exist_ok=True)
    os.environ['MPLCONFIGDIR'] = str(output / '.matplotlib-cache')
    sys.addaudithook(prohibit_live_operations)
    # Load the numerical and evidence helpers without initializing the live UART verifier.
    p = import_offline('enf_offline_processing', 'verifier/scripts/enf_reference_processing.py')
    a = import_offline('enf_offline_aggregation', 'verifier/scripts/analyze_three_source_runs.py')
    v = import_offline('enf_offline_verification', 'reproduce/verification.py')
    cohort = REPOSITORY / 'data' / 'paper_runs'
    directories = {d.name for d in cohort.glob('reqid_*') if d.is_dir()}
    require(directories == {f'reqid_{rid}' for rid in range(1, 16)}, 'Expected exactly request directories 1–15')
    with (REPOSITORY / 'data' / 'expected_correlations.csv').open(encoding='utf-8-sig', newline='') as f:
        expected_rows = list(csv.DictReader(f))
    require(len(expected_rows) == 15, 'Expected-correlation oracle must contain 15 rows')
    expected = {int(row['request_id']): row for row in expected_rows}
    require(set(expected) == set(range(1, 16)), 'Expected correlation IDs must be unique and complete')
    offline_metadata = read_offline_metadata(REPOSITORY / 'data' / 'offline_reproduction_metadata.csv')
    run_results, regressions, verification_results, pair_metrics = [], [], [], {pair[0]: [] for pair in PAIRS}
    for rid in range(1, 16):
        run = cohort / f'reqid_{rid}'
        board_metadata = read_json(run / 'zb_attestation_metadata.json')
        pico_metadata = read_json(run / 'pico_ref_metadata.json')
        host_timing, pico_timing = offline_metadata[rid]
        manifests = list(run.glob('*_manifest.json'))
        require(len(manifests) == 1, f'Request {rid}: expected one mains manifest')
        manifest = read_json(manifests[0])
        nonce_hex = board_metadata['nonce']
        # Authenticate canonical bytes before using the board's signed ENF values.
        parsed, evidence_hash = v.authenticate_zb_evidence(
            (run / 'zb_m_zb.bin').read_bytes(), (run / 'zb_signature.bin').read_bytes(), rid,
            v.decode_fixed_hex(nonce_hex, 'board nonce', 16))
        require(board_metadata['request_id'] == rid and board_metadata['device_id'] == parsed['device_id']
                and board_metadata['verifier_id'] == parsed['verifier_id']
                and board_metadata['evidence_sha256'] == evidence_hash, f'Request {rid}: board metadata mismatch')
        # The mains signature binds its WAV digest to the same request and nonce.
        ref_security = v.authenticate_reference_manifest(manifest, rid, nonce_hex, 44100, 1)
        require(ref_security['nonce'] == parsed['nonce'] and ref_security['verifier_id'] == parsed['verifier_id'],
                f'Request {rid}: board/mains binding mismatch')
        wavs = list(run.glob('*.wav'))
        bins = [path for path in run.glob('*.bin') if path.name not in ('zb_m_zb.bin', 'zb_signature.bin')]
        require(len(wavs) == len(bins) == 1, f'Request {rid}: expected one raw WAV and Pico BIN')
        wav, pico_bin = wavs[0], bins[0]
        require(digest(wav) == manifest['wav_sha256'], f'Request {rid}: signed WAV digest mismatch')
        require(manifest['expected_samples'] == manifest['actual_samples'] == 9702000
                and manifest['requested_duration_ms'] == 220000, f'Request {rid}: mains count/duration mismatch')
        # Pico metadata is unsigned: these checks establish consistency, not origin.
        v.validate_pico_metadata(pico_metadata, rid, nonce_hex)
        pico_hash = digest(pico_bin)
        require(pico_hash == pico_metadata['trace_sha256'] == pico_timing['downloaded_sha256'],
                f'Request {rid}: Pico digest mismatch')
        require(digest(run / 'pico_ref_metadata.json') == pico_timing['metadata_sha256'],
                f'Request {rid}: saved Pico metadata digest mismatch')
        require(pico_metadata['actual_samples'] == pico_metadata['expected_samples'] == 9702000,
                f'Request {rid}: Pico sample count mismatch')
        for metadata in (manifest, host_timing, pico_metadata, pico_timing):
            require(metadata['request_id'] == rid and metadata['nonce'] == nonce_hex,
                    f'Request {rid}: transaction association mismatch')
        require(pico_timing['verifier_id'] == parsed['verifier_id'], f'Request {rid}: Pico verifier mismatch')
        dest = output / f'reqid_{rid}'
        dest.mkdir()
        board_path = dest / 'fpga_em_trace_200s_arm_enf.csv'
        v.write_arm_enf_csv(board_path, parsed['enf_values_nhz'])
        times, board = p.load_arm_enf_csv(board_path)
        count = p.validate_manifest(manifest)
        samples, info = p.load_reference_wav(wav, manifest)
        require(samples.size == count, f'Request {rid}: decoded WAV count mismatch')
        # Use the nominal 10-to-210-second crop, without fitting timing to correlation.
        alignment = p.build_alignment_metadata(host_timing, info['sample_rate_hz'], 10.0)
        p.validate_alignment_bounds(alignment, samples.size)
        aligned = samples[alignment['aligned_start_sample']:alignment['aligned_end_sample']]
        window = p.get_reference_window(p.FRAME_SAMPLES)
        mains = p.np.array([p.compute_reference_enf_hz(
            aligned[i * p.REFERENCE_FRAME_SAMPLES:(i + 1) * p.REFERENCE_FRAME_SAMPLES], window)
            for i in range(p.EXPECTED_FRAME_COUNT)])
        pico_samples, actual_rate = p.load_pico_binary(pico_bin, pico_metadata)
        pico, pico_alignment = p.extract_pico_enf(pico_samples, actual_rate, pico_metadata)
        vectors = {'zedboard': board, 'mains': mains, 'pico': pico}
        for label, values in vectors.items():
            require(values.shape == (25,) and p.np.all(p.np.isfinite(values)) and p.np.ptp(values) > 0,
                    f'Request {rid}: invalid {label} vector')
        p.write_reference_enf_csv(dest / 'mains_enf.csv', mains, 10.0)
        p.write_pico_enf_csv(dest / 'pico_enf.csv', pico)
        metrics, result_row = {}, {'request_id': rid}
        for key, column, _, left, right in PAIRS:
            metric = p.compute_comparison_metrics(vectors[left], vectors[right])
            metrics[key] = metric
            pair_metrics[key].append(metric)
            result_row[column] = metric['pearson_r']
            # Compare against the fixed oracle; regression PASS is not location acceptance.
            original = float(expected[rid][column])
            difference = abs(original - metric['pearson_r'])
            passed = math.isfinite(original) and difference <= TOLERANCE
            regressions.append({'request_id': rid, 'comparison': key, 'expected': original,
                                'reproduced': metric['pearson_r'], 'absolute_difference': difference,
                                'tolerance': TOLERANCE, 'status': 'PASS' if passed else 'FAIL'})
            if not passed:
                write_csv(output / 'regression_comparison.csv', regressions)
                raise RuntimeError(f'Request {rid}: scientific regression FAIL for {key}; no tolerance change allowed')
            p.write_comparison_csv(dest / (key + '.csv'), times, vectors[left], vectors[right], left+'_enf_hz', right+'_enf_hz')
        write_json(dest / 'metrics.json', {'request_id': rid, 'pairwise': metrics,
                   'mains_alignment': alignment, 'pico_alignment': pico_alignment,
                   'diagnostic_timing_only': {'mains_observed_pre_roll_s': host_timing.get('ref_citya_observed_pre_roll_s'),
                                             'pico_observed_pre_roll_s': pico_timing.get('pico_ref_observed_pre_roll_s')},
                   'pico_authenticated': False})
        run_results.append(result_row)
        verification_results.append({'request_id': rid, 'zedboard_signature': 'PASS', 'mains_signature': 'PASS',
            'pico_integrity': 'PASS', 'pico_authenticated': False, 'zedboard_enf_count': 25, 'mains_enf_count': 25,
            'pico_enf_count': 25, 'board_evidence_sha256': evidence_hash, 'mains_wav_sha256': manifest['wav_sha256'],
            'pico_bin_sha256': pico_hash, 'pico_actual_rate_hz': actual_rate,
            'pico_resampled_frame_lengths': pico_alignment['resampled_frame_lengths']})
        print(f'Request {rid:2d}/15: signatures PASS, Pico integrity PASS, 25/25/25 ENF values, correlations 3/3 PASS', flush=True)
    aggregate = {}
    for key, column, _, _, _ in PAIRS:
        values = [row[column] for row in run_results]
        expected_mean = a.correlation_statistics([float(expected[i][column]) for i in range(1, 16)])['mean']
        stats = a.correlation_statistics(values)
        require(abs(stats['mean'] - expected_mean) <= TOLERANCE, 'Aggregate correlation mismatch: ' + key)
        aggregate[key] = {'correlation_statistics': stats,
                          'offset_statistics': a.offset_statistics([m['mean_signed_difference_hz'] for m in pair_metrics[key]]),
                          'expected_mean': expected_mean}
    write_csv(output / 'recomputed_correlations.csv', run_results)
    write_csv(output / 'regression_comparison.csv', regressions)
    write_json(output / 'verification_results.json', verification_results)
    summary = {'status': 'PASS', 'requests': 15, 'zedboard_signatures_valid': 15, 'mains_signatures_valid': 15,
               'pico_integrity_pass': 15, 'correlations_pass': 45, 'absolute_tolerance': TOLERANCE,
               'max_absolute_difference': max(r['absolute_difference'] for r in regressions),
               'aggregate': aggregate, 'output_directory': str(output)}
    write_json(output / 'summary.json', summary)
    print('OFFLINE REPRODUCTION: PASS (15 requests, 45 correlations)', flush=True)
    for key in aggregate:
        print(f'{key}: {aggregate[key]["correlation_statistics"]["mean"]:.17g}', flush=True)
    print('Results: ' + str(output), flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print('OFFLINE REPRODUCTION: FAIL: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
