%% ENF Validation Correlation Summary
% Purpose:
%   Summarize ENF recovery for the fixed board, power-rail, and
%   probe-sensitivity measurements.
%
% Experiment:
%   Main paper Sections 4.3-4.4 and additional artifacts A-D/F.
%
% Analysis:
%   Compute the existing 77 selected pair correlations and summarize the
%   established board, adapter, and sensitivity experiments.
%
% Inputs:
%   exp_validation/exp_inputs; fixed baseline, EM, power-rail, adapter-output,
%   switching, and sensitivity selections.
%
% Outputs:
%   exp_validation/exp_logs/enf_analysis_top_validation_summary_log.txt.
%
% Dependencies:
%   Shared proc_enf_analysis.p processor; Signal Processing Toolbox.
%
% Usage:
%   Run from any working directory; retain SAKU VIN/VOUT spectrum combining,
%   other method-1 settings, and 120-seconds-to-end interval behavior.


%% STEP_1) Configuration and Paths
% Resolve the validation artifact paths and protected shared ENF processor.
config = struct();
standardization_timer = tic;
validation_script_dir = fileparts(mfilename('fullpath'));
[~, validation_script_name] = fileparts(mfilename('fullpath'));
validation_root = fileparts(validation_script_dir);
validation_input_root = fullfile(validation_root, 'exp_inputs');
config.paths.input_root = validation_input_root;
config.paths.log_dir = fullfile(validation_root, 'exp_logs');
addpath(validation_script_dir, '-begin');
assert(strcmpi(which('proc_enf_analysis'), fullfile(validation_script_dir,'proc_enf_analysis.p')), ...
    'Unexpected shared ENF processor.');

%% STEP_2) Logging Setup
% Open the established log filename and attach cleanup before input processing.
validation_log_dir = config.paths.log_dir;
if ~isfolder(validation_log_dir), mkdir(validation_log_dir); end
validation_log_path = fullfile(validation_log_dir, [validation_script_name '_log.txt']);
validation_file_id = fopen(validation_log_path, 'w');
assert(validation_file_id >= 0, 'Cannot open validation summary log.');
validation_cleanup = onCleanup(@() fclose(validation_file_id));
log_both(validation_file_id, '%s\nENF VALIDATION CORRELATION SUMMARY\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(validation_file_id, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
log_both(validation_file_id, 'Configuration entrypoint: %s\n', mfilename);
log_both(validation_file_id, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));
log_both(validation_file_id, 'Output directories initialized; log cleanup handler active.\n');

%% STEP_3) Input Discovery and Validation
% Validate all 77 fixed cases and retain the existing recording qualifications.
try
    log_both(validation_file_id, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    validation_cases = build_cases();
    assert(numel(validation_cases) == 77, 'Expected exactly 77 validation pairs.');
    preflight(validation_input_root, validation_cases);
    log_both(validation_file_id, 'Validated selected comparisons: %d\nInput dataset: exp_validation/exp_inputs/\n',numel(validation_cases));
catch execution_error
    log_both(validation_file_id, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear validation_cleanup;
    rethrow(execution_error);
end

%% STEP_4) ENF Extraction and Processing
% Run the unchanged pair estimator and existing interval selection for every case.
try
    log_both(validation_file_id, '\nSTEP_4) ENF EXTRACTION AND PROCESSING\n%s\n', repmat('%',1,85));
    validation_results = zeros(1, numel(validation_cases));
    for validation_index = 1:numel(validation_cases)
        validation_case = validation_cases(validation_index);
        reference_path = fullfile(validation_input_root, validation_case.folder, validation_case.reference);
        sensed_path = fullfile(validation_input_root, validation_case.folder, validation_case.sensed);
        if isempty(validation_case.interval)
            is_saku_power = strcmp(validation_case.group, 'C. ACTIVE PCB - POWER RAIL - SAKU');
            validation_results(validation_index) = analyze_pair(reference_path, sensed_path, is_saku_power);
        else
            % Match the single-pair chunk helper: slice raw samples, then preprocess.
            [reference, reference_fs] = read_interval(reference_path, validation_case.interval);
            [sensed, sensed_fs] = read_interval(sensed_path, validation_case.interval);
            validation_results(validation_index) = analyze_pair(reference, sensed, false, ...
                'Fs1', reference_fs, 'Fs2', sensed_fs, 'LegacyNumericInputHandling', true);
        end
        assert(isfinite(validation_results(validation_index)), ...
            'Undefined correlation for %s / %s.', validation_case.group, validation_case.row);
    end

catch execution_error
    log_both(validation_file_id, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear validation_cleanup;
    rethrow(execution_error);
end

%% STEP_5) Summary Statistics and
%            Report Formatting
% Format the established per-case correlations and replicate mean/sample standard deviation.
try
    log_both(validation_file_id, '\nSTEP_5) STATISTICAL ANALYSIS\n%s\n', repmat('%',1,85));
    validation_report = format_report(validation_cases, validation_results);
catch execution_error
    log_both(validation_file_id, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear validation_cleanup;
    rethrow(execution_error);
end

%% STEP_6) Results and Logging
% Print the computed validation tables to the Command Window and established text log.
try
    log_both(validation_file_id, '\nSTEP_6) RESULTS AND LOGGING\n%s\n', repmat('%',1,85));
    log_both(validation_file_id, '%s', validation_report);
catch execution_error
    log_both(validation_file_id, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear validation_cleanup;
    rethrow(execution_error);
end

%% STEP_7) Final Summary and Logging
% Report successful completion only after every required comparison has finished.
try
    log_both(validation_file_id, '\nSTEP_7) FINAL SUMMARY AND LOGGING\n%s\n', repmat('%',1,85));
    log_both(validation_file_id, 'Output log: %s\nExecution status: SUCCESS\nTotal execution time: %.3f s\n', validation_log_path, toc(standardization_timer));
    clear validation_cleanup;
catch execution_error
    log_both(validation_file_id, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear validation_cleanup;
    rethrow(execution_error);
end

%% Local Functions
% Build the fixed, ordered set of 77 validation cases.
function cases = build_cases()
    cases = struct('group', {}, 'row', {}, 'column', {}, 'folder', {}, ...
        'reference', {}, 'sensed', {}, 'interval', {});
    ac = 'mains_pow_trace_ac.wav';
    em = 'fpga_em_trace_dc.wav';
    for name = {'NO_FB', 'W_FB'}
        cases = add_case(cases, 'A. BASELINE AMBIENT EM SENSING', name{1}, 1, ...
            fullfile('BASE', name{1}), ac, em, []);
    end
    for board = {'SAKU', 'CW305'}
        group = ['B. ACTIVE PCB - AMBIENT EM - ' board{1}];
        for adapter = 1:5
            label = sprintf('DC_%d', adapter);
            cases = add_case(cases, group, label, 1, ...
                fullfile('FPGA', 'EM_TRACES', board{1}, 'MAIN_EXP', label), ac, em, []);
        end
    end
    for board = {'SAKU', 'CW305'}
        group = ['C. ACTIVE PCB - POWER RAIL - ' board{1}];
        for adapter = 1:5
            label = sprintf('DC_%d', adapter);
            folder = fullfile('FPGA', 'POW_TRACES', board{1}, 'MAIN_EXP', label);
            cases = add_case(cases, group, label, 1, folder, ac, 'fpga_pow_trace_dc_a.wav', []);
            cases = add_case(cases, group, label, 2, folder, ac, 'fpga_pow_trace_dc_b.wav', []);
        end
    end
    control = fullfile('FPGA', 'EM_TRACES', 'SAKU');
    for adapter = 1:5
        label = sprintf('DC_%d', adapter);
        cases = add_case(cases, 'D. AC-DC ADAPTER OUTPUT', label, 1, ...
            fullfile(control, 'DC_ADAPTER_CHAR', label), ac, 'mains_pow_trace_dc.wav', []);
    end
    labels = {'ON_1 (0-50 s)', 'OFF (50-120 s)', 'ON_2 (120 s-end)'};
    intervals = {[0 50], [50 120], [120 Inf]};
    for index = 1:3
        cases = add_case(cases, 'E. ON-OFF-ON SUPPLY CONTROL', labels{index}, 1, ...
            fullfile(control, 'ON_OFF_ON'), ac, em, intervals{index});
    end
    for name = {'dist_0', 'dist_1p4m', 'dist_5p9m'}
        cases = add_case(cases, 'F. WALL-OUTLET SEPARATION', name{1}, 1, ...
            fullfile(control, 'POW_SUPPLY_DIST_CHAR', name{1}), ac, em, []);
    end
    cases = add_case(cases, 'G. ADAPTER SHIELDING', 'DC_ADAPTER_W_FB', 1, ...
        fullfile(control, 'DC_ADAPTER_W_FB'), ac, em, []);
    probe = fullfile(control, 'PROBE_ORIENT_CHAR');
    groups = {'H1. PROBE DISTANCE', 'H2. PROBE ORIENTATION', 'H3. PROBE PLACEMENT'};
    folders = {'DIST_VAR', 'ORIENT_VAR', 'PLACE_VAR'};
    configurations = {{'DIST_0cm', 'DIST_10cm', 'DIST_20cm', 'DIST_40cm', 'DIST_60cm'}, ...
        {'TOWARDS_FPGA_PSU', 'AWAY_FROM_FPGA_PSU'}, {'W', 'N', 'E', 'S'}};
    for index = 1:3
        for name = configurations{index}
            for trial = 1:3
                cases = add_case(cases, groups{index}, name{1}, trial, ...
                    fullfile(probe, folders{index}, name{1}), ...
                    sprintf('mains_pow_trace_ac_%d.wav', trial), ...
                    sprintf('fpga_em_trace_dc_%d.wav', trial), []);
            end
        end
    end
end

% Append one validation case without changing the established case schema.
function cases = add_case(cases, group, row, column, folder, reference, sensed, interval)
    cases(end+1) = struct('group', group, 'row', row, 'column', column, ...
        'folder', folder, 'reference', reference, 'sensed', sensed, 'interval', interval);
end

% Validate that each selected input exists and has compatible WAV metadata.
function preflight(root, cases)
    checked_trials = {};
    for index = 1:numel(cases)
        item = cases(index);
        paths = {fullfile(root, item.folder, item.reference), fullfile(root, item.folder, item.sensed)};
        info = cell(1, 2);
        for channel = 1:2
            relative = fullfile(item.folder, {item.reference, item.sensed});
            assert(isfile(paths{channel}), 'Missing required input: %s.', relative{channel});
            info{channel} = audioinfo(paths{channel});
            assert(info{channel}.NumChannels == 1, ...
                'Expected a mono channel recording: %s.', relative{channel});
            assert(ismember(info{channel}.SampleRate, [1000 1050 44100]), ...
                'Unsupported source sample rate: %s.', relative{channel});
            effective_fs = info{channel}.SampleRate;
            if effective_fs == 44100
                effective_fs = 1050;
            end
            if isempty(item.interval)
                duration = info{channel}.TotalSamples / info{channel}.SampleRate;
            else
                stop = min(item.interval(2), info{channel}.TotalSamples / info{channel}.SampleRate);
                assert(isinf(item.interval(2)) || stop == item.interval(2), ...
                    'Requested interval exceeds available samples: %s.', relative{channel});
                duration = stop - item.interval(1);
            end
            assert(duration * effective_fs >= 8000, 'Input shorter than an analysis frame: %s.', relative{channel});
        end
        rates = cellfun(@(value) value.SampleRate, info);
        rates(rates == 44100) = 1050;
        assert(rates(1) == rates(2), 'Effective sample-rate mismatch: %s.', item.folder);
        if startsWith(item.group, 'H') && ~ismember(item.folder, checked_trials)
            listing = dir(fullfile(root, item.folder, '*.wav'));
            for prefix = {'mains_pow_trace_ac', 'fpga_em_trace_dc'}
                numbers = [];
                for file = listing'
                    token = regexp(file.name, ['^' prefix{1} '_(\d+)\.wav$'], 'tokens', 'once');
                    if ~isempty(token)
                        numbers(end+1) = str2double(token{1});
                    end
                end
                assert(isequal(sort(numbers), [1 2 3]), 'Missing or ambiguous numbered trials: %s / %s.', item.folder, prefix{1});
            end
            checked_trials{end+1} = item.folder;
        end
    end
end

% Read the requested time interval from one WAV input.
function [signal, fs] = read_interval(path, interval)
    info = audioinfo(path);
    fs = info.SampleRate;
    first = floor(interval(1) * fs) + 1;
    last = min(floor(interval(2) * fs), info.TotalSamples);
    assert(first <= last, 'Control interval has no samples.');
    signal = audioread(path, [first last]);
end

% Run the shared ENF processor with the estimator selected for this case.
function r = analyze_pair(reference, sensed, is_saku_power, varargin)
    % Use the shared core, selecting the requested SAKU power-rail estimators.
    nominal = 60;
    harmonics = (1:7) * nominal;
    reference_method = 1;
    sensed_method = 1;
    sensed_combining_harmonics = harmonics;
    if is_saku_power
        reference_method = 2;
        sensed_method = 2;
        sensed_combining_harmonics = [120 240 360];
    end
    r = proc_enf_analysis(reference, sensed, 32768, 8000, 0, ...
        harmonics, nominal, harmonics, nominal, ...
        reference_method, harmonics(1), harmonics, ...
        sensed_method, harmonics(1), sensed_combining_harmonics, ...
        'Reference AC Mains Power Trace', 'Sensed FPGA Trace', false, ...
        'Quiet', true, varargin{:});
end

% Format per-case correlations and replicate summary statistics as text.
function report = format_report(cases, results)
    divider = repmat('=', 1, 78);
    lines = {divider, 'ENF VALIDATION - CORRELATION SUMMARY', divider, ...
        'Purpose: compare sensed ambient EM, board power-rail, and adapter-output', ...
        'ENF signatures against their co-recorded AC mains reference signals.', ...
        'Coverage: 77 pairs across baseline, active-board, and control experiments.', ...
        'Metric: zero-lag Pearson r between extracted ENF series.', ...
        'VIN / VOUT: regulator input / output sensed channels, respectively.', ...
        'Replicates: T01-T03; arithmetic mean r; sample SD r (N-1).', ...
        '', ...
        'PROCESSING SETTINGS', ...
        '60 Hz nominal; frame/hop 8000 samples; FFT setting 32768.', ...
        'SAKU power rails (both VIN and VOUT): spectrum combining (method 2).', ...
        '  Reference harmonics (Hz): 60 120 180 240 300 360 420.', ...
        '  Sensed harmonics (Hz): 120 240 360.', ...
        'All other pairs: weighted-average estimator (method 1), PMF power 3.', ...
        'Shared preprocessing and alignment; no plots or signal-file writes.', ''};
    groups = unique({cases.group}, 'stable');
    for group = groups
        lines = [lines, {group{1}, repmat('-', 1, 78)}];
        group_indices = find(strcmp({cases.group}, group{1}));
        rows = unique({cases(group_indices).row}, 'stable');
        is_replicate = startsWith(group{1}, 'H');
        is_power = startsWith(group{1}, 'C');
        if is_replicate
            lines{end+1} = sprintf('%-25s %9s %9s %9s %9s %9s', 'Configuration', 'T01', 'T02', 'T03', 'Mean r', 'SD r');
        elseif is_power
            lines{end+1} = sprintf('%-25s %9s %9s', 'Adapter', 'VIN r', 'VOUT r');
        else
            lines{end+1} = sprintf('%-25s %9s', 'Configuration', 'Pearson r');
        end
        for row = rows
            indices = group_indices(strcmp({cases(group_indices).row}, row{1}));
            [~, order] = sort([cases(indices).column]);
            values = results(indices(order));
            if is_replicate
                assert(numel(values) == 3, 'Expected three replicate correlations.');
                lines{end+1} = sprintf('%-25s %9.4f %9.4f %9.4f %9.4f %9.4f', ...
                    row{1}, values, mean(values), std(values, 0));
            elseif is_power
                assert(numel(values) == 2, 'Expected VIN and VOUT correlations.');
                lines{end+1} = sprintf('%-25s %9.4f %9.4f', row{1}, values);
            else
                lines{end+1} = sprintf('%-25s %9.4f', row{1}, values);
            end
        end
        lines{end+1} = '';
    end
    lines = [lines, {divider, 'END OF VALIDATION SUMMARY', divider}];
    report = sprintf('%s\n', lines{:});
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID, varargin)
    fprintf(1,varargin{:}); fprintf(fileID,varargin{:});
end
