%% ENF Pairwise Signature Validation
% Purpose:
%   Inspect ENF recovery from one configured reference/sensed recording pair.
%
% Experiment:
%   Main paper Sections 4.3-4.4; configurable single-pair figure helper.
%
% Analysis:
%   Compare the selected reference and sensed WAVs with the existing
%   configurable ENF estimator and optional chunk processing.
%
% Inputs:
%   exp_validation/exp_inputs; one configured WAV pair, with existing optional
%   segment definitions.
%
% Outputs:
%   Interactive shared-processor figures; optional chunk WAVs under
%   exp_validation/exp_results/pair_wise; and the script log under
%   exp_validation/exp_logs.
%
% Dependencies:
%   Shared proc_enf_analysis.p in this script directory; Signal Processing Toolbox.
%
% Usage:
%   Select the input folders/files and estimator options in STEP_1, then run
%   the script from any working directory.


%% STEP_1) Script Configuration
% Preserve the selected files, estimator settings, chunk flags, and figure
% configuration.
config = struct();
standardization_timer = tic;

% Chunk Processing Options
% Enable or disable splitting the complete traces into configured segments.
SCRP_CFG_DO_CHUNK_PROCESSING = false;
% SCRP_CFG_ENABLE_CHUNK_PLOTS controls plots for each segment pair:
%   true:  Generate plots for each segment pair.
%   false: Compute segment PCCs without making per-segment plots.
SCRP_CFG_ENABLE_CHUNK_PLOTS = false;
% Set the minimum overlap used only when SCRP_CFG_ENABLE_CHUNK_PLOTS is true.
SCRP_CFG_CHUNK_PLOT_MIN_OVERLAP_SEC = 30;

% Input Trace Selection
% Analyze one pair of traces at a time. Update the variables below for each
% run. If both traces are in the same
% leaf folder, set file_1_path and file_2_path to the same value.
%
% 1. `file_1_path`: Relative path ending in "/" for the AC mains reference.
% 2. `file_2_path`: Relative path ending in "/" for the sensed trace.
% 3. `file_1_name`: AC mains reference file name without extension.
% 4. `file_2_name`: Sensed trace file name without extension.
%
% Examples
%
% % Example 1: Analyzing a 'TREND' experiment trace (WK01/WEND/SUN/EVEN/T01)
% file_1_path = "../../exp_evaluation/exp_inputs/TREND/WK01/WEND/SUN/EVEN/T01/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac";
% file_2_name = "fpga_em_trace_dc";
%
% % Example 2: Analyzing an FPGA ambient EM trace (FPGA/EM_TRACES/CW305/MAIN_EXP/DC_1)
% file_1_path = "../exp_inputs/FPGA/EM_TRACES/CW305/MAIN_EXP/DC_1/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac";
% file_2_name = "fpga_em_trace_dc";
%
% % Example 2a: Analyzing an FPGA ambient EM trace for ON-OFF-ON EXP(FPGA/EM_TRACES/SAKU/ON_OFF_ON)
% file_1_path = "../exp_inputs/FPGA/EM_TRACES/SAKU/ON_OFF_ON/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac";
% file_2_name = "fpga_em_trace_dc";
%
% % Example 3: Analyzing an FPGA board power trace (FPGA/POW_TRACES/CW305/MAIN_EXP/DC_1)
% file_1_path = "../exp_inputs/FPGA/POW_TRACES/CW305/MAIN_EXP/DC_1/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac";
% file_2_name = "fpga_pow_trace_dc_a";  % or "fpga_pow_trace_dc_b"
%
% % Example 4: Analyzing a 'MULTI' (US_60) experiment trace (MULTI/US_60/AUG/WED/T02)
% % File names differ from the standard naming convention in this folder.
% file_1_path = "../../exp_evaluation/exp_inputs/MULTI/US_60/AUG/WED/T02/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac_egrid_citya_lab";
% file_2_name = "fpga_em_trace_dc_egrid_citya_lab";
%
% % Example 5: Analyzing a 'MULTI' (DE_50) experiment trace (MULTI/DE_50/AUG/WED/T01)
% file_1_path = "../../exp_evaluation/exp_inputs/MULTI/DE_50/AUG/WED/T01/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac_citya_lab";
% file_2_name = "fpga_em_trace_dc_citya_lab";
%
% % Example 6: Analyzing an 'SRV_L' experiment trace (SRV_L/SPSU/WED/T05)
% file_1_path = "../../exp_evaluation/exp_inputs/SRV_L/SPSU/WED/T05/";
% file_2_path = file_1_path;
% file_1_name = "mains_pow_trace_ac";
% file_2_name = "fpga_em_trace_dc";

% Set the variables below to point to the trace pair you want to analyze.
% file_1_path = "../exp_inputs/FPGA/EM_TRACES/CW305/MAIN_EXP/DC_1/";
% file_2_path = file_1_path;
file_1_path = "../exp_inputs/FPGA/EM_TRACES/SAKU/MAIN_EXP/DC_3/";
file_2_path = file_1_path;
file_1_name = "mains_pow_trace_ac";
file_2_name = "fpga_em_trace_dc";

% Spectrogram Parameters
% Configure the fundamental power-grid frequencies for each trace.
nominal_freq_arr      = [50 60];

% For MULTI traces, manually select the fundamental frequency of the source
% grid with the nominal_freq_* variables below:
% - For US_60 (United States) traces: set nominal_freq = nominal_freq_arr(2); (60 Hz)
% - For DE_50 (Germany) traces:     set nominal_freq = nominal_freq_arr(1); (50 Hz)

% Reference trace nominal frequency and harmonics.
nominal_freq_1        = nominal_freq_arr(2);
harmonics_arr_1       = (1:7)*nominal_freq_1;

% Sensed trace nominal frequency and harmonics.
nominal_freq_2        = nominal_freq_arr(2);
harmonics_arr_2       = (1:7)*nominal_freq_2;

% STFT computation parameters.
frame_size_arr      = (1:12)*1000;
frame_size          = frame_size_arr(8);                % 8000 samples; hop depends on the effective analysis sample rate
nfft_arr            = 2.^(10:20);
nfft                = nfft_arr(6);                      % 2^15 = 32768 points
overlap_size_arr    = 0:0.1:0.9;
overlap_size        = overlap_size_arr(1)*frame_size;   % Non-overlapping

% Frequency Estimation Parameters
% Select the harmonic estimated for each trace.
trace_1_est_freq = harmonics_arr_1(1);                    % First harmonic = 60 Hz
trace_2_est_freq = harmonics_arr_2(1);                    % First harmonic = 60 Hz

% Frequency-estimation methods:
%   1: Weighted average (PMF power = 3).
%   2: Spectrum combining (quadratic interpolation).
trace_1_freq_est_method = 1;   % Reference trace
trace_1_freq_est_spec_comb_harmonics = [60 120 180 240 300 360 420];

trace_2_freq_est_method = 1;   % Sensed trace
trace_2_freq_est_spec_comb_harmonics = [120 240 360];

tempo_align_corr_vals = {};

% Plot Configuration
% Use the jet colormap for generated figures.
set(0,'DefaultFigureColormap', jet)

% Titles for MATLAB plots.
trace_1_plot_title = "Reference AC Mains Power Trace";
trace_2_plot_title = "Sensed FPGA Trace";

%% STEP_2) Setup: Paths and Logging
% Resolve inputs relative to this script, define result and log directories,
% verify the protected shared MATLAB dependency, and capture console output.

% File Path Construction
% Build the complete WAV paths from each configured leaf folder and file base
% name. Both inputs must already be WAV files; no conversion is performed.
script_dir = string(fileparts(mfilename('fullpath')));
file_1_path = string(fullfile(script_dir, file_1_path)) + filesep;
file_2_path = string(fullfile(script_dir, file_2_path)) + filesep;
full_file_1_path_wav = file_1_path + file_1_name + ".wav";
full_file_2_path_wav = file_2_path + file_2_name + ".wav";

% Result and Log Directories
config.paths.artifact_root = fileparts(char(script_dir));
config.paths.results_dir = fullfile(config.paths.artifact_root,'exp_results','pair_wise');
config.paths.log_dir = fullfile(config.paths.artifact_root,'exp_logs');

% Protected Shared MATLAB Dependency
addpath(char(script_dir),'-begin');
assert(strcmpi(which('proc_enf_analysis'),fullfile(char(script_dir),'proc_enf_analysis.p')), ...
    'Unexpected shared ENF processor.');

% Logging Setup
if ~isfolder(config.paths.log_dir), mkdir(config.paths.log_dir); end
[~, pairwise_script_name] = fileparts(mfilename('fullpath'));
pairwise_log_path = fullfile(config.paths.log_dir,[pairwise_script_name '_log.txt']);
pairwise_file = fopen(pairwise_log_path,'w'); assert(pairwise_file>=0,'Cannot open pairwise log.'); fclose(pairwise_file);
diary(pairwise_log_path);
pairwise_cleanup = onCleanup(@() diary('off'));
fprintf('%s\nENF PAIRWISE SIGNATURE VALIDATION\n%s\n',repmat('%',1,85),repmat('%',1,85));
fprintf('STEP_1) SCRIPT CONFIGURATION\nFrame=%d samples; overlap=%d; FFT=%d; estimators=%d/%d\n', ...
    frame_size,overlap_size,nfft,trace_1_freq_est_method,trace_2_freq_est_method);
fprintf('STEP_2) SETUP: PATHS AND LOGGING\nLog: %s\n',pairwise_log_path);

%% STEP_3) Input Discovery and Validation
% Validate the selected WAV metadata without altering source waveforms.
try
    fprintf('\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n');
    for pairwise_path = [full_file_1_path_wav, full_file_2_path_wav]
        assert(isfile(pairwise_path),'Missing required pairwise input: %s',pairwise_path);
        pairwise_info = audioinfo(pairwise_path);
        assert(pairwise_info.NumChannels==1 && ismember(pairwise_info.SampleRate,[1000 1050 44100]), ...
            'Expected mono WAV with a supported source sample rate.');
        assert(pairwise_info.Duration>frame_size/1050,'Selected recording is shorter than one ENF frame.');
        fprintf('Input: %s; Fs=%d Hz; channels=%d; duration=%.9f s\n', ...
            pairwise_path,pairwise_info.SampleRate,pairwise_info.NumChannels,pairwise_info.Duration);
    end
catch execution_error
    fprintf(2, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear pairwise_cleanup;
    rethrow(execution_error);
end

%% STEP_4) Optional Chunk Processing
% When SCRP_CFG_DO_CHUNK_PROCESSING is enabled, split both traces at the
% configured boundaries and write the generated chunk WAVs to
% exp_validation/exp_results/pair_wise. SCRP_CFG_ENABLE_CHUNK_PLOTS controls
% whether analysis later generates plots for each chunk pair.
try
    fprintf('\nSTEP_4) OPTIONAL CHUNK PROCESSING\n');
    if SCRP_CFG_DO_CHUNK_PROCESSING
        % Custom segment boundaries in seconds:
        % [0 50 120 Inf] creates:
        %   segment 1: 0   to 50 seconds
        %   segment 2: 50  to 120 seconds
        %   segment 3: 120 to end of file
        if ~isfolder(config.paths.results_dir), mkdir(config.paths.results_dir); end
        segment_edges_secs = [0 50 120 Inf];

        output_filename_w_chunk_1 = string(fullfile(config.paths.results_dir,file_1_name + "_tr"));
        fprintf('\nINFO: For trace 1 splitting "%s" into custom time segments...\n', full_file_1_path_wav);
        trace_1_created_files = proc_split_trace_segments( ...
            full_file_1_path_wav, segment_edges_secs, output_filename_w_chunk_1);

        output_filename_w_chunk_2 = string(fullfile(config.paths.results_dir,file_2_name + "_tr"));
        fprintf('\nINFO: For trace 2 splitting "%s" into custom time segments...\n', full_file_2_path_wav);
        trace_2_created_files = proc_split_trace_segments( ...
            full_file_2_path_wav, segment_edges_secs, output_filename_w_chunk_2);
    else
        disp('INFO: Skipping trace chunking as per SCRP_CFG_DO_CHUNK_PROCESSING flag.');
        trace_1_created_files = {};
        trace_2_created_files = {};
    end
catch execution_error
    fprintf(2, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear pairwise_cleanup;
    rethrow(execution_error);
end

%% STEP_5) ENF Extraction and Correlation
% Use the shared ENF processor for the complete trace pair and, when enabled,
% each generated chunk pair. The processor computes the spectrograms,
% extracts and aligns the ENF series, and returns the Pearson correlation.
try
    fprintf('\nSTEP_5) ENF EXTRACTION AND CORRELATION\n');
    fprintf('\nINFO: ENF Analysis on complete reference and sensed traces ...\n');
    matched_corr_val_full = proc_enf_analysis(full_file_1_path_wav, full_file_2_path_wav, ...
        nfft, frame_size, overlap_size, ...
        harmonics_arr_1, nominal_freq_1, harmonics_arr_2, nominal_freq_2,...
        trace_1_freq_est_method, trace_1_est_freq, trace_1_freq_est_spec_comb_harmonics, ...
        trace_2_freq_est_method, trace_2_est_freq, trace_2_freq_est_spec_comb_harmonics, ...
        trace_1_plot_title, trace_2_plot_title, true);

    tempo_align_corr_vals{end+1} = matched_corr_val_full;

    if SCRP_CFG_DO_CHUNK_PROCESSING
        if numel(trace_1_created_files) == numel(trace_2_created_files)
            fprintf('\nINFO: ENF Analysis (pairwise) on %d trace chunks for reference and sensed traces ...\n', numel(trace_1_created_files));
            for i = 1:numel(trace_1_created_files)
                file1 = trace_1_created_files{i};
                file2 = trace_2_created_files{i};
                fprintf('\nINFO: Processing pair %d: "%s" and "%s"\n', i, file1, file2);
                matched_corr_val_chunk = proc_enf_analysis(file1, file2, ...
                    nfft, frame_size, overlap_size, ...
                    harmonics_arr_1, nominal_freq_1, harmonics_arr_2, nominal_freq_2,...
                    trace_1_freq_est_method, trace_1_est_freq, trace_1_freq_est_spec_comb_harmonics, ...
                    trace_2_freq_est_method, trace_2_est_freq, trace_2_freq_est_spec_comb_harmonics, ...
                    trace_1_plot_title, trace_2_plot_title, SCRP_CFG_ENABLE_CHUNK_PLOTS, ...
                    'MinOverlapSec', SCRP_CFG_CHUNK_PLOT_MIN_OVERLAP_SEC);
                tempo_align_corr_vals{end+1} = matched_corr_val_chunk;
            end

            fprintf('\nINFO: Pearsons Correlation Coefficient for the temporally aligned reference and sensed traces (complete trace): %.8f \n', cell2mat(tempo_align_corr_vals(1)));
            fprintf('\nINFO: Pearsons Correlation Coefficients for the temporally aligned reference and sensed traces (chunk-wise):\n');
            disp(tempo_align_corr_vals(2:end));
            mean_corr = mean(cell2mat(tempo_align_corr_vals(2:end)));
            fprintf('INFO: Mean Pearsons Correlation Coefficient for the temporally aligned reference and sensed traces (all chunks): %.8f\n', mean_corr);

            fprintf('\nINFO: ENF Analysis Post-Processing complete.\n');
        else
            error('The number of files in trace_1_created_files and trace_2_created_files must be the same.');
        end
    else
        fprintf('\nINFO: Pearsons Correlation Coefficient for the temporally aligned reference and sensed traces (complete trace): %.8f \n', matched_corr_val_full);
        fprintf('\nINFO: ENF Analysis complete.\n');
    end
catch execution_error
    fprintf(2, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear pairwise_cleanup;
    rethrow(execution_error);
end

%% STEP_6) Final Summary and Logging
% Report completion and runtime, then close the diary.
try
    fprintf('\nSTEP_6) FINAL SUMMARY AND LOGGING\nExecution status: SUCCESS\nTotal execution time: %.3f s\n',toc(standardization_timer));
    clear pairwise_cleanup;
catch execution_error
    fprintf(2, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear pairwise_cleanup;
    rethrow(execution_error);
end

%% Local Functions
% Split a WAV file at user-defined time boundaries and write each segment.
function created_files = proc_split_trace_segments(inputFile, segment_edges_secs, output_filename_suffix)
    if nargin < 3
        output_filename_suffix = 'tr';
    end

    created_files = {};

    try
        [y, Fs] = audioread(inputFile);
        [totalSamples, ~] = size(y);
        totalDurationSecs = totalSamples / Fs;

        segment_edges_secs(~isfinite(segment_edges_secs)) = totalDurationSecs;

        if segment_edges_secs(1) < 0
            error('Segment start time cannot be negative.');
        end

        if any(diff(segment_edges_secs) <= 0)
            error('segment_edges_secs must be strictly increasing.');
        end

        if segment_edges_secs(1) ~= 0
            warning('First segment does not start at 0 seconds.');
        end

        segment_edges_secs(end) = min(segment_edges_secs(end), totalDurationSecs);
        numSegments = numel(segment_edges_secs) - 1;

        for i = 1:numSegments
            startSec = segment_edges_secs(i);
            endSec   = segment_edges_secs(i + 1);

            startSample = floor(startSec * Fs) + 1;
            endSample   = min(floor(endSec * Fs), totalSamples);

            if endSample <= startSample
                warning('Skipping segment %d because it has no samples.', i);
                continue;
            end

            currentSegmentData = y(startSample:endSample, :);
            outputFileName = sprintf('%s_%d.wav', output_filename_suffix, i);
            audiowrite(outputFileName, currentSegmentData, Fs);

            fprintf('INFO: Created segment %d: %.2f to %.2f sec -> %s\n', ...
                i, startSec, endSec, outputFileName);

            created_files{end+1} = outputFileName;
        end

    catch ME
        fprintf('ERROR: Could not process the file "%s".\n', inputFile);
        fprintf('MATLAB error message: %s\n', ME.message);
        rethrow(ME);
    end
end
