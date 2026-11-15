%% ENF Relay Attacks
% Purpose:
%   Evaluate relay-delay sensitivity with calibrated detectors.
%
% Experiment:
%   Main paper Section 6.4 and Figure 20.
%
% Analysis:
%   Apply source-sample delay injection, optional baseline analysis,
%   high-resolution lag estimation, and leave-one-out calibration.
%
% Inputs:
%   exp_evaluation/exp_inputs/TREND; 160 validated pairs, 320 WAVs, and 19
%   delay states, with fixed input-integrity hashes verified.
%
% Outputs:
%   Enabled raw CSVs, the summary CSV, and figures under
%   exp_evaluation/exp_results/relay_attacks, plus the script log under
%   exp_evaluation/exp_logs.
%
% Dependencies:
%   Shared exp_validation/exp_scripts/proc_enf_analysis.p; Signal Processing
%   and Statistics toolboxes; Parallel Computing Toolbox for six workers.
%
% Usage:
%   Defaults use RUN_BASELINE=false and RUN_ENF_EXTRACTION=true. Set extraction
%   false to reuse enabled raw CSVs; run from any working directory.


%% STEP_1) Script Configuration
% Keep independent baseline-inclusion and extraction/reuse flags and both existing estimators.
close all;
clear;
clc;

% Repository and Dataset Paths
config = struct();
standardization_timer = tic;
config.script_dir = fileparts(mfilename('fullpath'));
config.evaluation_root = fileparts(config.script_dir);
config.repository_root = fileparts(config.evaluation_root);
config.shared_dir = fullfile(config.repository_root, 'exp_validation', 'exp_scripts');
addpath(config.shared_dir, '-begin');
assert(strcmpi(which('proc_enf_analysis'), fullfile(config.shared_dir, 'proc_enf_analysis.p')), ...
    'Relay:ProcessorPath', 'MATLAB resolved a different shared ENF processor.');
config.trend_root = fullfile(config.evaluation_root, 'exp_inputs', 'TREND');
config.reference_filename = 'mains_pow_trace_ac.wav';
config.sensed_filename = 'fpga_em_trace_dc.wav';
config.allowed_leaf_folders = {'T01', 'T02', 'T03', 'T04', 'T05'};

% Execution Flags
% RUN_BASELINE enables the optional baseline Pearson-correlation detector;
% high-resolution lag analysis is always included. RUN_ENF_EXTRACTION
% recomputes enabled raw analyses when true or reuses saved raw CSVs when false.
config.RUN_BASELINE = false;
config.RUN_ENF_EXTRACTION = true;

% Parallel Processing
% USE_PARALLEL:
%   true:  Process independent TREND measurement pairs using a local
%          MATLAB parallel pool.
%   false: Process the same measurement pairs serially.
%
% NUM_PARALLEL_WORKERS:
%   Number of local MATLAB workers used when USE_PARALLEL is true.
config.USE_PARALLEL = true;
config.NUM_PARALLEL_WORKERS = 6;

% Relay Delay Configuration
config.relay = struct();
config.relay.REPORT_DELAYS_MS = ...
    [50 75 100 150 175 200 250 275 300 350 375 500 ...
     1000 2000 3000 5000 8000 10000];
config.relay.DELAY_MS_VEC = [0 config.relay.REPORT_DELAYS_MS];
config.relay.TARGET_FPR_VEC = [0.01 0.03 0.05];
config.relay.MIN_OVERLAP_SEC = 60;
config.relay.FISHER_R_CLIP = 0.9999999;

% Baseline ENF Extraction
config.baseline_enf_extract = struct();
config.baseline_enf_extract.analysis_name = 'baseline_enf_extract';
config.baseline_enf_extract.analysis_fs = 1050;
config.baseline_enf_extract.frame_size = 8000;
config.baseline_enf_extract.overlap_size = 0;
config.baseline_enf_extract.nfft = 32768;
config.baseline_enf_extract.nominal_freq = 60;
config.baseline_enf_extract.reference_method = 1;
config.baseline_enf_extract.sensed_method = 1;
config.baseline_enf_extract.reference_est_freq = 60;
config.baseline_enf_extract.sensed_est_freq = 60;
config.baseline_enf_extract.reference_harmonics = 60;
config.baseline_enf_extract.sensed_harmonics = 60;
config.baseline_enf_extract.reference_spec_comb_harmonics = 60;
config.baseline_enf_extract.sensed_spec_comb_harmonics = 60;

% High-Resolution ENF Extraction
config.high_res_enf_extract = struct();
config.high_res_enf_extract.analysis_name = 'high_res_enf_extract';
config.high_res_enf_extract.analysis_fs = 1050;
config.high_res_enf_extract.frame_size = 2100;
config.high_res_enf_extract.overlap_size = 1995;
config.high_res_enf_extract.nfft = 32768;
config.high_res_enf_extract.nominal_freq = 60;
config.high_res_enf_extract.reference_method = 2;
config.high_res_enf_extract.sensed_method = 2;
config.high_res_enf_extract.reference_est_freq = 60;
config.high_res_enf_extract.sensed_est_freq = 60;
config.high_res_enf_extract.reference_harmonics = [60 180 300];
config.high_res_enf_extract.sensed_harmonics = [60 180 300];
config.high_res_enf_extract.reference_spec_comb_harmonics = [60 180 300];
config.high_res_enf_extract.sensed_spec_comb_harmonics = [60 180 300];
config.high_res_enf_extract.lag_max_sec = 15;
config.high_res_enf_extract.lag_step_sec = 0.1;
config.high_res_enf_extract.interpolation_method = 'linear';
config.high_res_enf_extract.minimum_fixed_overlap_sec = 60;

% Results and Logging
config.results_root = fullfile(config.evaluation_root, 'exp_results', 'relay_attacks');
config.logs_root = fullfile(config.evaluation_root, 'exp_logs');
config.baseline_raw_csv = fullfile(config.results_root, ...
    'baseline_enf_extract', 'relay_attack_raw_results.csv');
config.high_res_raw_csv = fullfile(config.results_root, ...
    'high_res_enf_extract', 'relay_attack_raw_results.csv');
config.summary_csv = fullfile(config.results_root, ...
    'relay_attack_results_summary.csv');
config.tpr_figure = fullfile(config.results_root, ...
    'relay_attack_tpr_vs_injected_delay.svg');
config.pearson_figure = fullfile(config.results_root, ...
    'relay_attack_pearson_correlation_vs_injected_delay.svg');
config.log_file = fullfile(config.logs_root, ...
    'enf_analysis_top_relay_attacks_log.txt');


%% STEP_2) Setup: Logging and Output Directories
% Initialize shared processing, output roots, logging, and execution timing.
validate_configuration(config);
[fileID, cleanup_log] = open_analysis_log(config);
log_configuration(config, fileID);
analysis_timer = tic;

%% STEP_3) Input Discovery and Validation
% Verify the fixed 160-pair inventory and input-integrity hashes.
try
    relay_log(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    validate_final_trend_inputs(config);
catch execution_error
    relay_log(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_4) ENF Extraction and Raw Results
% Recompute or reuse only enabled analyses; high-resolution processing is always included.
try
    relay_log(fileID, '\nSTEP_4) ENF EXTRACTION AND RAW RESULTS\n%s\n', repmat('%',1,85));
    if config.RUN_ENF_EXTRACTION
        records = discover_trend_pairs(config, fileID);
        relay_log(fileID, 'Matched TREND measurements   : %d\n', numel(records));
        prepare_parallel_pool(config, fileID);

        if config.RUN_BASELINE
            baseline_raw = run_baseline_relay_analysis(records, config, fileID);
            validate_baseline_raw(baseline_raw, config);
            write_normalized_raw(baseline_raw, config.baseline_raw_csv, config.repository_root);
            relay_log(fileID, 'Baseline ENF extraction     : completed; raw CSV written\n');
        end

        high_res_raw = run_high_res_relay_analysis(records, config, fileID);
        validate_high_res_raw(high_res_raw, config);
        write_normalized_raw(high_res_raw, config.high_res_raw_csv, config.repository_root);
        relay_log(fileID, 'High-resolution ENF extraction: completed; raw CSV written\n');
    else
        if config.RUN_BASELINE
            if ~isfile(config.baseline_raw_csv)
                error(['Baseline raw relay result is missing: %s. Set ' ...
                    'RUN_ENF_EXTRACTION=true to recompute the raw relay results.'], ...
                    config.baseline_raw_csv);
            end
            baseline_raw = readtable(config.baseline_raw_csv, 'Delimiter', ',');
            baseline_raw = normalize_numeric_columns( ...
                baseline_raw, baseline_numeric_column_names(), 'baseline raw relay result');
            validate_baseline_raw(baseline_raw, config);
            relay_log(fileID, 'Baseline raw result          : loaded from raw-result CSV\n');
        end
        if ~isfile(config.high_res_raw_csv)
            error(['High-resolution raw relay result is missing: %s. Set ' ...
                'RUN_ENF_EXTRACTION=true to recompute the raw relay results.'], ...
                config.high_res_raw_csv);
        end

        high_res_raw = readtable(config.high_res_raw_csv, 'Delimiter', ',');
        high_res_raw = normalize_numeric_columns( ...
            high_res_raw, high_res_numeric_column_names(), ...
            'high-resolution raw relay result');
        high_res_raw = restore_cached_lag_grid(high_res_raw, config.high_res_enf_extract);
        validate_high_res_raw(high_res_raw, config);
        relay_log(fileID, 'High-resolution raw result   : loaded from raw-result CSV (extraction skipped)\n');
        relay_log(fileID, 'Lag representation           : aligned to the configured 0.1-s search grid\n');
    end
    if ~config.RUN_BASELINE
        relay_log(fileID, 'Baseline ENF extraction     : skipped\n');
    end
catch execution_error
    relay_log(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_5) Detection and Leave-One-Out Calibration
% Retain all three target FPRs, strict score comparisons, and the original group correction.
try
    relay_log(fileID, '\nSTEP_5) DETECTION AND LEAVE-ONE-OUT CALIBRATION\n%s\n', repmat('%',1,85));
    if config.RUN_BASELINE
        baseline_thresholds = build_baseline_thresholds(baseline_raw, config);
        baseline_detection = build_detection_results(baseline_raw, 'corr_delay', ...
            'LOWER', baseline_thresholds, config);
    end

    high_res_thresholds = build_high_res_thresholds( ...
        high_res_raw, 'abs_tau_hat_corr_sec', config);
    high_res_detection = build_detection_results(high_res_raw, ...
        'abs_tau_hat_corr_sec', 'UPPER', high_res_thresholds, config);

    high_res_leave_one_out = apply_leave_one_out_correction(high_res_raw);
    relay_log(fileID, 'Leave-one-out correction    : completed\n');
    leave_one_out_thresholds = build_high_res_thresholds( ...
        high_res_leave_one_out, 'abs_corrected_tau_corr', config);
    leave_one_out_detection = build_detection_results(high_res_leave_one_out, ...
        'abs_corrected_tau_corr', 'UPPER', leave_one_out_thresholds, config);
catch execution_error
    relay_log(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_6) Results and Figures
% Write six or nine summary rows and retain the one-curve corrected-lag TPR figure.
try
    relay_log(fileID, '\nSTEP_6) RESULTS AND FIGURES\n%s\n', repmat('%',1,85));
    if config.RUN_BASELINE
        summary = build_publication_summary(high_res_thresholds, high_res_detection, ...
            leave_one_out_thresholds, leave_one_out_detection, config, ...
            baseline_thresholds, baseline_detection);
    else
        summary = build_publication_summary(high_res_thresholds, high_res_detection, ...
            leave_one_out_thresholds, leave_one_out_detection, config);
    end
    writetable(summary, config.summary_csv);
    print_publication_summary(summary, config, fileID);
    plot_tpr_vs_delay(summary, config);
    relay_log(fileID, 'TPR figure                  : high-resolution leave-one-out, 1%% target FPR only\n');
    if config.RUN_BASELINE
        plot_baseline_pearson_correlation_vs_delay(baseline_raw, config);
        relay_log(fileID, 'Pearson correlation figure  : exp_evaluation/exp_results/relay_attacks/relay_attack_pearson_correlation_vs_injected_delay.svg\n');
    else
        retire_baseline_figure(config, fileID);
    end
catch execution_error
    relay_log(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_7) Final Summary and Logging
% Report actual runtime, output paths, and successful execution.
try
    relay_log(fileID, '\nSTEP_7) FINAL SUMMARY AND LOGGING\n%s\n', repmat('%',1,85));
    relay_log(fileID, '\nRuntime                     : %.2f minutes\n', ...
        toc(analysis_timer) / 60);
    relay_log(fileID, 'Summary CSV                 : exp_evaluation/exp_results/relay_attacks/relay_attack_results_summary.csv\n');
    relay_log(fileID, 'TPR figure                  : exp_evaluation/exp_results/relay_attacks/relay_attack_tpr_vs_injected_delay.svg\n');
    relay_log(fileID, 'Relay-delay analysis complete.\n');
    relay_log(fileID, 'Execution status: SUCCESS\nTotal execution time: %.3f s\n', toc(standardization_timer));
    clear cleanup_log;
catch execution_error
    relay_log(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% Local Functions
% Validate the fixed 160-pair TREND inventory and input-integrity hashes.
function validate_final_trend_inputs(config)
    files = dir(fullfile(config.trend_root, '**', '*.wav'));
    assert(numel(files) == 320, 'Relay:Inventory', 'Require exactly 320 TREND WAVs.');
    days = {'WDAY/WED', 'WDAY/THUR', 'WEND/SAT', 'WEND/SUN'};
    slots = {'EMRN', 'MORN', 'AFTN', 'EVEN'};
    for week = {'WK01', 'WK02'}
        for day = days
            for slot = slots
                for trial = config.allowed_leaf_folders
                    folder = fullfile(config.trend_root, week{1}, day{1}, slot{1}, trial{1});
                    for name = {config.reference_filename, config.sensed_filename}
                        path = fullfile(folder, name{1});
                        assert(isfile(path), 'Relay:MissingInput', 'Missing required TREND WAV: %s', path);
                        info = audioinfo(path);
                        assert(info.NumChannels == 1 && info.SampleRate == 44100 && ...
                            abs(info.TotalSamples - 200*44100) <= 1, ...
                            'Relay:WAVFormat', 'Expected mono 44100 Hz, nominal 200-second WAV: %s', path);
                    end
                end
            end
        end
    end
    target = fullfile(config.trend_root, 'WK01', 'WEND', 'SUN', 'MORN', 'T04');
    expected = {'37C5B67A7E2218D71A7D87F3B618B985743185CE3A45D07935687EECC48FEBF8', ...
        '1970D0B2B7C47084D1E2EB137CA8CC79D6E91CD8C0EA0C637E188FA24E89C8A6'};
    names = {config.reference_filename, config.sensed_filename};
    for ii = 1:2
        fileID = fopen(fullfile(target, names{ii}), 'rb');
        assert(fileID >= 0, 'Cannot read integrity-checked WAV.');
        bytes = fread(fileID, Inf, '*uint8'); fclose(fileID);
        engine = java.security.MessageDigest.getInstance('SHA-256');
        engine.update(typecast(bytes, 'int8'));
        digest = typecast(engine.digest(), 'uint8');
        actual = upper(reshape(dec2hex(digest, 2).', 1, []));
        assert(strcmp(actual, expected{ii}), 'Relay:InputHash', ...
            'SUN/MORN/T04 input SHA-256 mismatch for %s; stop.', names{ii});
    end
end

% Validate relay configuration, estimators, delays, and execution flags.
function validate_configuration(config)
    for flag = {'RUN_BASELINE', 'RUN_ENF_EXTRACTION'}
        value = config.(flag{1});
        assert(isscalar(value) && (islogical(value) || ...
            (isnumeric(value) && isfinite(value) && any(value == [0 1]))), ...
            '%s must be a scalar boolean value.', flag{1});
    end
    parallel_is_boolean = isscalar(config.USE_PARALLEL) && ...
        (islogical(config.USE_PARALLEL) || ...
        (isnumeric(config.USE_PARALLEL) && isfinite(config.USE_PARALLEL) && ...
        any(config.USE_PARALLEL == [0 1])));
    assert(parallel_is_boolean, ...
        'USE_PARALLEL must be a scalar logical or numeric boolean value.');
    workers = config.NUM_PARALLEL_WORKERS;
    assert(isnumeric(workers) && isscalar(workers) && isfinite(workers) && ...
        workers >= 1 && workers == floor(workers), ...
        'NUM_PARALLEL_WORKERS must be a positive integer.');
    delays = config.relay.REPORT_DELAYS_MS(:).';
    assert(~isempty(delays) && all(isfinite(delays)) && all(delays > 0) && ...
        numel(unique(delays)) == numel(delays) && issorted(delays), ...
        'Relay delays must be finite, positive, unique, and ordered.');
    assert(isequal(config.relay.DELAY_MS_VEC, [0 delays]), ...
        'DELAY_MS_VEC must contain no-attack followed by report delays.');
    fprs = config.relay.TARGET_FPR_VEC(:).';
    assert(all(isfinite(fprs)) && all(fprs > 0 & fprs < 1) && ...
        numel(unique(fprs)) == numel(fprs), ...
        'Target FPR values must be unique and strictly between zero and one.');
    assert(isequal(fprs, [0.01 0.03 0.05]), ...
        'Target FPR values must be 0.01, 0.03, and 0.05.');
    assert(config.relay.FISHER_R_CLIP == 0.9999999, ...
        'The Fisher-z correlation clip must be 0.9999999.');

    b = config.baseline_enf_extract;
    assert(b.analysis_fs == 1050 && b.frame_size == 8000 && ...
        b.overlap_size == 0 && b.nfft == 32768 && ...
        b.nominal_freq == 60 && b.reference_method == 1 && ...
        b.sensed_method == 1 && b.reference_est_freq == 60 && ...
        b.sensed_est_freq == 60 && isequal(b.reference_harmonics, 60) && ...
        isequal(b.sensed_harmonics, 60), ...
        'Baseline ENF estimator settings are invalid.');

    h = config.high_res_enf_extract;
    assert(h.analysis_fs == 1050 && h.frame_size == 2100 && ...
        h.overlap_size == 1995 && h.frame_size - h.overlap_size == 105 && ...
        h.nfft == 32768 && h.reference_method == 2 && ...
        h.sensed_method == 2 && ...
        isequal(h.reference_harmonics, [60 180 300]) && ...
        isequal(h.sensed_harmonics, [60 180 300]) && ...
        isequal(h.reference_spec_comb_harmonics, [60 180 300]) && ...
        isequal(h.sensed_spec_comb_harmonics, [60 180 300]), ...
        'High-resolution ENF estimator settings are invalid.');
    assert(h.lag_max_sec == 15 && h.lag_step_sec == 0.1 && ...
        strcmp(h.interpolation_method, 'linear') && ...
        h.minimum_fixed_overlap_sec == 60, ...
        'High-resolution lag-search settings are invalid.');
end

% Create result directories and open the cleanup-managed analysis log.
function [fileID, cleanup_log] = open_analysis_log(config)
    if ~isfolder(config.results_root)
        mkdir(config.results_root);
    end
    if config.RUN_BASELINE && ~isfolder(fileparts(config.baseline_raw_csv))
        mkdir(fileparts(config.baseline_raw_csv));
    end
    if ~isfolder(fileparts(config.high_res_raw_csv))
        mkdir(fileparts(config.high_res_raw_csv));
    end
    if ~isfolder(config.logs_root)
        mkdir(config.logs_root);
    end

    fileID = fopen(config.log_file, 'w');
    if fileID < 0
        error('Cannot open log file: %s', config.log_file);
    end
    cleanup_log = onCleanup(@() fclose(fileID));
end

% Report the fixed relay experiment and estimator configuration.
function log_configuration(config, fileID)
    relay_log(fileID, '%s\nENF RELAY ATTACKS\n%s\n', repmat('%',1,85), repmat('%',1,85));
relay_log(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
relay_log(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));
    relay_log(fileID, 'Dataset                      : exp_evaluation/exp_inputs/TREND/\n');
    states = {'disabled', 'enabled'};
    relay_log(fileID, 'RUN_BASELINE                : %s\n', states{1+config.RUN_BASELINE});
    relay_log(fileID, 'RUN_ENF_EXTRACTION          : %s\n', states{1+config.RUN_ENF_EXTRACTION});
    if config.USE_PARALLEL
        relay_log(fileID, 'Parallel processing          : enabled\n');
        relay_log(fileID, 'Parallel workers             : %d\n', ...
            config.NUM_PARALLEL_WORKERS);
    else
        relay_log(fileID, 'Parallel processing          : disabled\n');
    end
    relay_log(fileID, 'Relay delays (ms)            : %s\n', ...
        format_numeric_list(config.relay.REPORT_DELAYS_MS));
    relay_log(fileID, 'Target FPR values            : %s\n', ...
        format_percent_list(config.relay.TARGET_FPR_VEC));

    if config.RUN_BASELINE
        b = config.baseline_enf_extract;
        relay_log(fileID, ['Baseline ENF estimator       : frame=%d, overlap=%d, ' ...
            'nfft=%d, methods=%d/%d, harmonic=60 Hz\n'], ...
            b.frame_size, b.overlap_size, b.nfft, ...
            b.reference_method, b.sensed_method);
    end

    h = config.high_res_enf_extract;
    relay_log(fileID, ['High-resolution estimator    : Fs=%g Hz, frame=%d, ' ...
        'overlap=%d, hop=%d, nfft=%d, methods=%d/%d, harmonics=%s Hz\n'], ...
        h.analysis_fs, h.frame_size, h.overlap_size, ...
        h.frame_size - h.overlap_size, h.nfft, ...
        h.reference_method, h.sensed_method, ...
        format_numeric_list(h.reference_spec_comb_harmonics));
    relay_log(fileID, ['High-resolution lag search   : +/-%.1f s, %.1f-s step, ' ...
        '%s interpolation, %.0f-s minimum fixed overlap\n'], ...
        h.lag_max_sec, h.lag_step_sec, h.interpolation_method, ...
        h.minimum_fixed_overlap_sec);
    relay_log(fileID, ['Leave-one-out grouping       : Week + DayType + Day + ' ...
        'TimeOfDay; four other T0x no-attack measurements\n\n']);
end

% Create or reuse the configured local parallel pool.
function prepare_parallel_pool(config, fileID)
    if ~config.USE_PARALLEL
        return;
    end

    pool = gcp('nocreate');
    if ~isempty(pool) && pool.NumWorkers ~= config.NUM_PARALLEL_WORKERS
        delete(pool);
        pool = [];
    end

    if isempty(pool)
        pool = parpool('local', config.NUM_PARALLEL_WORKERS);
    end

    if pool.NumWorkers ~= config.NUM_PARALLEL_WORKERS
        error('Parallel pool worker count does not match NUM_PARALLEL_WORKERS.');
    end
end

% Discover and validate the ordered TREND measurement-pair inventory.
function records = discover_trend_pairs(config, fileID)
    sensed_files = dir(fullfile(config.trend_root, '**', config.sensed_filename));
    record_template = struct( ...
        'pair_id', 0, ...
        'measurement_folder', '', ...
        'reference_full_path', '', ...
        'reference_filename', '', ...
        'sensed_full_path', '', ...
        'sensed_filename', '', ...
        'Week', '', ...
        'DayType', '', ...
        'Day', '', ...
        'TimeOfDay', '', ...
        'LeafFolder', '');
    records = repmat(record_template, numel(sensed_files), 1);
    record_count = 0;

    for ii = 1:numel(sensed_files)
        folder = sensed_files(ii).folder;
        [~, leaf] = fileparts(folder);
        if ~ismember(upper(leaf), config.allowed_leaf_folders)
            continue;
        end

        reference_path = fullfile(folder, config.reference_filename);
        sensed_path = fullfile(folder, config.sensed_filename);
        if ~isfile(reference_path) || ~isfile(sensed_path)
            continue;
        end

        metadata = parse_trend_metadata(folder);
        record_count = record_count + 1;
        row = record_template;
        row.pair_id = record_count;
        row.measurement_folder = folder;
        row.reference_full_path = reference_path;
        row.reference_filename = config.reference_filename;
        row.sensed_full_path = sensed_path;
        row.sensed_filename = config.sensed_filename;
        row.Week = metadata.Week;
        row.DayType = metadata.DayType;
        row.Day = metadata.Day;
        row.TimeOfDay = metadata.TimeOfDay;
        row.LeafFolder = upper(leaf);
        records(record_count) = row;
    end

    records = records(1:record_count);
    if isempty(records)
        error('No matched TREND measurements were found.');
    end
end

% Parse week, day, time, and trial metadata from a TREND folder.
function metadata = parse_trend_metadata(folder)
    tokens = regexp(char(folder), '[^\\/]+', 'match');
    tokens = cellfun(@upper, tokens, 'UniformOutput', false);
    metadata.Week = first_matching_token(tokens, '^WK[0-9]+$', 'NA');
    metadata.DayType = first_from_list(tokens, {'WDAY', 'WEND'}, 'NA');
    metadata.Day = first_from_list(tokens, ...
        {'MON', 'TUE', 'WED', 'THU', 'THUR', 'FRI', 'SAT', 'SUN'}, 'NA');
    if strcmp(metadata.Day, 'THUR')
        metadata.Day = 'THU';
    end
    metadata.TimeOfDay = first_from_list( ...
        tokens, {'EMRN', 'MORN', 'AFTN', 'EVEN'}, 'NA');
    values = {metadata.Week, metadata.DayType, ...
        metadata.Day, metadata.TimeOfDay};
    if any(strcmp(values, 'NA'))
        error('Cannot parse TREND metadata from: %s', folder);
    end
end

% Return the first token matching a regular expression.
function value = first_matching_token(tokens, expression, default_value)
    value = default_value;
    for ii = 1:numel(tokens)
        if ~isempty(regexp(tokens{ii}, expression, 'once'))
            value = tokens{ii};
            return;
        end
    end
end

% Return the first token found in a fixed candidate list.
function value = first_from_list(tokens, candidates, default_value)
    value = default_value;
    for ii = 1:numel(candidates)
        if any(strcmp(tokens, candidates{ii}))
            value = candidates{ii};
            return;
        end
    end
end

% Run the optional baseline Pearson-correlation relay analysis.
function raw = run_baseline_relay_analysis(records, config, fileID)
    raw = run_relay_extraction( ...
        records, config.baseline_enf_extract, false, config, fileID);
    raw = normalize_baseline_table(raw, config.baseline_enf_extract);
end

% Run the high-resolution lag-based relay analysis.
function raw = run_high_res_relay_analysis(records, config, fileID)
    raw = run_relay_extraction( ...
        records, config.high_res_enf_extract, true, config, fileID);
    raw = normalize_high_res_table(raw, config.high_res_enf_extract);
end

% Execute relay extraction for every record and configured delay.
function raw = run_relay_extraction(records, estimator, include_lag, config, fileID)
    pair_count = numel(records);
    pair_rows = cell(pair_count, 1);
    estimator_timer = tic;
    analysis_name = estimator.analysis_name;

    if config.USE_PARALLEL
        parfor pp = 1:pair_count
            pair_rows{pp} = process_relay_pair( ...
                records(pp), estimator, include_lag, config);
        end
    else
        for pp = 1:pair_count
            pair_rows{pp} = process_relay_pair( ...
                records(pp), estimator, include_lag, config);
        end
    end

    estimator_runtime_min = toc(estimator_timer) / 60;
    if strcmp(analysis_name, 'baseline_enf_extract')
        relay_log(fileID, ...
            'Baseline extraction runtime       : %.2f minutes\n', ...
            estimator_runtime_min);
    elseif strcmp(analysis_name, 'high_res_enf_extract')
        relay_log(fileID, ...
            'High-resolution extraction runtime: %.2f minutes\n', ...
            estimator_runtime_min);
    end

    rows = vertcat(pair_rows{:});
    raw = struct2table(rows);
end

% Inject each source-sample delay and process one recording pair.
function pair_rows = process_relay_pair(info, estimator, include_lag, config)
    row_template = struct( ...
        'pair_id', 0, ...
        'measurement_folder', '', ...
        'Week', '', ...
        'DayType', '', ...
        'Day', '', ...
        'TimeOfDay', '', ...
        'LeafFolder', '', ...
        'reference_file', '', ...
        'sensed_file', '', ...
        'reference_full_path', '', ...
        'sensed_full_path', '', ...
        'effective_sample_rate_hz', NaN, ...
        'delay_ms', NaN, ...
        'delay_sec', NaN, ...
        'eval_duration_sec', NaN, ...
        'corr_delay', NaN, ...
        'tau_hat_corr_sec', NaN, ...
        'abs_tau_hat_corr_sec', NaN);
    delay_count = numel(config.relay.DELAY_MS_VEC);
    pair_rows = repmat(row_template, delay_count, 1);

    reference = load_wav_trace( ...
        info.reference_full_path, info.reference_filename);
    sensed = load_wav_trace(info.sensed_full_path, info.sensed_filename);
    if reference.source_fs ~= sensed.source_fs
        error('Sample-rate mismatch for pair %d: %.12g versus %.12g Hz.', ...
            info.pair_id, reference.source_fs, sensed.source_fs);
    end

    effective_fs = effective_analysis_fs(reference.source_fs);
    if effective_fs ~= estimator.analysis_fs
        error('%s requires %.12g Hz but pair %d resolves to %.12g Hz.', ...
            estimator.analysis_name, estimator.analysis_fs, ...
            info.pair_id, effective_fs);
    end

    common_count = min(reference.num_samples, sensed.num_samples);
    extracted_segments = containers.Map('KeyType', 'char', 'ValueType', 'any');
    for dd = 1:delay_count
        delay_ms = config.relay.DELAY_MS_VEC(dd);
        delay_samples = round((delay_ms / 1000) * reference.source_fs);
        eval_count = common_count - delay_samples;
        if eval_count < 1
            error('Delay removes pair %d overlap.', info.pair_id);
        end

        % The FPGA signal is delayed by d. The valid comparison is
        % reference(d+1:N) against FPGA(1:N-d).
        start_ref = delay_samples + 1;
        end_ref = common_count;
        start_fpga = 1;
        end_fpga = common_count - delay_samples;
        duration_sec = eval_count / reference.source_fs;
        if duration_sec < max(config.relay.MIN_OVERLAP_SEC, ...
                estimator.frame_size / effective_fs)
            error('Pair %d delay %g ms has insufficient overlap.', ...
                info.pair_id, delay_ms);
        end

        [enf_ref, enf_fpga, extracted_segments] = fetch_pair_enfs( ...
            extracted_segments, reference, start_ref, end_ref, sensed, ...
            start_fpga, end_fpga, estimator);
        corr_delay = NaN;
        tau_hat_corr_sec = NaN;
        abs_tau_hat_corr_sec = NaN;
        if include_lag
            tau_hat_corr_sec = estimate_correlation_lag( ...
                enf_ref, enf_fpga, effective_fs, estimator);
            abs_tau_hat_corr_sec = abs(tau_hat_corr_sec);
        else
            corr_delay = correlate_enf_lag_zero(enf_ref, enf_fpga);
            if ~isfinite(corr_delay)
                error('Pair %d delay %g ms has invalid Pearson correlation.', ...
                    info.pair_id, delay_ms);
            end
        end

        row = row_template;
        row.pair_id = info.pair_id;
        row.measurement_folder = info.measurement_folder;
        row.Week = info.Week;
        row.DayType = info.DayType;
        row.Day = info.Day;
        row.TimeOfDay = info.TimeOfDay;
        row.LeafFolder = info.LeafFolder;
        row.reference_file = info.reference_filename;
        row.sensed_file = info.sensed_filename;
        row.reference_full_path = info.reference_full_path;
        row.sensed_full_path = info.sensed_full_path;
        row.effective_sample_rate_hz = effective_fs;
        row.delay_ms = delay_ms;
        row.delay_sec = delay_ms / 1000;
        row.eval_duration_sec = duration_sec;
        row.corr_delay = corr_delay;
        row.tau_hat_corr_sec = tau_hat_corr_sec;
        row.abs_tau_hat_corr_sec = abs_tau_hat_corr_sec;
        pair_rows(dd) = row;
    end

    if numel(pair_rows) ~= delay_count
        error('Pair %d did not produce every configured delay.', info.pair_id);
    end
end

% Load and validate one mono WAV trace.
function trace = load_wav_trace(full_path, filename)
    audio_metadata = audioinfo(full_path);
    waveform = audioread(full_path);
    if size(waveform, 2) > 1
        waveform = mean(waveform, 2);
    end
    waveform = double(waveform(:));
    if isempty(waveform) || any(~isfinite(waveform))
        error('Invalid WAV data: %s', full_path);
    end
    trace.full_path = full_path;
    trace.filename = filename;
    trace.waveform = waveform;
    trace.source_fs = double(audio_metadata.SampleRate);
    trace.num_samples = numel(waveform);
end

% Map a supported source sample rate to its analysis sample rate.
function fs = effective_analysis_fs(source_fs)
    if source_fs == 44100
        fs = 1050;
    elseif source_fs == 1050 || source_fs == 1000
        fs = source_fs;
    else
        error('Unsupported source sample rate: %.12g Hz.', source_fs);
    end
end

% Extract or reuse the reference and sensed ENF series for one segment.
function [enf_ref, enf_fpga, reuse] = fetch_pair_enfs( ...
        reuse, reference, start_ref, end_ref, sensed, start_fpga, ...
        end_fpga, estimator)
    ref_key = segment_key( ...
        reference, start_ref, end_ref, estimator, 'reference');
    fpga_key = segment_key( ...
        sensed, start_fpga, end_fpga, estimator, 'sensed');
    has_ref = isKey(reuse, ref_key);
    has_fpga = isKey(reuse, fpga_key);

    if has_ref
        enf_ref = reuse(ref_key);
    end
    if has_fpga
        enf_fpga = reuse(fpga_key);
    end
    if has_ref && has_fpga
        return;
    end

    if ~has_ref && ~has_fpga
        segment_ref = reference.waveform(start_ref:end_ref);
        segment_fpga = sensed.waveform(start_fpga:end_fpga);
        [enf_ref, enf_fpga] = extract_enf_pair( ...
            segment_ref, reference.source_fs, segment_fpga, ...
            sensed.source_fs, estimator);
        reuse(ref_key) = enf_ref;
        reuse(fpga_key) = enf_fpga;
    elseif ~has_ref
        segment_ref = reference.waveform(start_ref:end_ref);
        [enf_ref, ~] = extract_enf_pair( ...
            segment_ref, reference.source_fs, segment_ref, ...
            reference.source_fs, estimator);
        reuse(ref_key) = enf_ref;
    else
        segment_fpga = sensed.waveform(start_fpga:end_fpga);
        [~, enf_fpga] = extract_enf_pair( ...
            segment_fpga, sensed.source_fs, segment_fpga, ...
            sensed.source_fs, estimator);
        reuse(fpga_key) = enf_fpga;
    end
end

% Build the cache key for one trace segment and estimator role.
function key = segment_key(trace, start_sample, end_sample, estimator, role)
    key = sprintf( ...
        ['%s|%s|sourcefs=%.12g|start=%d|end=%d|frame=%d|' ...
        'overlap=%d|nfft=%d|methods=%d/%d|harmonics=%s/%s'], ...
        lower(trace.full_path), role, trace.source_fs, ...
        start_sample, end_sample, ...
        estimator.frame_size, estimator.overlap_size, estimator.nfft, ...
        estimator.reference_method, estimator.sensed_method, ...
        format_numeric_list(estimator.reference_harmonics), ...
        format_numeric_list(estimator.sensed_harmonics));
end

% Extract one ENF pair with the shared protected processor.
function [enf_ref, enf_fpga] = extract_enf_pair( ...
        reference, reference_fs, sensed, sensed_fs, estimator)
    [~, ~, ~, ~, enf_ref, enf_fpga] = proc_enf_analysis( ...
        reference, sensed, estimator.nfft, estimator.frame_size, ...
        estimator.overlap_size, estimator.reference_harmonics, ...
        estimator.nominal_freq, estimator.sensed_harmonics, ...
        estimator.nominal_freq, estimator.reference_method, ...
        estimator.reference_est_freq, ...
        estimator.reference_spec_comb_harmonics, ...
        estimator.sensed_method, estimator.sensed_est_freq, ...
        estimator.sensed_spec_comb_harmonics, ...
        'TREND reference segment', 'TREND FPGA segment', false, ...
        'Fs1', reference_fs, 'Fs2', sensed_fs, ...
        'LegacyNumericInputHandling', true, ...
        'Quiet', true, 'lagOptEnable', false, ...
        'minOverlapSec', 60, ...
        'lagLogPath', '');
    enf_ref = double(enf_ref(:));
    enf_fpga = double(enf_fpga(:));
    if isempty(enf_ref) || isempty(enf_fpga) || ...
            any(~isfinite(enf_ref)) || any(~isfinite(enf_fpga))
        error('ENF extraction produced empty or non-finite values.');
    end
end

% Calculate zero-lag Pearson correlation over the common ENF support.
function value = correlate_enf_lag_zero(enf_ref, enf_fpga)
    n = min(numel(enf_ref), numel(enf_fpga));
    if n < 2
        value = NaN;
        return;
    end
    a = double(enf_ref(1:n));
    b = double(enf_fpga(1:n));
    a = a(:) - mean(a);
    b = b(:) - mean(b);
    denominator = sqrt((a'*a)*(b'*b));
    if ~isfinite(denominator) || denominator <= 0
        value = NaN;
    else
        value = (a'*b) / denominator;
    end
end

% Estimate relay lag on the fixed grid with interpolation and tie-breaking.
function tau_hat = estimate_correlation_lag(enf_ref, enf_fpga, effective_fs, estimator)
    hop_sec = (estimator.frame_size - estimator.overlap_size) / effective_fs;
    t_ref = (0:numel(enf_ref) - 1).'*hop_sec;
    t_fpga = (0:numel(enf_fpga) - 1).'*hop_sec;
    if numel(t_ref)<2 || numel(t_fpga)<2
        error('High-resolution lag search requires at least two ENF samples.');
    end
    lag_steps = round(estimator.lag_max_sec / estimator.lag_step_sec);
    candidate_lags = (-lag_steps:lag_steps).'*estimator.lag_step_sec;
    common_end = min(t_ref(end), t_fpga(end));
    tolerance = 32 * eps(max(1, common_end));
    support = t_ref >= (estimator.lag_max_sec - tolerance) & ...
        t_ref <= (common_end - estimator.lag_max_sec + tolerance);
    t_eval = t_ref(support);
    ref_eval = enf_ref(support);
    if numel(t_eval)<2 || t_eval(end) - t_eval(1)<estimator.minimum_fixed_overlap_sec
        error('High-resolution fixed lag support is shorter than 60 seconds.');
    end
    query_time = t_eval + candidate_lags.';
    query_time(abs(query_time - t_fpga(1)) <= tolerance) = t_fpga(1);
    query_time(abs(query_time - t_fpga(end)) <= tolerance) = t_fpga(end);
    fpga_at_lags = interp1(t_fpga, enf_fpga, query_time, ...
        estimator.interpolation_method, NaN);
    if any(~isfinite(fpga_at_lags(:)))
        error('Interpolation left the fixed high-resolution lag support.');
    end
    correlations = nan(numel(candidate_lags), 1);
    for ii = 1:numel(candidate_lags)
        % Sign convention: reference(t) is compared with FPGA(t + tau).
        correlations(ii) = correlate_enf_lag_zero(ref_eval, fpga_at_lags(:, ii));
    end
    best_value = max(correlations);
    score_tolerance = 1e-10 * max(1, abs(best_value));
    equivalent = find(abs(correlations - best_value) <= score_tolerance);
    candidates = [abs(candidate_lags(equivalent)) candidate_lags(equivalent)];
    [~, order] = sortrows(candidates, [1 2]);
    tau_hat = candidate_lags(equivalent(order(1)));
end

% Check whether a table column matches the expected harmonic vector.
function matches = harmonic_column_matches(column, expected)
    matches = true;
    for ii = 1:numel(column)
        if iscell(column)
            value = column{ii};
        else
            value = column(ii);
        end
        if isnumeric(value)
            parsed = double(value(:).');
        else
            tokens = regexp(char(value), '[-+]?[0-9]*\.?[0-9]+', 'match');
            parsed = str2double(tokens);
        end
        if ~isequal(parsed, double(expected(:).'))
            matches = false;
            return;
        end
    end
end

% Restore serialized lag values to the configured fixed search grid.
function raw = restore_cached_lag_grid(raw, estimator)
    % writetable decimal serialization loses the binary representation of n*step.
    % Reconstruct the exact configured search-grid value before strict comparisons.
    assert(all(abs(raw.abs_tau_hat_corr_sec - abs(raw.tau_hat_corr_sec)) <= 1e-12), ...
        'Cached signed and absolute lag values disagree.');
    step = estimator.lag_step_sec;
    restored = round(raw.tau_hat_corr_sec / step) * step;
    assert(all(isfinite(restored)) && ...
        all(abs(restored - raw.tau_hat_corr_sec) <= 1e-12), ...
        'Cached lags are not on the configured search grid.');
    raw.tau_hat_corr_sec = restored;
    raw.abs_tau_hat_corr_sec = abs(restored);
end

% Normalize a baseline raw-result table to the established schema.
function raw = normalize_baseline_table(source, estimator)
    required = {'pair_id', 'measurement_folder', 'Week', 'DayType', 'Day', ...
        'TimeOfDay', 'LeafFolder', 'reference_file', 'sensed_file', ...
        'reference_full_path', 'sensed_full_path', 'effective_sample_rate_hz', ...
        'delay_ms', 'delay_sec', 'eval_duration_sec', 'corr_delay'};
    require_columns(source, required, 'baseline raw source');
    n = height(source);
    analysis_name = repmat({estimator.analysis_name}, n, 1);
    pair_id = source.pair_id;
    measurement_folder = source.measurement_folder;
    Week = source.Week;
    DayType = source.DayType;
    Day = source.Day;
    TimeOfDay = source.TimeOfDay;
    LeafFolder = source.LeafFolder;
    reference_file = source.reference_file;
    sensed_file = source.sensed_file;
    reference_full_path = source.reference_full_path;
    sensed_full_path = source.sensed_full_path;
    effective_sample_rate_hz = source.effective_sample_rate_hz;
    frame_size_samples = repmat(estimator.frame_size, n, 1);
    overlap_size_samples = repmat(estimator.overlap_size, n, 1);
    nfft = repmat(estimator.nfft, n, 1);
    reference_method = repmat(estimator.reference_method, n, 1);
    sensed_method = repmat(estimator.sensed_method, n, 1);
    enf_hop_sec = repmat((estimator.frame_size - estimator.overlap_size)/ ...
        estimator.analysis_fs, n, 1);
    delay_ms = source.delay_ms;
    delay_sec = source.delay_sec;
    eval_duration_sec = source.eval_duration_sec;
    corr_delay = source.corr_delay;
    raw = table( ...
        analysis_name, pair_id, measurement_folder, Week, DayType, Day, ...
        TimeOfDay, LeafFolder, reference_file, sensed_file, ...
        reference_full_path, ...
        sensed_full_path, effective_sample_rate_hz, frame_size_samples, ...
        overlap_size_samples, nfft, reference_method, sensed_method, enf_hop_sec, ...
        delay_ms, delay_sec, eval_duration_sec, corr_delay);
end

% Normalize a high-resolution raw-result table to the established schema.
function raw = normalize_high_res_table(source, estimator)
    required = {'pair_id', 'measurement_folder', 'Week', 'DayType', 'Day', ...
        'TimeOfDay', 'LeafFolder', 'reference_file', 'sensed_file', ...
        'reference_full_path', 'sensed_full_path', 'effective_sample_rate_hz', ...
        'delay_ms', 'delay_sec', 'eval_duration_sec', 'tau_hat_corr_sec', ...
        'abs_tau_hat_corr_sec'};
    require_columns(source, required, 'high-resolution raw source');
    n = height(source);
    analysis_name = repmat({estimator.analysis_name}, n, 1);
    pair_id = source.pair_id;
    measurement_folder = source.measurement_folder;
    Week = source.Week;
    DayType = source.DayType;
    Day = source.Day;
    TimeOfDay = source.TimeOfDay;
    LeafFolder = source.LeafFolder;
    reference_file = source.reference_file;
    sensed_file = source.sensed_file;
    reference_full_path = source.reference_full_path;
    sensed_full_path = source.sensed_full_path;
    effective_sample_rate_hz = source.effective_sample_rate_hz;
    frame_size_samples = repmat(estimator.frame_size, n, 1);
    overlap_size_samples = repmat(estimator.overlap_size, n, 1);
    nfft = repmat(estimator.nfft, n, 1);
    reference_method = repmat(estimator.reference_method, n, 1);
    sensed_method = repmat(estimator.sensed_method, n, 1);
    harmonic_text = format_numeric_list(estimator.reference_spec_comb_harmonics);
    reference_spec_comb_harmonics = repmat({harmonic_text}, n, 1);
    sensed_spec_comb_harmonics = repmat({harmonic_text}, n, 1);
    enf_hop_sec = repmat((estimator.frame_size - estimator.overlap_size)/ ...
        estimator.analysis_fs, n, 1);
    lag_search_max_sec = repmat(estimator.lag_max_sec, n, 1);
    lag_search_step_sec = repmat(estimator.lag_step_sec, n, 1);
    lag_interpolation_method = repmat({estimator.interpolation_method}, n, 1);
    lag_minimum_fixed_overlap_sec = ...
        repmat(estimator.minimum_fixed_overlap_sec, n, 1);
    delay_ms = source.delay_ms;
    delay_sec = source.delay_sec;
    eval_duration_sec = source.eval_duration_sec;
    tau_hat_corr_sec = source.tau_hat_corr_sec;
    abs_tau_hat_corr_sec = source.abs_tau_hat_corr_sec;
    raw = table( ...
        analysis_name, pair_id, measurement_folder, Week, DayType, Day, ...
        TimeOfDay, LeafFolder, reference_file, sensed_file, ...
        reference_full_path, ...
        sensed_full_path, effective_sample_rate_hz, frame_size_samples, ...
        overlap_size_samples, nfft, reference_method, sensed_method, ...
        reference_spec_comb_harmonics, sensed_spec_comb_harmonics, enf_hop_sec, ...
        lag_search_max_sec, lag_search_step_sec, lag_interpolation_method, ...
        lag_minimum_fixed_overlap_sec, delay_ms, delay_sec, ...
        eval_duration_sec, tau_hat_corr_sec, ...
        abs_tau_hat_corr_sec);
end

% Write a normalized raw-result table to its configured CSV.
function write_normalized_raw(raw, csv_path, repository_root)
    folder = fileparts(csv_path);
    if ~isfolder(folder)
        mkdir(folder);
    end
    % Serialize portable paths without changing file-loading records or caller data.
    prefix = [strrep(repository_root, '\', '/') '/'];
    path_columns = {'measurement_folder', 'reference_full_path', 'sensed_full_path'};
    for index = 1:numel(path_columns)
        name = path_columns{index};
        paths = strrep(string(raw.(name)), '\', '/');
        assert(all(startsWith(paths, prefix)), ...
            'Raw-result paths must be inside the repository: %s.', name);
        raw.(name) = extractAfter(paths, strlength(prefix));
    end
    writetable(raw, csv_path);
end

% Return the numeric columns required by baseline raw results.
function names = baseline_numeric_column_names()
    names = {'pair_id', 'effective_sample_rate_hz', 'frame_size_samples', ...
        'overlap_size_samples', 'nfft', 'reference_method', ...
        'sensed_method', 'enf_hop_sec', 'delay_ms', 'delay_sec', ...
        'eval_duration_sec', 'corr_delay'};
end

% Return the numeric columns required by high-resolution raw results.
function names = high_res_numeric_column_names()
    names = {'pair_id', 'effective_sample_rate_hz', 'frame_size_samples', ...
        'overlap_size_samples', 'nfft', 'reference_method', ...
        'sensed_method', 'enf_hop_sec', 'lag_search_max_sec', ...
        'lag_search_step_sec', 'lag_minimum_fixed_overlap_sec', ...
        'delay_ms', 'delay_sec', 'eval_duration_sec', ...
        'tau_hat_corr_sec', 'abs_tau_hat_corr_sec'};
end

% Normalize required table columns to finite numeric values.
function output = normalize_numeric_columns(input, column_names, table_label)
    require_columns(input, column_names, table_label);
    output = input;

    for ii = 1:numel(column_names)
        column_name = column_names{ii};
        values = output.(column_name);
        if isnumeric(values)
            continue;
        end

        if iscell(values)
            if all(cellfun(@isnumeric, values))
                converted = cellfun(@double, values);
            else
                converted = str2double(values);
            end
        elseif ischar(values)
            converted = str2double(cellstr(values));
        else
            error('%s column %s cannot be converted to numeric values.', ...
                table_label, column_name);
        end

        if any(~isfinite(converted))
            error('%s column %s contains invalid numeric text.', ...
                table_label, column_name);
        end
        output.(column_name) = converted;
    end
end

% Validate baseline raw-result values and schema.
function validate_baseline_raw(raw, config)
    required = {'analysis_name', 'pair_id', 'measurement_folder', 'Week', ...
        'DayType', 'Day', 'TimeOfDay', 'LeafFolder', 'reference_file', 'sensed_file', ...
        'reference_full_path', 'sensed_full_path', 'effective_sample_rate_hz', ...
        'frame_size_samples', 'overlap_size_samples', 'nfft', 'reference_method', ...
        'sensed_method', 'enf_hop_sec', 'delay_ms', 'delay_sec', ...
        'eval_duration_sec', 'corr_delay'};
    require_columns(raw, required, 'baseline_enf_extract raw result');
    assert(all(strcmp(raw.analysis_name, 'baseline_enf_extract')), ...
        'Baseline analysis_name values are invalid.');
    b = config.baseline_enf_extract;
    assert(all(raw.effective_sample_rate_hz == b.analysis_fs) && ...
        all(raw.frame_size_samples == b.frame_size) && ...
        all(raw.overlap_size_samples == b.overlap_size) && ...
        all(raw.nfft == b.nfft) && all(raw.reference_method == 1) && ...
        all(raw.sensed_method == 1), 'Baseline estimator metadata is invalid.');
    validate_common_raw(raw, config, 'corr_delay');
end

% Validate high-resolution raw-result values, lags, and schema.
function validate_high_res_raw(raw, config)
    required = {'analysis_name', 'pair_id', 'measurement_folder', 'Week', ...
        'DayType', 'Day', 'TimeOfDay', 'LeafFolder', 'reference_file', 'sensed_file', ...
        'reference_full_path', 'sensed_full_path', 'effective_sample_rate_hz', ...
        'frame_size_samples', 'overlap_size_samples', 'nfft', 'reference_method', ...
        'sensed_method', 'reference_spec_comb_harmonics', ...
        'sensed_spec_comb_harmonics', 'enf_hop_sec', 'lag_search_max_sec', ...
        'lag_search_step_sec', 'lag_interpolation_method', ...
        'lag_minimum_fixed_overlap_sec', 'delay_ms', 'delay_sec', ...
        'eval_duration_sec', 'tau_hat_corr_sec', 'abs_tau_hat_corr_sec'};
    require_columns(raw, required, 'high_res_enf_extract raw result');
    assert(all(strcmp(raw.analysis_name, 'high_res_enf_extract')), ...
        'High-resolution analysis_name values are invalid.');
    h = config.high_res_enf_extract;
    expected_hop_sec = (h.frame_size - h.overlap_size) / h.analysis_fs;
    assert(all(raw.effective_sample_rate_hz == h.analysis_fs) && ...
        all(raw.frame_size_samples == h.frame_size) && ...
        all(raw.overlap_size_samples == h.overlap_size) && ...
        all(raw.nfft == h.nfft) && all(raw.reference_method == 2) && ...
        all(raw.sensed_method == 2) && ...
        all(abs(raw.enf_hop_sec - expected_hop_sec) < 1e-12), ...
        'High-resolution estimator metadata is invalid.');
    assert(all(raw.lag_search_max_sec == h.lag_max_sec) && ...
        all(abs(raw.lag_search_step_sec - h.lag_step_sec) < 1e-12) && ...
        all(strcmp(raw.lag_interpolation_method, h.interpolation_method)) && ...
        all(raw.lag_minimum_fixed_overlap_sec == h.minimum_fixed_overlap_sec), ...
        'High-resolution lag-search metadata is invalid.');
    assert(harmonic_column_matches(raw.reference_spec_comb_harmonics, ...
        h.reference_spec_comb_harmonics) && ...
        harmonic_column_matches(raw.sensed_spec_comb_harmonics, ...
        h.sensed_spec_comb_harmonics), ...
        'High-resolution harmonic metadata is invalid.');
    difference = abs(raw.abs_tau_hat_corr_sec - abs(raw.tau_hat_corr_sec));
    tolerance = 1e-10 * max(ones(height(raw), 1), abs(raw.tau_hat_corr_sec));
    assert(all(difference <= tolerance), ...
        'Signed and absolute high-resolution correlation lags disagree.');
    assert(all(raw.abs_tau_hat_corr_sec <= ...
        h.lag_max_sec + h.lag_step_sec * 1e-9), ...
        'High-resolution correlation lag exceeds the configured search range.');
    validate_common_raw(raw, config, 'tau_hat_corr_sec');
end

% Validate fields shared by all raw relay-result tables.
function validate_common_raw(raw, config, score_column)
    if isempty(raw), error('Raw result table is empty.'); end
    numeric_columns = {'pair_id', 'delay_ms', 'delay_sec', 'eval_duration_sec', score_column};
    for ii = 1:numel(numeric_columns)
        assert(all(isfinite(raw.(numeric_columns{ii}))), ...
            'Raw column %s contains non-finite values.', numeric_columns{ii});
    end
    assert(all(abs(raw.delay_sec - raw.delay_ms / 1000) < 1e-12), ...
        'Raw delay_ms and delay_sec values disagree.');
    keys = arrayfun(@(pair, delay) sprintf('%.12g|%.12g', pair, delay), ...
        raw.pair_id, raw.delay_ms, 'UniformOutput', false);
    assert(numel(unique(keys)) == height(raw), 'Duplicate pair/delay rows were found.');
    pair_ids = unique(raw.pair_id);
    expected_delays = sort(config.relay.DELAY_MS_VEC(:));
    for pp = 1:numel(pair_ids)
        selected = raw.pair_id == pair_ids(pp);
        assert(isequal(sort(raw.delay_ms(selected)), expected_delays), ...
            'Pair %g does not contain every configured delay exactly once.', pair_ids(pp));
        assert(sum(selected & raw.delay_ms == 0) == 1, ...
            'Pair %g must contain exactly one no-attack row.', pair_ids(pp));
    end
end

% Apply the established leave-one-out group lag correction.
function corrected = apply_leave_one_out_correction(raw)
    required = {'pair_id', 'Week', 'DayType', 'Day', 'TimeOfDay', 'LeafFolder', ...
        'delay_ms', 'tau_hat_corr_sec'};
    require_columns(raw, required, 'leave-one-out source');
    metadata_columns = {'Week', 'DayType', 'Day', 'TimeOfDay', 'LeafFolder'};
    for mm = 1:numel(metadata_columns)
        values = raw.(metadata_columns{mm});
        if any(cellfun(@isempty, values)) || any(strcmp(values, 'NA'))
            error('Leave-one-out grouping metadata is incomplete in %s.', ...
                metadata_columns{mm});
        end
    end
    corrected = raw;
    corrected.leave_one_out_group_median_tau_corr_sec = nan(height(raw), 1);
    corrected.corrected_tau_corr = nan(height(raw), 1);
    corrected.abs_corrected_tau_corr = nan(height(raw), 1);
    no_attack = raw(raw.delay_ms == 0, :);
    expected_leaves = {'T01', 'T02', 'T03', 'T04', 'T05'};
    pair_ids = unique(raw.pair_id);
    for pp = 1:numel(pair_ids)
        target_id = pair_ids(pp);
        target = no_attack(no_attack.pair_id == target_id, :);
        if height(target) ~= 1, error('Pair %g must have one no-attack row.', target_id); end
        same_group = strcmp(no_attack.Week, target.Week{1}) & ...
            strcmp(no_attack.DayType, target.DayType{1}) & ...
            strcmp(no_attack.Day, target.Day{1}) & ...
            strcmp(no_attack.TimeOfDay, target.TimeOfDay{1});
        group = no_attack(same_group, :);
        group_leaves = sort(unique(group.LeafFolder));
        if height(group) ~= 5 || ~isequal(group_leaves(:), sort(expected_leaves(:)))
            error(['Acquisition group %s|%s|%s|%s for target %s must ' ...
                'contain T01 through T05 exactly once.'], target.Week{1}, ...
                target.DayType{1}, target.Day{1}, target.TimeOfDay{1}, ...
                target.LeafFolder{1});
        end
        others = group(group.pair_id ~= target_id, :);
        if height(others) ~= 4 || numel(unique(others.LeafFolder)) ~= 4
            error(['Acquisition group %s|%s|%s|%s target %s requires ' ...
                'exactly four other no-attack T0x measurements.'], ...
                target.Week{1}, target.DayType{1}, target.Day{1}, ...
                target.TimeOfDay{1}, target.LeafFolder{1});
        end
        offset = median(others.tau_hat_corr_sec);
        target_rows = raw.pair_id == target_id;
        corrected.leave_one_out_group_median_tau_corr_sec(target_rows) = offset;
        corrected.corrected_tau_corr(target_rows) = raw.tau_hat_corr_sec(target_rows) - offset;
        corrected.abs_corrected_tau_corr(target_rows) = ...
            abs(corrected.corrected_tau_corr(target_rows));
    end
    assert(all(isfinite(corrected.abs_corrected_tau_corr)), ...
        'Leave-one-out correction produced non-finite scores.');
end

% Calibrate baseline detector thresholds for each target false-positive rate.
function thresholds = build_baseline_thresholds(raw, config)
    target_fprs = config.relay.TARGET_FPR_VEC;
    no_attack = raw(raw.delay_ms == 0, :);
    clipped_r = max(-config.relay.FISHER_R_CLIP, ...
        min(config.relay.FISHER_R_CLIP, no_attack.corr_delay));
    z_values = atanh(clipped_r);
    if isempty(z_values) || any(~isfinite(z_values))
        error('Baseline no-attack Fisher-z values are empty or non-finite.');
    end
    mean_z = mean(z_values);
    std_z = std(z_values, 0);
    if ~isfinite(std_z) || std_z <= 0
        error('Baseline no-attack Fisher-z standard deviation must be positive.');
    end
    rows = cell(numel(target_fprs), 1);
    for ii = 1:numel(target_fprs)
        target_fpr = target_fprs(ii);
        threshold = tanh(mean_z + std_z * norminv(target_fpr));
        false_positive_count = sum(no_attack.corr_delay<threshold);
        true_negative_count = height(no_attack) - false_positive_count;
        assert(false_positive_count + true_negative_count == height(no_attack), ...
            'Baseline FP and TN counts do not cover all no-attack rows.');
        empirical_fpr = false_positive_count / height(no_attack);
        rows{ii} = table(target_fpr, threshold, empirical_fpr, height(no_attack), ...
            false_positive_count, true_negative_count, mean_z, std_z, ...
            'VariableNames', {'target_fpr', 'threshold', 'empirical_fpr', ...
            'no_attack_count', 'false_positive_count', 'true_negative_count', ...
            'fisher_z_mean', 'fisher_z_std'});
    end
    thresholds = vertcat(rows{:});
end

% Calibrate lag-detector thresholds for each target false-positive rate.
function thresholds = build_high_res_thresholds(raw, score_name, config)
    target_fprs = config.relay.TARGET_FPR_VEC;
    no_attack = raw(raw.delay_ms == 0, :);
    scores = no_attack.(score_name);
    if isempty(scores) || any(~isfinite(scores))
        error('High-resolution no-attack lag scores are empty or non-finite.');
    end
    rows = cell(numel(target_fprs), 1);
    for ii = 1:numel(target_fprs)
        target_fpr = target_fprs(ii);
        threshold = quantile(scores, 1 - target_fpr);
        false_positive_count = sum(scores>threshold);
        true_negative_count = height(no_attack) - false_positive_count;
        assert(false_positive_count + true_negative_count == height(no_attack), ...
            'Lag-detector FP and TN counts do not cover all no-attack rows.');
        empirical_fpr = false_positive_count / height(no_attack);
        rows{ii} = table(target_fpr, threshold, empirical_fpr, height(no_attack), ...
            false_positive_count, true_negative_count, 'VariableNames', ...
            {'target_fpr', 'threshold', 'empirical_fpr', 'no_attack_count', ...
            'false_positive_count', 'true_negative_count'});
    end
    thresholds = vertcat(rows{:});
end

% Calculate detection statistics across injected relay delays.
function detection = build_detection_results(raw, score_name, direction, thresholds, config)
    report_delays_ms = config.relay.REPORT_DELAYS_MS;
    rows = cell(height(thresholds) * numel(report_delays_ms), 1);
    row_index = 0;
    for ff = 1:height(thresholds)
        threshold = thresholds.threshold(ff);
        for dd = 1:numel(report_delays_ms)
            delay_ms = report_delays_ms(dd);
            selected = raw(raw.delay_ms == delay_ms, :);
            values = selected.(score_name);
            if isempty(values) || any(~isfinite(values))
                error('Missing or non-finite detector values at delay %d ms.', delay_ms);
            end
            if strcmpi(direction, 'lower')
                detected = values<threshold;
            elseif strcmpi(direction, 'upper')
                detected = values>threshold;
            else
                error('Unsupported detector direction: %s', direction);
            end
            row_index = row_index + 1;
            tp_count = sum(detected);
            fn_count = numel(detected) - tp_count;
            assert(tp_count + fn_count == height(selected), ...
                'TP and FN counts do not cover all attacked rows.');
            rows{row_index} = table(thresholds.target_fpr(ff), threshold, ...
                thresholds.empirical_fpr(ff), delay_ms, tp_count, fn_count, ...
                tp_count / numel(detected), 'VariableNames', {'target_fpr', ...
                'threshold', 'empirical_fpr', 'delay_ms', 'tp_count', 'fn_count', 'tpr'});
        end
    end
    detection = vertcat(rows{:});
end

% Build the publication summary table from calibrated detector results.
function summary = build_publication_summary(high_res_thresholds, high_res_detection, ...
        leave_one_out_thresholds, leave_one_out_detection, config, varargin)
    analysis_names = {'high_res_enf_extract', 'high_res_enf_extract_leave_one_out'};
    detector_names = {'abs_tau_corr', 'abs_tau_corr'};
    corrections = {'none', 'leave_one_out_group_median'};
    threshold_units = {'s', 's'};
    threshold_tables = {high_res_thresholds, leave_one_out_thresholds};
    detection_tables = {high_res_detection, leave_one_out_detection};
    if config.RUN_BASELINE
        assert(numel(varargin) == 2, 'Enabled baseline requires its threshold and detection tables.');
        analysis_names = [{'baseline_enf_extract'}, analysis_names];
        detector_names = [{'pearson_corr'}, detector_names];
        corrections = [{'none'}, corrections];
        threshold_units = [{'r'}, threshold_units];
        threshold_tables = [varargin(1), threshold_tables];
        detection_tables = [varargin(2), detection_tables];
    else
        assert(isempty(varargin), 'Disabled baseline must not supply baseline results.');
    end
    targets = config.relay.TARGET_FPR_VEC;
    rows = cell(numel(analysis_names) * numel(targets), 1);
    row_index = 0;
    for aa = 1:numel(analysis_names)
        for ff = 1:numel(targets)
            target_fpr = targets(ff);
            threshold_table = threshold_tables{aa};
            detection_table = detection_tables{aa};
            threshold_row = threshold_table( ...
                abs(threshold_table.target_fpr - target_fpr) < 1e-12, :);
            detection_rows = detection_table( ...
                abs(detection_table.target_fpr - target_fpr) < 1e-12, :);
            if height(threshold_row) ~= 1 || ...
                    height(detection_rows) ~= numel(config.relay.REPORT_DELAYS_MS)
                error('Incomplete summary rows for %s.', analysis_names{aa});
            end
            detection_rows = sortrows(detection_rows, 'delay_ms');
            if ~isequal(detection_rows.delay_ms, sort(config.relay.REPORT_DELAYS_MS(:)))
                error('Unexpected delay coverage for %s.', analysis_names{aa});
            end
            row_index = row_index + 1;
            target_fpr_percent = 100 * target_fpr;
            empirical_fpr_percent = 100 * threshold_row.empirical_fpr;
            threshold = threshold_row.threshold;
            rows{row_index} = table(analysis_names(aa), detector_names(aa), ...
                corrections(aa), target_fpr_percent, empirical_fpr_percent, ...
                threshold, threshold_units(aa), 'VariableNames', {'analysis_name', ...
                'detector', 'correction', 'target_fpr_percent', ...
                'empirical_fpr_percent', 'threshold', 'threshold_units'});
            for dd = 1:height(detection_rows)
                variable_name = sprintf('TPR_%dms_percent', detection_rows.delay_ms(dd));
                rows{row_index}.(variable_name) = 100 * detection_rows.tpr(dd);
            end
        end
    end
    summary = vertcat(rows{:});
end

% Report publication-summary thresholds and detection statistics.
function print_publication_summary(summary, config, fileID)
    report_delays_ms = config.relay.REPORT_DELAYS_MS;
    relay_log(fileID, '\nPublication relay-attack detection summary\n');
    relay_log(fileID, '%-43s %-12s %-26s %6s %8s %12s %5s', ...
        'Analysis', 'Detector', 'Correction', 'FPR', 'E-FPR', 'Threshold', 'Units');
    for dd = 1:numel(report_delays_ms)
        relay_log(fileID, ' %7gs', report_delays_ms(dd) / 1000);
    end
    relay_log(fileID, '\n');
    display_names = {'Baseline ENF extraction', ...
        'High-resolution ENF extraction', ...
        'High-resolution ENF + leave-one-out'};
    analysis_names = {'baseline_enf_extract', 'high_res_enf_extract', ...
        'high_res_enf_extract_leave_one_out'};
    for rr = 1:height(summary)
        name_index = find(strcmp(analysis_names, summary.analysis_name{rr}), 1);
        relay_log(fileID, '%-43s %-12s %-26s %5.1f%% %7.2f%% %12.6g %5s', ...
            display_names{name_index}, summary.detector{rr}, summary.correction{rr}, ...
            summary.target_fpr_percent(rr), ...
            summary.empirical_fpr_percent(rr), summary.threshold(rr), ...
            summary.threshold_units{rr});
        for dd = 1:numel(report_delays_ms)
            variable_name = sprintf('TPR_%dms_percent', report_delays_ms(dd));
            relay_log(fileID, ' %6.1f%%', summary.(variable_name)(rr));
        end
        relay_log(fileID, '\n');
    end
end

% Generate the corrected-lag true-positive-rate figure.
function plot_tpr_vs_delay(summary, config)
    selected = strcmp(summary.analysis_name, 'high_res_enf_extract_leave_one_out') & ...
        abs(summary.target_fpr_percent - 1) < 1e-12;
    assert(sum(selected) == 1, 'Require exactly one corrected-lag summary row at 1%% target FPR.');
    assert(strcmp(summary.detector{selected}, 'abs_tau_corr') && ...
        strcmp(summary.correction{selected}, 'leave_one_out_group_median'), ...
        'Unexpected detector or correction in the selected TPR row.');
    delays_sec = config.relay.REPORT_DELAYS_MS / 1000;
    values = zeros(size(delays_sec));
    for dd = 1:numel(delays_sec)
        name = sprintf('TPR_%dms_percent', config.relay.REPORT_DELAYS_MS(dd));
        values(dd) = summary.(name)(selected);
    end
    assert(numel(values) == 18 && all(isfinite(values)) && all(values >= 0 & values <= 100), ...
        'Invalid selected TPR values.');
    figure_handle = figure('Color', 'w', 'Visible', 'off', ...
        'Units', 'inches', 'Position', [1 1 15 5]);
    axes_handle = axes('Parent', figure_handle);
    standard_colors = get(0, 'DefaultAxesColorOrder');
    curve = semilogx(axes_handle, delays_sec, values, ...
        'Color', standard_colors(3, :), 'LineStyle', '-.', 'Marker', 'o', ...
        'LineWidth', 1.8, 'MarkerSize', 6);
    grid(axes_handle, 'on'); box(axes_handle, 'on');
    set(axes_handle, 'FontName', 'Arial', 'FontSize', 11);
    xticks(axes_handle, [0.05 0.1 0.2 0.5 1 2 5 10]);
    xticklabels(axes_handle, {'0.05', '0.1', '0.2', '0.5', '1', '2', '5', '10'});
    xtickangle(axes_handle, 45);
    xlim(axes_handle, [0.05 10]);
    ylim(axes_handle, [0 100]);
    xlabel(axes_handle, 'Injected Relay Delay (s, log scale)');
    ylabel(axes_handle, 'TPR (%)');
    legend(axes_handle, curve, ...
        {'High-resolution ENF + leave-one-out (1% target FPR)'}, ...
        'Location', 'northoutside', 'Orientation', 'horizontal');
    assert(numel(findobj(axes_handle, 'Type', 'line')) == 1, 'TPR figure must contain exactly one curve.');
    save_svg_figure(figure_handle, config.tpr_figure);
end

% Remove the optional baseline figure when baseline analysis is disabled.
function retire_baseline_figure(config, fileID)
    if ~isfile(config.pearson_figure), return; end
    % Preserve a verified external copy before retiring a stale publication figure.
    parent = fileparts(config.repository_root);
    checkpoints = dir(fullfile(parent, 'relay_recompute_checkpoint_*'));
    checkpoints = checkpoints([checkpoints.isdir]);
    if isempty(checkpoints)
        checkpoint = fullfile(parent, ['relay_recompute_checkpoint_' datestr(now, 'yyyymmdd_HHMMSS')]);
    else
        [~, latest] = max([checkpoints.datenum]);
        checkpoint = fullfile(parent, checkpoints(latest).name);
    end
    archive = fullfile(checkpoint, 'baseline_figure_archive');
    if ~isfolder(archive), mkdir(archive); end
    [~, name, extension] = fileparts(config.pearson_figure);
    stamp = datestr(now, 'yyyymmdd_HHMMSS');
    saved = fullfile(archive, [name '_' stamp extension]);
    suffix = 0;
    while isfile(saved)
        suffix = suffix + 1;
        saved = fullfile(archive, sprintf('%s_%s_%d%s', name, stamp, suffix, extension));
    end
    [ok, message] = copyfile(config.pearson_figure, saved);
    assert(ok, 'Cannot archive baseline figure: %s', message);
    a = fopen(config.pearson_figure, 'rb'); b = fopen(saved, 'rb');
    assert(a >= 0 && b >= 0, 'Cannot verify archived baseline figure.');
    original = fread(a, Inf, '*uint8'); copied = fread(b, Inf, '*uint8');
    fclose(a); fclose(b);
    assert(isequal(original, copied), 'Archived baseline figure differs from source figure.');
    delete(config.pearson_figure);
    relay_log(fileID, 'Baseline-only Pearson figure: archived outside repository; removed from active outputs\n');
end


% Generate the optional baseline Pearson-correlation figure.
function plot_baseline_pearson_correlation_vs_delay(baseline_raw, config)
    delay_states_ms = config.relay.DELAY_MS_VEC;
    delays_sec = delay_states_ms / 1000;
    mean_correlation = nan(size(delay_states_ms));

    for ii = 1:numel(delay_states_ms)
        selected = baseline_raw.delay_ms == delay_states_ms(ii);
        values = baseline_raw.corr_delay(selected);
        if isempty(values) || any(~isfinite(values))
            error('Missing or invalid baseline Pearson values at delay %g ms.', ...
                delay_states_ms(ii));
        end
        mean_correlation(ii) = mean(values);
    end

    no_attack_index = find(delay_states_ms == 0, 1);
    if isempty(no_attack_index)
        error('Baseline Pearson results do not contain the no-attack delay state.');
    end
    mean_no_attack = mean_correlation(no_attack_index);

    figure_handle = figure('Color', 'w', 'Visible', 'off', ...
        'Units', 'inches', 'Position', [1 1 8.5 4.0]);
    axes_handle = axes('Parent', figure_handle);
    hold(axes_handle, 'on');
    standard_colors = get(0, 'DefaultAxesColorOrder');

    mean_handle = plot(axes_handle, delays_sec, mean_correlation, ...
        'Color', standard_colors(1, :), 'LineStyle', '-', ...
        'Marker', 'o', 'LineWidth', 1.8, 'MarkerSize', 6, ...
        'MarkerFaceColor', 'w');
    reference_handle = plot(axes_handle, ...
        [min(delays_sec) max(delays_sec)], [mean_no_attack mean_no_attack], ...
        '--', 'Color', [0.25 0.25 0.25], 'LineWidth', 1.3);

    annotation_delays_ms = [3000 5000];
    for ii = 1:numel(annotation_delays_ms)
        delay_index = find(delay_states_ms == annotation_delays_ms(ii), 1);
        if isempty(delay_index)
            continue;
        end

        point_x = delays_sec(delay_index);
        point_y = mean_correlation(delay_index);
        relative_drop_percent = ...
            100 * (mean_no_attack - point_y) / mean_no_attack;
        plot(axes_handle, [point_x point_x], ...
            [point_y mean_no_attack], ':', 'Color', [0.35 0.35 0.35], ...
            'LineWidth', 1.0, 'HandleVisibility', 'off');
        text(axes_handle, point_x, (point_y + mean_no_attack) / 2, ...
            {sprintf('r drops by %.2f%%', relative_drop_percent), ...
            'relative to no-attack'}, ...
            'HorizontalAlignment', 'left', 'VerticalAlignment', 'middle', ...
            'FontName', 'Arial', 'FontSize', 9, 'BackgroundColor', 'w');
    end

    data_min = min([mean_correlation mean_no_attack]);
    data_max = max([mean_correlation mean_no_attack]);
    data_range = data_max - data_min;
    if data_range <= eps(max(1, abs(data_max)))
        padding = max(0.001, 0.01 * abs(mean_no_attack));
    else
        padding = 0.15 * data_range;
    end
    y_limits = [max(-1, data_min - padding) min(1, data_max + padding)];
    if y_limits(1) >= y_limits(2)
        y_limits = [data_min - padding data_max + padding];
    end

    grid(axes_handle, 'on');
    box(axes_handle, 'on');
    xlim(axes_handle, [min(delays_sec) max(delays_sec)]);
    ylim(axes_handle, y_limits);
    set(axes_handle, 'FontName', 'Arial', 'FontSize', 11);
    xlabel(axes_handle, 'Injected Relay Delay (s)');
    ylabel(axes_handle, 'Mean Pearson Correlation Coefficient');

    reference_label = sprintf( ...
        'Mean No-Attack Correlation (r = %.4f)', mean_no_attack);
    legend(axes_handle, [mean_handle reference_handle], ...
        {'Mean Pearson Correlation', reference_label}, ...
        'Location', 'southwest');
    save_svg_figure(figure_handle, config.pearson_figure);
end

% Export a figure to the configured SVG path.
function save_svg_figure(figure_handle, output_path)
    set(figure_handle, 'PaperPositionMode', 'auto');
    print(figure_handle, output_path, '-dsvg');
    close(figure_handle);
end

% Write the same formatted message to the Command Window and log file.
function relay_log(fileID, varargin)
    fprintf(varargin{:});
    fprintf(fileID, varargin{:});
end

% Format a numeric vector for configuration logging.
function text_value = format_numeric_list(values)
    text_value = strtrim(sprintf('%g ', values));
end

% Format a proportion vector as percentages for logging.
function text_value = format_percent_list(values)
    text_value = strtrim(sprintf('%.1f%% ', 100 * values));
end

% Require a table to contain every named column.
function require_columns(input_table, required_columns, label)
    missing = setdiff(required_columns, input_table.Properties.VariableNames);
    if ~isempty(missing)
        error('%s is missing required columns: %s', label, strjoin(missing, ', '));
    end
end
