%% ENF Synthetic Forgery Attacks
% Purpose:
%   Evaluate the finalized adaptive synthetic-ENF forgery against live-reference matching.
%
% Experiment:
%   Main paper Section 6.4; fixed representative overlay.
%
% Analysis:
%   Suppress ENF-bearing harmonics, reconstruct their spectral noise floor,
%   inject synthetic ENF harmonics with peak matching, and verify authentic
%   and forged ENF with zero-lag correlation.
%
% Inputs:
%   exp_evaluation/exp_inputs/TREND; 160 paired 200-second recordings.
%
% Outputs:
%   Raw and summary CSVs plus overlay PNG/SVG/FIG files under
%   exp_evaluation/exp_results/syn_forgery_attacks and the script log under
%   exp_evaluation/exp_logs.
%
% Dependencies:
%   Shared exp_validation/exp_scripts/proc_enf_analysis.p; Signal Processing
%   and Statistics toolboxes; optional Parallel Computing Toolbox.
%
% Usage:
%   Run from any working directory; preserve deterministic combRecursive
%   window IDs and seeds and the fixed example selection.


%% STEP_1) Script Configuration
% Centralize paths, execution flags, ENF verification, and attack parameters.

% Dataset and Shared Processor
config = struct();
standardization_timer = tic;
config.script_dir = fileparts(mfilename('fullpath'));

% Dataset
config.evaluation_root = fileparts(config.script_dir);
config.repository_root = fileparts(config.evaluation_root);
config.trend_root = fullfile(config.evaluation_root, 'exp_inputs', 'TREND');
config.shared_dir = fullfile(config.repository_root, 'exp_validation', 'exp_scripts');
addpath(config.shared_dir, '-begin');
assert(strcmp(which('proc_enf_analysis'), fullfile(config.shared_dir, 'proc_enf_analysis.p')), ...
    'MATLAB resolved a different shared ENF processor.');
config.reference_filename = 'mains_pow_trace_ac.wav';
config.sensed_filename = 'fpga_em_trace_dc.wav';

% Parallel Processing
config.USE_PARALLEL = true;
config.NUM_PARALLEL_WORKERS = 6;

% Baseline ENF Verification
config.baseline_enf_extract = struct();
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

% Matching Threshold
config.R_EER = 0.9217;
config.FISHER_R_CLIP = 0.9999999;
config.MIN_OVERLAP_SEC = 60;

% ENF Harmonic Suppression
% Suppress original ENF-bearing harmonics using the configured band-stop
% filters.
forgery_cfg = struct();
forgery_cfg.ANALYSIS_FS_HZ = 1050;
forgery_cfg.NOMINAL_FREQ_HZ = 60;
forgery_cfg.ATTACK_HARMONIC_MULTS = 1:7;
forgery_cfg.ENF_SUPPRESS_HALF_BW_HZ = 1;
forgery_cfg.ENF_SUPPRESS_TRANSITION_BW_HZ = 8;
forgery_cfg.ENF_SUPPRESS_FIR_ORDER = 350;
forgery_cfg.ENF_SUPPRESS_FIR_WEIGHTS = [1 1 1];
forgery_cfg.ENF_SUPPRESS_CASCADE_PASSES = 2;

% Spectral Noise-Floor Reconstruction
% Reconstruct the suppressed spectral regions using neighboring-band noise
% statistics while preserving the required suppression floor.
forgery_cfg.NOISE_FILL_NEIGHBOR_BW_HZ = 2 * forgery_cfg.ENF_SUPPRESS_HALF_BW_HZ;
forgery_cfg.NOISE_FILL_MATCH_STAT = 'median';
forgery_cfg.NOISE_FILL_RANDOM_SEED = 42;

% Synthetic ENF Injection
% Generate an independent synthetic ENF trajectory and inject its harmonics
% into the modified signal.
% Pearson correlation is scale-invariant, so this changes the forgery's
% visual realism, not the trajectory shape that matching evaluates.
forgery_cfg.SYNTH_ENF_MAX_DEV_HZ = 0.03;
forgery_cfg.SYNTH_ENF_MOD_FREQS_HZ = [1/120, 1/45];
forgery_cfg.SYNTH_ENF_MOD_AMPS_HZ = [0.08, 0.04];
forgery_cfg.HARMONIC_PEAK_MATCH_BW_HZ = forgery_cfg.ENF_SUPPRESS_HALF_BW_HZ;
forgery_cfg.SYNTH_ENF_BASE_SEED = 42;

% Harmonic Selection and Peak Matching
% Select required and eligible optional harmonics, then adjust injected
% amplitudes to match host spectral peaks within the configured tolerances.
% Peak-match tolerance per harmonic (fraction of host peak).
% Fundamental: strict, since matching uses 60 Hz only.
% Higher harmonics: +/-2 dB, since weak even harmonics sit near the noise floor.
forgery_cfg.PEAK_MATCH_TOL_FUND = 0.01;
forgery_cfg.PEAK_MATCH_TOL_HARM = 10^(2/20) - 1;
% Inject a synthetic harmonic only where the host has a real harmonic peak:
% host local peak must exceed the median of its neighboring bands by this margin.
forgery_cfg.INJECT_MIN_SNR_DB = 10;
% These harmonics are always injected and checked, regardless of SNR
% (fundamental for matching; the original required odd-harmonic set).
forgery_cfg.ALWAYS_INJECT_MULTS = [1 3 5 7];
config.forgery = forgery_cfg;

% Representative Figure Selection
config.overlay_key = struct('Week','WK01','Day','THU','TimeOfDay','EMRN','Trial','T02');

% Results and Logging
config.results_root = fullfile(config.evaluation_root, 'exp_results', 'syn_forgery_attacks');
config.logs_root = fullfile(config.evaluation_root, 'exp_logs');
config.raw_csv = fullfile(config.results_root, 'syn_forgery_raw_results.csv');
config.summary_csv = fullfile(config.results_root, 'syn_forgery_results_summary.csv');
config.overlay_figure = fullfile(config.results_root, 'syn_forgery_enf_overlay.svg');
config.log_file = fullfile(config.logs_root, 'enf_analysis_top_syn_forgery_attacks_log.txt');


%% STEP_2) Setup: Logging and Output Directories
% Validate configuration, initialize outputs, and attach log cleanup.
validate_configuration(config);
[fileID, cleanup_log] = open_analysis_log(config);
log_configuration(config, fileID);
log_both(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));

%% STEP_3) Input Discovery and Validation
% Validate all 160 pairs and the deterministic representative-window selection.
try
    log_both(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    records = discover_trend_pairs(config, fileID);
    if isempty(records)
        error('No TREND measurement windows were found.');
    end
    overlay_mask=strcmp({records.Week},config.overlay_key.Week) & ...
        strcmp({records.Day},config.overlay_key.Day) & strcmp({records.TimeOfDay},config.overlay_key.TimeOfDay) & ...
        strcmp({records.LeafFolder},config.overlay_key.Trial);
    assert(sum(overlay_mask)==1,'Representative TREND example is missing or ambiguous.');
    config.overlay_window_id=records(overlay_mask).window_id;
    config=prepare_parallel_pool(config,fileID);
    log_both(fileID,'\nSynthetic forgery generation\n');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_4) Attack Construction and ENF Processing
% Apply ENF harmonic suppression, spectral noise-floor reconstruction, and
% synthetic ENF injection with harmonic peak matching to every fixed measurement.
try
    log_both(fileID, '\nSTEP_4) ATTACK CONSTRUCTION AND ENF PROCESSING\n%s\n', repmat('%',1,85));
    rows=cell(160,1);
    if config.USE_PARALLEL
        parfor index=1:numel(records)
            rows{index}=process_required_window(records(index),config);
        end
    else
        for index=1:numel(records)
            rows{index}=process_required_window(records(index),config);
        end
    end
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_5) Attack Validation and Statistical Analysis
% Verify suppression, peak matching, injection completeness, finite results, and seed uniqueness.
try
    log_both(fileID, '\nSTEP_5) ATTACK VALIDATION AND STATISTICAL ANALYSIS\n%s\n', repmat('%',1,85));
    rows=vertcat(rows{:});
    [~,order]=sort([rows.window_id]); rows=rows(order);
    validate_processed_rows(rows,config);
    for index=1:numel(rows)
        if ~isempty(rows(index).log_message)
            log_both(fileID,'%s\n',rows(index).log_message);
        end
    end
    raw_table=build_raw_table(rows,config); summary_table=build_summary_table(rows,config);
    assert(height(raw_table)==160,'Incomplete forgery output tables.');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_6) Results and Figures
% Write the original CSV formats and generate the existing representative overlay.
try
    log_both(fileID, '\nSTEP_6) RESULTS AND FIGURES\n%s\n', repmat('%',1,85));
    writetable(raw_table,config.raw_csv); writetable(summary_table,config.summary_csv);
    print_publication_summary(rows,summary_table,config,fileID);
    plot_enf_overlay(rows,config); validate_output_files(config);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_7) Final Summary and Logging
% Report the selected example, verification verdicts, outputs, and successful completion.
try
    log_both(fileID, '\nSTEP_7) FINAL SUMMARY AND LOGGING\n%s\n', repmat('%',1,85));
    overlay_row=rows([rows.window_id]==config.overlay_window_id);
    log_both(fileID,'\nFIGURE GENERATION\nComputed TREND example: %s/%s/%s/%s; window_id=%d; seed=%d.\n', ...
        overlay_row.Week,overlay_row.Day,overlay_row.TimeOfDay,overlay_row.LeafFolder,overlay_row.window_id,overlay_row.seed);
    log_both(fileID,'Authentic r=%.9f; forged r=%.9f; same reference and common frequency limits on both panels.\n',overlay_row.r_auth,overlay_row.r_forged);
    log_both(fileID,'Authentic verdict: %s; forged verdict: %s.\n', ...
        threshold_verdict(overlay_row.r_auth,config.R_EER),threshold_verdict(overlay_row.r_forged,config.R_EER));
    log_both(fileID,'Fixed representative selected by Week/Day/TimeOfDay/Trial metadata.\n');
    log_both(fileID,'\nRESULT FILES\nexp_evaluation/exp_results/syn_forgery_attacks/\n');
    log_both(fileID,'syn_forgery_raw_results.csv; syn_forgery_results_summary.csv\n');
    log_both(fileID,'exp_evaluation/exp_results/syn_forgery_attacks/syn_forgery_enf_overlay.{png,svg,fig}\n');
    log_both(fileID,'Total processed: %d; total accepted: %d; total rejected: %d.\nAll analysis complete.\n', ...
        numel(rows),sum([rows.accepted]),sum(~[rows.accepted]));
    log_both(fileID, 'Execution status: SUCCESS\nTotal execution time: %.3f s\n', toc(standardization_timer));
    clear cleanup_log;
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% Local Functions
% Validate dataset, estimator, parallel, and attack configuration values.
function validate_configuration(config)
    assert(isfolder(config.script_dir), 'Script directory does not exist: %s', config.script_dir);
    assert(isfolder(config.trend_root), 'TREND dataset root does not exist: %s', config.trend_root);
    assert(~isempty(config.reference_filename), 'reference_filename must not be empty.');
    assert(~isempty(config.sensed_filename), 'sensed_filename must not be empty.');
    assert(isscalar(config.R_EER) && isfinite(config.R_EER) && ...
        config.R_EER > 0 && config.R_EER < 1, 'R_EER must be in (0,1).');
    assert(config.FISHER_R_CLIP > 0 && config.FISHER_R_CLIP < 1, ...
        'FISHER_R_CLIP must be in (0,1).');
    assert(config.MIN_OVERLAP_SEC >= 60, 'MIN_OVERLAP_SEC must be at least 60 seconds.');
    parallel_ok = isscalar(config.USE_PARALLEL) && ...
        (islogical(config.USE_PARALLEL) || (isnumeric(config.USE_PARALLEL) && ...
        isfinite(config.USE_PARALLEL) && any(config.USE_PARALLEL == [0 1])));
    assert(parallel_ok, 'USE_PARALLEL must be a scalar logical or numeric boolean.');
    assert(isscalar(config.NUM_PARALLEL_WORKERS) && isfinite(config.NUM_PARALLEL_WORKERS) && ...
        config.NUM_PARALLEL_WORKERS >= 1 && config.NUM_PARALLEL_WORKERS == floor(config.NUM_PARALLEL_WORKERS), ...
        'NUM_PARALLEL_WORKERS must be a positive integer.');
    b = config.baseline_enf_extract;
    assert(b.analysis_fs == 1050 && b.frame_size == 8000 && b.overlap_size == 0 && ...
        b.nfft == 32768 && b.nominal_freq == 60 && b.reference_method == 1 && ...
        b.sensed_method == 1 && b.reference_est_freq == 60 && b.sensed_est_freq == 60 && ...
        isequal(b.reference_harmonics, 60) && isequal(b.sensed_harmonics, 60) && ...
        isequal(b.reference_spec_comb_harmonics, 60) && ...
        isequal(b.sensed_spec_comb_harmonics, 60), ...
        'Baseline ENF estimator settings are invalid.');

    a = config.forgery;
    assert(a.ANALYSIS_FS_HZ == 1050 && a.NOMINAL_FREQ_HZ == 60, ...
        'AF sample rate and nominal frequency must be 1050 Hz and 60 Hz.');
    assert(isequal(a.ATTACK_HARMONIC_MULTS, 1:7), ...
        'ATTACK_HARMONIC_MULTS must be 1:7.');
    assert(isfinite(a.PEAK_MATCH_TOL_FUND) && a.PEAK_MATCH_TOL_FUND > 0 && ...
        isfinite(a.PEAK_MATCH_TOL_HARM) && a.PEAK_MATCH_TOL_HARM > 0, ...
        'Peak-match tolerances must be finite and positive.');
    assert(isfinite(a.INJECT_MIN_SNR_DB) && isscalar(a.INJECT_MIN_SNR_DB), ...
        'INJECT_MIN_SNR_DB must be a finite scalar.');
    assert(~isempty(a.ALWAYS_INJECT_MULTS) && ...
        all(ismember(a.ALWAYS_INJECT_MULTS, a.ATTACK_HARMONIC_MULTS)), ...
        'ALWAYS_INJECT_MULTS must be a non-empty subset of ATTACK_HARMONIC_MULTS.');
    highest_edge = max(a.ATTACK_HARMONIC_MULTS) * a.NOMINAL_FREQ_HZ + a.ENF_SUPPRESS_TRANSITION_BW_HZ;
    assert(highest_edge < a.ANALYSIS_FS_HZ / 2, ...
        'Highest attacked harmonic plus transition band must remain below Nyquist.');
end

% Create result directories and open the cleanup-managed analysis log.
function [fileID, cleanup_log] = open_analysis_log(config)
    if ~isfolder(config.results_root), mkdir(config.results_root); end
    if ~isfolder(config.logs_root), mkdir(config.logs_root); end
    fileID = fopen(config.log_file, 'w');
    if fileID < 0, error('Cannot open log file: %s', config.log_file); end
    cleanup_log = onCleanup(@() fclose(fileID));
end

% Report the fixed synthetic-forgery configuration.
function log_configuration(config, fileID)
    a=config.forgery; b=config.baseline_enf_extract;
    log_both(fileID, '%s\nENF SYNTHETIC FORGERY ATTACKS\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
    log_both(fileID,'\nEXPERIMENT CONFIGURATION\nDataset: exp_evaluation/exp_inputs/TREND/\n');
    log_both(fileID,'Weeks: WK01, WK02; days: WED, THU, SAT, SUN; times: EMRN, MORN, AFTN, EVEN; trials: T01-T05.\n');
    log_both(fileID,'Expected measurements: 160; deterministic window IDs within the fixed inventory.\n');
    log_both(fileID,'\nBASELINE VERIFIER CONFIGURATION\nFs=%g Hz; frame=%d samples; overlap=%d; FFT setting=%d; methods=%d/%d; target=%g Hz; gamma=3.\n', ...
        b.analysis_fs,b.frame_size,b.overlap_size,b.nfft,b.reference_method,b.sensed_method,b.reference_est_freq);
    log_both(fileID,'Threshold r_EER=%.6f; accept iff r >= threshold; zero lag; lag optimization disabled.\n',config.R_EER);
    log_both(fileID,'Attack-host preprocessing: mean removal, resample(1050, fs_in), and peak normalization.\n');
    log_both(fileID,'Reference preprocessing uses shared-core decimation; the same reference ENF serves authentic and forged verification.\n');
    log_both(fileID,'\nATTACK CONFIGURATION\nENF Harmonic Suppression: harmonics [%s]; half-BW=%.1f Hz; transition=%.1f Hz; FIR order=%d; weights=[%s]; passes=%d.\n', ...
        format_numeric_list(a.ATTACK_HARMONIC_MULTS),a.ENF_SUPPRESS_HALF_BW_HZ,a.ENF_SUPPRESS_TRANSITION_BW_HZ,a.ENF_SUPPRESS_FIR_ORDER,format_numeric_list(a.ENF_SUPPRESS_FIR_WEIGHTS),a.ENF_SUPPRESS_CASCADE_PASSES);
    log_both(fileID,'Spectral Noise-Floor Reconstruction: neighbor-BW=%.1f Hz; %s noise matching; seed=%d; >=20 dB suppression with 0.5 dB guard.\n', ...
        a.NOISE_FILL_NEIGHBOR_BW_HZ,a.NOISE_FILL_MATCH_STAT,a.NOISE_FILL_RANDOM_SEED);
    log_both(fileID,'Synthetic ENF Injection: nominal=60 Hz; max deviation=%.6f Hz; modulation frequencies=[%s]; amplitudes=[%s].\n', ...
        a.SYNTH_ENF_MAX_DEV_HZ,format_numeric_list(a.SYNTH_ENF_MOD_FREQS_HZ),format_numeric_list(a.SYNTH_ENF_MOD_AMPS_HZ));
    log_both(fileID,'Seed rule: %d + window_id. Required injected multipliers=[%s]; optional=[2 4 6]; SNR criterion=%.6f dB.\n', ...
        a.SYNTH_ENF_BASE_SEED,format_numeric_list(a.ALWAYS_INJECT_MULTS),a.INJECT_MIN_SNR_DB);
    log_both(fileID,'Peak tolerance: fundamental=%.6f; higher harmonics=%.6f.\n',a.PEAK_MATCH_TOL_FUND,a.PEAK_MATCH_TOL_HARM);
    log_both(fileID,'Random generator: combRecursive (mrg32k3a) on client and workers.\n');
end

% Create or reuse the configured local parallel pool.
function config = prepare_parallel_pool(config, fileID)
    if config.USE_PARALLEL
        try
            pool=gcp('nocreate');
            if isempty(pool)
                pool=parpool('local',config.NUM_PARALLEL_WORKERS);
            end
            config.NUM_PARALLEL_WORKERS=pool.NumWorkers;
            log_both(fileID,'Processing mode: parallel (%d workers).\n',pool.NumWorkers);
        catch
            config.USE_PARALLEL=false;
            log_both(fileID,'Processing mode: serial fallback (parallel pool unavailable).\n');
        end
    else
        log_both(fileID,'Processing mode: serial.\n');
    end
end

% Discover the deterministic 160-recording TREND inventory.
function records = discover_trend_pairs(config, fileID)
    weeks={'WK01','WK02'}; days={'WED','THU','SAT','SUN'};
    day_folders={'WED','THUR','SAT','SUN'}; day_types={'WDAY','WDAY','WEND','WEND'};
    times={'EMRN','MORN','AFTN','EVEN'}; trials={'T01','T02','T03','T04','T05'};
    template=struct('window_id',0,'measurement_folder','','Week','','DayType','','Day','', ...
        'TimeOfDay','','LeafFolder','','host_full_path','','ref_full_path','');
    records=repmat(template,160,1); expected_paths=strings(320,1); index=0;
    for w=1:2
        for d=1:4
            if d==2
                assert(~isfolder(fullfile(config.trend_root,weeks{w},'WDAY','THU')), ...
                    'Ambiguous Thursday layout; expected WDAY/THUR for %s.',weeks{w});
            end
            for t=1:4
                for k=1:5
                    index=index+1;
                    relative=fullfile(weeks{w},day_types{d},day_folders{d},times{t},trials{k});
                    rec=template;
                    rec.measurement_folder=strrep(relative,'\','/');
                    rec.Week=weeks{w}; rec.DayType=day_types{d}; rec.Day=days{d};
                    rec.TimeOfDay=times{t}; rec.LeafFolder=trials{k};
                    rec.host_full_path=fullfile(config.trend_root,relative,config.sensed_filename);
                    rec.ref_full_path=fullfile(config.trend_root,relative,config.reference_filename);
                    paths={rec.ref_full_path,rec.host_full_path};
                    for channel=1:2
                        path=paths{channel};
                        assert(isfile(path),'Missing required input: %s (channel %d).',rec.measurement_folder,channel);
                        info=audioinfo(path);
                        assert(info.NumChannels==1 && info.SampleRate==44100, ...
                            'Expected mono 44100 Hz input: %s (channel %d).',rec.measurement_folder,channel);
                        assert(abs(info.Duration-200)<=1/info.SampleRate, ...
                            'Expected nominal 200 s input: %s (%.9f s).',rec.measurement_folder,info.Duration);
                        expected_paths(2*(index-1)+channel)=string(path);
                    end
                    records(index)=rec;
                end
            end
        end
    end
    found=dir(fullfile(config.trend_root,'**','*.wav'));
    found_paths=strings(numel(found),1);
    for k=1:numel(found), found_paths(k)=string(fullfile(found(k).folder,found(k).name)); end
    assert(index==160 && numel(unique(string({records.measurement_folder})))==160 && ...
        numel(found_paths)==320 && isequal(sort(found_paths),sort(expected_paths)), ...
        'Require exactly 160 unique pairs and 320 WAVs.');
    % Assign deterministic measurement-to-seed mappings using lexical ranks
    % of fixed relative identifiers, independent of dir() and worker order.
    [~, order]=sort(lower(string({records.measurement_folder})));
    records=records(order);
    for k=1:160, records(k).window_id=k; end
    log_both(fileID,'\nINPUT VALIDATION\nExpected pairs: 160; found pairs: %d; validated pairs: %d.\n',index,numel(records));
    log_both(fileID,'Duration: 200 s on both channels; tolerance one 44100 Hz source sample.\n');
    log_both(fileID,'Selection matches the fixed Section 6.1 inventory; THUR maps to THU metadata.\n');
    log_both(fileID,'window_id is the lexical rank of the fixed relative folder and determines the synthetic-ENF seed.\n');
end









% Process one required window with deterministic worker random streams.
function row = process_required_window(rec, config)
    try
        row=process_forgery_window(rec,config);
    catch processing_error
        error('SyntheticForgery:ProcessingFailed','%s/%s/%s/%s (window %d): %s', ...
            rec.Week,rec.Day,rec.TimeOfDay,rec.LeafFolder,rec.window_id,processing_error.message);
    end
end

% Construct, verify, and score all three descriptive forgery stages for one window.
function row = process_forgery_window(rec, config)
    a = config.forgery;
    [host, host_fs] = af_load_mono_trace_resampled(rec.host_full_path, a.ANALYSIS_FS_HZ, true);
    if host_fs ~= a.ANALYSIS_FS_HZ, error('Unexpected resampled host rate.'); end
    [~, ref_name, ref_ext] = fileparts(rec.ref_full_path);
    reference = load_wav_trace(rec.ref_full_path, [ref_name ref_ext]);
    duration_sec = min(numel(host) / host_fs, ...
        reference.num_samples / reference.source_fs);
    if duration_sec < config.MIN_OVERLAP_SEC
        error('Window %d has only %.3f seconds of common data; %.0f required.', ...
            rec.window_id, duration_sec, config.MIN_OVERLAP_SEC);
    end
    host = host(1:floor(duration_sec * host_fs));
    duration_sec = numel(host) / host_fs;
    reference.waveform = reference.waveform( ...
        1:floor(duration_sec * reference.source_fs));
    reference.num_samples = numel(reference.waveform);

    enf_suppressed = host;
    for pass = 1:a.ENF_SUPPRESS_CASCADE_PASSES
        enf_suppressed = af_apply_enf_bandstop_removal(enf_suppressed, host_fs, a);
    end
    [~, noise_components] = af_generate_bandpassed_noise_fill( ...
        host, numel(host), host_fs, a);
    [suppressed, noise_fill_scales] = af_add_noise_fill_with_suppression_floor( ...
        host, enf_suppressed, noise_components, host_fs, a, 20);

    harmonic_count = numel(a.ATTACK_HARMONIC_MULTS);
    suppression_db = nan(1, harmonic_count);
    for h = 1:harmonic_count
        center_hz = a.ATTACK_HARMONIC_MULTS(h) * a.NOMINAL_FREQ_HZ;
        original_peak = af_fft_local_peak_abs(host, host_fs, center_hz, a.HARMONIC_PEAK_MATCH_BW_HZ);
        suppressed_peak = af_fft_local_peak_abs(suppressed, host_fs, center_hz, a.HARMONIC_PEAK_MATCH_BW_HZ);
        suppression_db(h) = 20 * log10(max(original_peak, eps) / max(suppressed_peak, eps));
    end
    if any(~isfinite(suppression_db)) || any(suppression_db < 20)
        error('Window %d failed the >=20 dB all-harmonic suppression requirement: [%s] dB.', ...
            rec.window_id, format_numeric_list(suppression_db));
    end

    host_snr_db = nan(1, harmonic_count);
    for h = 1:harmonic_count
        m = a.ATTACK_HARMONIC_MULTS(h);
        center_hz = m * a.NOMINAL_FREQ_HZ;
        host_peak = af_fft_local_peak_abs( ...
            host, host_fs, center_hz, a.HARMONIC_PEAK_MATCH_BW_HZ);
        [~, ~, s1, s2, valid_edges] = af_get_noise_fill_band_edges(center_hz, host_fs, a);
        if ~valid_edges
            error('Window %d has invalid SNR-neighbor bands at harmonic %g.', ...
                rec.window_id, m);
        end
        neighbor_bw = a.NOISE_FILL_NEIGHBOR_BW_HZ;
        neighbor_bands = af_prune_invalid_bands([ ...
            max(0, s1-neighbor_bw), s1; ...
            s2, min(host_fs/2, s2+neighbor_bw)]);
        host_floor = af_fft_band_stat_abs(host, host_fs, neighbor_bands, 'median');
        host_snr_db(h) = 20*log10(max(host_peak,eps) / max(host_floor,eps));
    end
    if any(~isfinite(host_snr_db))
        error('Window %d produced a non-finite host harmonic SNR.', rec.window_id);
    end
    always_mask = ismember(a.ATTACK_HARMONIC_MULTS, a.ALWAYS_INJECT_MULTS);
    missing_required = always_mask & (host_snr_db < a.INJECT_MIN_SNR_DB);
    if any(missing_required)
        error(['Window %d lacks required experiment harmonics above %.1f dB SNR: ' ...
            'multipliers=[%s], SNR dB=[%s].'], rec.window_id, a.INJECT_MIN_SNR_DB, ...
            format_numeric_list(a.ATTACK_HARMONIC_MULTS(missing_required)), ...
            format_numeric_list(host_snr_db(missing_required)));
    end
    inject_mask = always_mask | (host_snr_db >= a.INJECT_MIN_SNR_DB);
    required = ismember(a.ATTACK_HARMONIC_MULTS, a.ALWAYS_INJECT_MULTS);
    optional = inject_mask & ~required;
    injected_mults = a.ATTACK_HARMONIC_MULTS(inject_mask);

    seed_w = a.SYNTH_ENF_BASE_SEED + rec.window_id;
    cfg_w = a;
    cfg_w.SYNTH_ENF_RANDOM_SEED = seed_w;
    cfg_w.ATTACK_HARMONIC_MULTS = injected_mults;
    synthetic_all = af_generate_syn_enf_component(numel(host), host_fs, cfg_w);

    components = cell(1, harmonic_count);
    injected_indices = find(inject_mask);
    for h = 1:numel(injected_indices)
        full_index = injected_indices(h);
        m = a.ATTACK_HARMONIC_MULTS(full_index);
        center_hz = m * a.NOMINAL_FREQ_HZ;
        [b_bp, ~, valid] = af_design_paper_equiripple_filters(host_fs, center_hz, a);
        if ~valid, error('Invalid synthetic bandpass at %.1f Hz.', center_hz); end
        components{full_index} = af_apply_fir_single_pass_compensated(synthetic_all, b_bp);
    end

    peak_tolerances = peak_match_tolerances(a);
    active = inject_mask;
    dropped_mask = false(size(active));
    dropped_details = {};
    peak_match_succeeded = false;
    for attempt = 1:numel(active)
        active_mults = a.ATTACK_HARMONIC_MULTS(active);
        [forged, active_scales, active_targets, active_finals, active_errors] = ...
            af_joint_peak_match_all_harmonics( ...
            host, suppressed, components(active), host_fs, a, active_mults);
        scales = nan(1, harmonic_count);
        target_peaks = nan(1, harmonic_count);
        final_peaks = nan(1, harmonic_count);
        peak_error_fraction = nan(1, harmonic_count);
        scales(active) = active_scales;
        target_peaks(active) = active_targets;
        final_peaks(active) = active_finals;
        peak_error_fraction(active) = active_errors;

        fail = active & (peak_error_fraction > peak_tolerances | ...
            ~isfinite(peak_error_fraction));
        if ~any(fail)
            peak_match_succeeded = true;
            break;
        end
        if any(fail & required)
            error(['Window %d failed the peak-match requirement on a required harmonic: ' ...
                'errors=[%s], tolerances=[%s].'], rec.window_id, ...
                format_numeric_list(peak_error_fraction), ...
                format_numeric_list(peak_tolerances));
        end

        candidates = find(fail & optional);
        if isempty(candidates)
            error('Window %d has no optional failing harmonic available to drop.', rec.window_id);
        end
        [~, worst] = max(peak_error_fraction(candidates));
        drop_index = candidates(worst);
        component_scale = scales(drop_index);
        base_trace = forged - component_scale*components{drop_index};
        center_hz = a.ATTACK_HARMONIC_MULTS(drop_index) * a.NOMINAL_FREQ_HZ;
        base_peak = af_fft_local_peak_abs( ...
            base_trace, host_fs, center_hz, a.HARMONIC_PEAK_MATCH_BW_HZ);
        dropped_details{end+1} = struct( ... %#ok<AGROW>
            'multiplier', a.ATTACK_HARMONIC_MULTS(drop_index), ...
            'frequency_hz', center_hz, ...
            'target_peak', target_peaks(drop_index), ...
            'base_peak', base_peak, ...
            'final_peak', final_peaks(drop_index), ...
            'error', peak_error_fraction(drop_index), ...
            'background_exceeds_target', base_peak > target_peaks(drop_index));
        active(drop_index) = false;
        dropped_mask(drop_index) = true;
    end
    if ~peak_match_succeeded
        error('Window %d exhausted optional-harmonic exclusions without a valid peak match.', ...
            rec.window_id);
    end
    inject_mask = active;
    assert(numel(forged)==numel(host) && all(isfinite(forged)) && all(isfinite(host)), ...
        'Invalid finite waveform or length for window %d.',rec.window_id);

    % Extract the single reference exactly once and reuse it for both
    % lag-zero comparisons. The second call extracts only the forged trace.
    [enf_ref, enf_host] = extract_enf_pair( ...
        reference.waveform, reference.source_fs, host, host_fs, ...
        config.baseline_enf_extract, config.MIN_OVERLAP_SEC);
    [~, enf_forged] = extract_enf_pair( ...
        host, host_fs, forged, host_fs, ...
        config.baseline_enf_extract, config.MIN_OVERLAP_SEC);

    r_forged = correlate_enf_lag_zero(enf_ref, enf_forged);
    r_auth = correlate_enf_lag_zero(enf_ref, enf_host);
    if ~isfinite(r_forged) || ~isfinite(r_auth)
        error('Window %d produced a non-finite verification correlation.', rec.window_id);
    end

    [~, host_name, host_ext] = fileparts(rec.host_full_path);
    [~, ref_name, ref_ext] = fileparts(rec.ref_full_path);
    row = struct();
    row.window_id = rec.window_id;
    row.measurement_folder = rec.measurement_folder;
    row.Week = rec.Week;
    row.DayType = rec.DayType;
    row.Day = rec.Day;
    row.TimeOfDay = rec.TimeOfDay;
    row.LeafFolder = rec.LeafFolder;
    row.host_file = [host_name host_ext];
    row.ref_file = [ref_name ref_ext];
    row.seed = seed_w;
    row.eval_duration_sec = duration_sec;
    row.r_forged = r_forged;
    row.r_auth = r_auth;
    row.accepted = r_forged >= config.R_EER;
    row.peak_scale = scales;
    row.target_peaks = target_peaks;
    row.final_peaks = final_peaks;
    row.host_snr_db = host_snr_db;
    row.inject_mask = logical(inject_mask);
    row.dropped_mask = logical(dropped_mask);
    row.dropped_details = dropped_details;
    row.suppression_db = suppression_db;
    row.noise_fill_scale = noise_fill_scales;
    row.enf_host = enf_host;
    row.enf_forged = enf_forged;
    row.enf_ref = enf_ref;
    row.log_message = build_window_log_message(row, rec, config);
end

% Report exceptions with full window context; routine measurements remain in the raw CSV.
function message = build_window_log_message(row, rec, config)
    message = '';
    if all(row.inject_mask) && ~any(row.dropped_mask) && ...
            ~row.accepted && row.r_auth >= config.R_EER
        return;
    end
    lines={sprintf('Window %d: %s/%s/%s/%s; seed=%d; duration=%.6f s', ...
        row.window_id,rec.Week,rec.Day,rec.TimeOfDay,rec.LeafFolder,row.seed,row.eval_duration_sec), ...
        sprintf('  Suppression PASS: m1..m7=[%s] dB',format_numeric_list(row.suppression_db)), ...
        sprintf('  Injected multipliers=[%s]; excluded optional multipliers=[%s]; dropped after matching=[%s]', ...
        format_numeric_list(config.forgery.ATTACK_HARMONIC_MULTS(row.inject_mask)), ...
        format_numeric_list(config.forgery.ATTACK_HARMONIC_MULTS(~row.inject_mask)), ...
        format_numeric_list(config.forgery.ATTACK_HARMONIC_MULTS(row.dropped_mask)))};
    errors=abs(row.final_peaks-row.target_peaks)./max(row.target_peaks,eps);
    lines{end+1}=sprintf('  Peak matching PASS: active errors=[%s]',format_numeric_list(errors(row.inject_mask)));
    lines{end+1}=sprintf('  Authentic r=%.9f; forged r=%.9f; accepted=%s',row.r_auth,row.r_forged,yes_no(row.accepted));
    message=strjoin(lines,newline);
end

% Validate all processed rows, deterministic seeds, and attack checks.
function validate_processed_rows(rows, config)
    assert(numel(rows)==160 && isequal([rows.window_id].', (1:160).'), ...
        'Require exactly 160 forgeries in deterministic window order.');
    all_r = [[rows.r_forged], [rows.r_auth]];
    if any(~isfinite(all_r)), error('All verification correlations must be finite.'); end
    seeds = [rows.seed];
    if numel(unique(seeds)) ~= numel(seeds), error('Per-window forgery seeds must be distinct.'); end
    for k = 1:numel(rows)
        if any(rows(k).suppression_db < 20), error('Window %d suppression validation failed.', k); end
        if numel(rows(k).inject_mask) ~= numel(config.forgery.ATTACK_HARMONIC_MULTS) || ...
                numel(rows(k).dropped_mask) ~= numel(config.forgery.ATTACK_HARMONIC_MULTS)
            error('Window %d has an invalid injection or dropped mask.', k);
        end
        peak_error = abs(rows(k).final_peaks - rows(k).target_peaks) ./ max(rows(k).target_peaks, eps);
        checked = logical(rows(k).inject_mask);
        required = ismember(config.forgery.ATTACK_HARMONIC_MULTS, config.forgery.ALWAYS_INJECT_MULTS);
        if any(required & ~checked)
            error('Window %d is missing a required injected harmonic.', k);
        end
        if any(logical(rows(k).dropped_mask) & (checked | required))
            error('Window %d has an invalid dropped-harmonic decision.', k);
        end
        tolerance = peak_match_tolerances(config.forgery);
        if any(~isfinite(peak_error(checked))) || any(peak_error(checked) > tolerance(checked))
            error('Window %d peak-match validation failed.', k);
        end
    end
    if any(abs(all_r) > 1)
        error('A verification correlation exceeded its valid range.');
    end
    if config.R_EER <= 0 || config.R_EER >= 1, error('Invalid matching threshold.'); end
end

% Verify that every configured CSV and figure output was created.
function validate_output_files(config)
    required = {config.raw_csv, config.summary_csv, config.overlay_figure, ...
        strrep(config.overlay_figure,'.svg','.png'),strrep(config.overlay_figure,'.svg','.fig')};
    missing = required(~cellfun(@isfile, required));
    if ~isempty(missing)
        error('Required synthetic-forgery outputs were not written: %s', strjoin(missing, ', '));
    end
end

% Build the fixed-schema raw synthetic-forgery result table.
function T = build_raw_table(rows, config)
    n = numel(rows);
    window_id = reshape([rows.window_id], [], 1);
    measurement_folder = string({rows.measurement_folder}).';
    Week = string({rows.Week}).';
    DayType = string({rows.DayType}).';
    Day = string({rows.Day}).';
    TimeOfDay = string({rows.TimeOfDay}).';
    LeafFolder = string({rows.LeafFolder}).';
    host_file = string({rows.host_file}).';
    ref_file = string({rows.ref_file}).';
    seed = reshape([rows.seed], [], 1);
    eval_duration_sec = reshape([rows.eval_duration_sec], [], 1);
    r_forged = reshape([rows.r_forged], [], 1);
    z_forged = fisher_z(r_forged, config.FISHER_R_CLIP);
    r_auth = reshape([rows.r_auth], [], 1);
    z_auth = fisher_z(r_auth, config.FISHER_R_CLIP);
    accepted = logical(reshape([rows.accepted], [], 1));
    ps = reshape([rows.peak_scale], 7, n).';
    host_snr = reshape([rows.host_snr_db], 7, n).';
    injected = logical(reshape([rows.inject_mask], 7, n).');
    dropped = logical(reshape([rows.dropped_mask], 7, n).');
    T = table(window_id, measurement_folder, Week, DayType, Day, TimeOfDay, ...
        LeafFolder, host_file, ref_file, seed, eval_duration_sec, ...
        r_forged, z_forged, r_auth, z_auth, accepted, ...
        ps(:,1), ps(:,2), ps(:,3), ps(:,4), ps(:,5), ps(:,6), ps(:,7), ...
        host_snr(:,1), host_snr(:,2), host_snr(:,3), host_snr(:,4), ...
        host_snr(:,5), host_snr(:,6), host_snr(:,7), ...
        injected(:,1), injected(:,2), injected(:,3), injected(:,4), ...
        injected(:,5), injected(:,6), injected(:,7), ...
        dropped(:,1), dropped(:,2), dropped(:,3), dropped(:,4), ...
        dropped(:,5), dropped(:,6), dropped(:,7), ...
        'VariableNames', raw_column_names());
    T.Trial=T.LeafFolder;
    suppression=vertcat(rows.suppression_db); targets=vertcat(rows.target_peaks);
    finals=vertcat(rows.final_peaks); fill=vertcat(rows.noise_fill_scale);
    errors=abs(finals-targets)./max(targets,eps);
    for harmonic=1:7
        T.(sprintf('suppression_db_m%d',harmonic))=suppression(:,harmonic);
        T.(sprintf('target_peak_m%d',harmonic))=targets(:,harmonic);
        T.(sprintf('final_peak_m%d',harmonic))=finals(:,harmonic);
        T.(sprintf('peak_match_error_m%d',harmonic))=errors(:,harmonic);
        T.(sprintf('noise_fill_scale_m%d',harmonic))=fill(:,harmonic);
    end
end

% Return the established raw-result column names.
function names = raw_column_names()
    names = {'window_id','measurement_folder','Week','DayType','Day','TimeOfDay', ...
        'LeafFolder','host_file','ref_file','seed','eval_duration_sec', ...
        'r_forged','z_forged','r_auth','z_auth','accepted', ...
        'peak_scale_m1','peak_scale_m2', ...
        'peak_scale_m3','peak_scale_m4','peak_scale_m5','peak_scale_m6','peak_scale_m7', ...
        'host_snr_db_m1','host_snr_db_m2','host_snr_db_m3','host_snr_db_m4', ...
        'host_snr_db_m5','host_snr_db_m6','host_snr_db_m7', ...
        'injected_m1','injected_m2','injected_m3','injected_m4', ...
        'injected_m5','injected_m6','injected_m7', ...
        'dropped_m1','dropped_m2','dropped_m3','dropped_m4', ...
        'dropped_m5','dropped_m6','dropped_m7'};
end


% Build the grouped synthetic-forgery summary table.
function T = build_summary_table(rows, config)
    forged = reshape([rows.r_forged], [], 1);
    authentic = reshape([rows.r_auth], [], 1);
    window_count = numel(rows);
    group_names = {'forged','authentic'};
    values = {forged, authentic};
    if any(cellfun(@numel, values) ~= window_count)
        error('Summary groups must each contain exactly N window values.');
    end
    T = table('Size', [numel(values), numel(summary_column_names())], ...
        'VariableTypes', {'string','double','double','double','double','double', ...
        'double','double','double','double','double'}, 'VariableNames', summary_column_names());
    for k = 1:numel(values)
        v = values{k};
        z = fisher_z(v, config.FISHER_R_CLIP);
        T.group(k) = string(group_names{k});
        T.N(k) = numel(v);
        T.mean_r(k) = mean(v);
        T.std_r(k) = std(v);
        T.min_r(k) = min(v);
        T.max_r(k) = max(v);
        T.mean_z(k) = mean(z);
        T.std_z(k) = std(z);
        if k == 1
            T.acceptance_rate(k) = mean(v >= config.R_EER);
            T.margin_to_threshold(k) = config.R_EER - max(v);
        else
            T.acceptance_rate(k) = NaN;
            T.margin_to_threshold(k) = NaN;
        end
        T.r_eer(k) = config.R_EER;
    end
    if height(T) ~= 2 || ~isequal(cellstr(T.group), group_names.') || ...
            any(T.N ~= window_count)
        error('Summary table groups, order, or counts are invalid.');
    end
end



% Return the established summary-table column names.
function names = summary_column_names()
    names = {'group','N','mean_r','std_r','min_r','max_r','mean_z','std_z', ...
        'acceptance_rate','r_eer','margin_to_threshold'};
end

% Report publication summary statistics and attack decisions.
function print_publication_summary(rows, summary, config, fileID)
    forged=require_summary_group(summary,'forged'); authentic=require_summary_group(summary,'authentic');
    accepted=sum([rows.accepted]); rejected=numel(rows)-accepted;
    log_both(fileID,'\nFORGERY VERIFICATION RESULTS\n');
    log_both(fileID,'%-12s | %5s | %12s | %12s | %12s | %12s\n','Trace','N','Mean r','Sample SD','Minimum r','Maximum r');
    for group={forged,authentic}
        g=group{1};
        log_both(fileID,'%-12s | %5d | %12.9f | %12.9f | %12.9f | %12.9f\n',g.group,g.N,g.mean_r,g.std_r,g.min_r,g.max_r);
    end
    log_both(fileID,'Threshold=%.6f; accepted=%d; rejected=%d; acceptance rate=%.6f%%; rejection rate=%.6f%%.\n', ...
        config.R_EER,accepted,rejected,100*accepted/numel(rows),100*rejected/numel(rows));
    log_both(fileID,'Margin below threshold=%.9f.\n',forged.margin_to_threshold);
    log_both(fileID,'\nATTACK GENERATION SUMMARY\n');
    suppression=vertcat(rows.suppression_db); counts=arrayfun(@(r)sum(r.inject_mask),rows);
    log_both(fileID,'Validated forgeries: %d/%d\nMinimum harmonic suppression: %.9f dB\n',numel(rows),forged.N,min(suppression(:)));
    log_both(fileID,'All seven harmonics injected: %d/%d\n',sum(counts==7),numel(rows));
    if any(counts~=7)
        for n=unique(counts(:)).'
            log_both(fileID,'Windows with %d injected harmonics: %d\n',n,sum(counts==n));
        end
    end
    omissions=find(counts<7);
    if ~isempty(omissions)
        for index=omissions(:).'
            row=rows(index);
            log_both(fileID,'Excluded harmonics: window %d (%s/%s/%s/%s), multipliers=[%s].\n', ...
                row.window_id,row.Week,row.Day,row.TimeOfDay,row.LeafFolder,format_numeric_list(config.forgery.ATTACK_HARMONIC_MULTS(~row.inject_mask)));
        end
    end
    tolerance=peak_match_tolerances(config.forgery);
    peak_pass=false(size(rows));
    for index=1:numel(rows)
        row=rows(index);
        errors=abs(row.final_peaks-row.target_peaks)./max(row.target_peaks,eps);
        active=logical(row.inject_mask);
        peak_pass(index)=all(isfinite(errors(active))) && all(errors(active)<=tolerance(active));
    end
    if all(peak_pass), status='PASS'; else, status='FAIL'; end
    log_both(fileID,'Harmonic Peak Matching: %s (%d/%d)\n',status,sum(peak_pass),numel(rows));
end

% Return one uniquely named row from the summary table.
function row = require_summary_group(summary, group_name)
    matches = summary(summary.group == string(group_name), :);
    if height(matches) ~= 1
        error('Summary table must contain exactly one "%s" row.', group_name);
    end
    row = matches(1,:);
end

% Generate and export the representative authentic/forged ENF overlay.
function plot_enf_overlay(rows, config)
    row = rows([rows.window_id] == config.overlay_window_id);
    if numel(row) ~= 1
        error('Could not resolve overlay window ID %d.', config.overlay_window_id);
    end
    hop_sec = config.baseline_enf_extract.frame_size / ...
        config.baseline_enf_extract.analysis_fs;

    auth_ref = row.enf_ref(:);
    auth_sensed = row.enf_host(:);
    forged_ref = row.enf_ref(:);
    forged_sensed = row.enf_forged(:);
    n_auth = min(numel(auth_ref), numel(auth_sensed));
    n_forged = min(numel(forged_ref), numel(forged_sensed));
    auth_ref = auth_ref(1:n_auth); auth_sensed = auth_sensed(1:n_auth);
    forged_ref = forged_ref(1:n_forged); forged_sensed = forged_sensed(1:n_forged);
    t_auth = (0:n_auth-1).' * hop_sec;
    t_forged = (0:n_forged-1).' * hop_sec;

    all_enf = [auth_ref; auth_sensed; forged_ref; forged_sensed];
    y_min = min(all_enf); y_max = max(all_enf);
    y_padding = max(0.005, 0.08 * max(y_max-y_min, eps));
    common_ylim = [y_min-y_padding, y_max+y_padding];

    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 920 700]);
    ax1 = subplot(2,1,1, 'Parent', fig); hold(ax1, 'on');
    plot(ax1, t_auth, auth_ref, 'k-', 'LineWidth', 1.4);
    plot(ax1, t_auth, auth_sensed, '--', 'Color', [0.10 0.45 0.80], 'LineWidth', 1.5);
    metadata_label = sprintf('%s %s %s %s %s', row.Week, row.DayType, ...
        row.Day, row.TimeOfDay, row.LeafFolder);
    title(ax1, {'(a) Authentic'; metadata_label});
    ylabel(ax1, 'ENF (Hz)');
    ylim(ax1, common_ylim); grid(ax1, 'on'); box(ax1, 'on');
    auth_verdict = threshold_verdict(row.r_auth, config.R_EER);
    text(ax1, 0.02, 0.90, sprintf('r = %.4f, %s', row.r_auth, auth_verdict), ...
        'Units', 'normalized', 'FontName', 'Arial', 'FontSize', 10, ...
        'BackgroundColor', 'w', 'Margin', 3);

    % Dummy handles provide one shared three-entry legend without duplicating
    % reference entries from the two panels.
    h_ref = plot(ax1, nan, nan, 'k-', 'LineWidth', 1.4);
    h_auth = plot(ax1, nan, nan, '--', 'Color', [0.10 0.45 0.80], 'LineWidth', 1.5);
    h_forged = plot(ax1, nan, nan, '--', 'Color', [0.90 0.45 0.10], 'LineWidth', 1.5);
    legend(ax1, [h_ref h_auth h_forged], ...
        {'Mains reference ENF','Authentic sensed ENF','Synthetic forgery ENF'}, ...
        'Location', 'northoutside', 'Orientation', 'horizontal');

    ax2 = subplot(2,1,2, 'Parent', fig); hold(ax2, 'on');
    plot(ax2, t_forged, forged_ref, 'k-', 'LineWidth', 1.4);
    plot(ax2, t_forged, forged_sensed, '--', 'Color', [0.90 0.45 0.10], 'LineWidth', 1.5);
    title(ax2, '(b) Synthetic forgery');
    xlabel(ax2, 'Time (s)'); ylabel(ax2, 'ENF (Hz)');
    ylim(ax2, common_ylim); grid(ax2, 'on'); box(ax2, 'on');
    forged_verdict = threshold_verdict(row.r_forged, config.R_EER);
    text(ax2, 0.02, 0.90, sprintf('r = %.4f, %s', row.r_forged, forged_verdict), ...
        'Units', 'normalized', 'FontName', 'Arial', 'FontSize', 10, ...
        'BackgroundColor', 'w', 'Margin', 3);
    set([ax1 ax2], 'FontName', 'Arial', 'FontSize', 11, 'LineWidth', 1);
    linkaxes([ax1 ax2], 'x');
    save_svg_figure(fig, config.overlay_figure);
end

% Convert a correlation and threshold to its acceptance verdict.
function verdict = threshold_verdict(r_value, threshold)
    if r_value >= threshold, verdict = 'Accepted'; else, verdict = 'Rejected'; end
end

% Load and validate one mono WAV trace.
function trace = load_wav_trace(full_path, filename)
    info = audioinfo(full_path);
    waveform = audioread(full_path);
    if size(waveform,2) > 1, waveform = mean(waveform,2); end
    waveform = double(waveform(:));
    if isempty(waveform) || any(~isfinite(waveform)), error('Invalid WAV data: %s', full_path); end
    trace = struct('full_path', full_path, 'filename', filename, 'waveform', waveform, ...
        'source_fs', double(info.SampleRate), 'num_samples', numel(waveform));
    effective_analysis_fs(trace.source_fs);
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

% Extract reference and sensed ENF series with the shared processor.
function [enf_ref, enf_sensed] = extract_enf_pair(reference, reference_fs, sensed, sensed_fs, estimator, min_overlap_sec)
    [~, ~, ~, ~, enf_ref, enf_sensed] = proc_enf_analysis( ...
        reference, sensed, estimator.nfft, estimator.frame_size, estimator.overlap_size, ...
        estimator.reference_harmonics, estimator.nominal_freq, estimator.sensed_harmonics, ...
        estimator.nominal_freq, estimator.reference_method, estimator.reference_est_freq, ...
        estimator.reference_spec_comb_harmonics, estimator.sensed_method, ...
        estimator.sensed_est_freq, estimator.sensed_spec_comb_harmonics, ...
        'AC mains reference', 'Ambient EM sensed', false, ...
        'Fs1', reference_fs, 'Fs2', sensed_fs, 'LegacyNumericInputHandling', true, ...
        'Quiet', true, 'lagOptEnable', false, 'minOverlapSec', min_overlap_sec, 'lagLogPath', '');
    enf_ref = double(enf_ref(:));
    enf_sensed = double(enf_sensed(:));
    if isempty(enf_ref) || isempty(enf_sensed) || any(~isfinite(enf_ref)) || any(~isfinite(enf_sensed))
        error('ENF extraction produced empty or non-finite values.');
    end
end

% Calculate zero-lag Pearson correlation over the common ENF support.
function value = correlate_enf_lag_zero(enf_ref, enf_sensed)
    n = min(numel(enf_ref), numel(enf_sensed));
    if n < 2, value = NaN; return; end
    a = double(enf_ref(1:n)); b = double(enf_sensed(1:n));
    a = a(:) - mean(a); b = b(:) - mean(b);
    denominator = sqrt((a'*a) * (b'*b));
    if ~isfinite(denominator) || denominator <= 0, value = NaN; else, value = (a'*b)/denominator; end
end

% Load, resample, center, and optionally peak-normalize one trace.
function [x_out, fs_out] = af_load_mono_trace_resampled(path, target_fs, normalize_peak)
    if ~isfile(path), error('AF input file not found: %s', path); end
    [x, fs_in] = audioread(path);
    if isempty(x), error('AF input file is empty: %s', path); end
    if size(x,2) > 1, x = mean(x,2); else, x = x(:,1); end
    x = x(:);
    assert(all(isfinite(x)), 'Input waveform must be finite.');
    x = x - mean(x, 'omitnan'); x(~isfinite(x)) = 0;
    if fs_in == target_fs, x_out = x; else, x_out = resample(x, target_fs, fs_in); end
    x_out = x_out(:);
    if normalize_peak
        peak = max(abs(x_out));
        if isfinite(peak) && peak > 0, x_out = x_out / peak; end
    end
    fs_out = target_fs;
end

% Apply the ENF harmonic-suppression band-stop cascade.
function x_removed = af_apply_enf_bandstop_removal(x, fs, cfg)
    x_removed = x(:);
    for m = cfg.ATTACK_HARMONIC_MULTS(:).'
        [~, b_bs, valid] = af_design_paper_equiripple_filters(fs, m*cfg.NOMINAL_FREQ_HZ, cfg);
        if ~valid, error('Invalid attack band at harmonic %g.', m); end
        x_removed = af_apply_fir_single_pass_compensated(x_removed, b_bs);
    end
end

% Apply one compensated single-pass FIR filter.
function y = af_apply_fir_single_pass_compensated(x, b)
    x = x(:); b = b(:);
    if isempty(x) || isempty(b), y = x; return; end
    order = numel(b)-1;
    if mod(order,2) ~= 0, y = af_apply_fir_zero_phase(x,b); return; end
    delay = order/2;
    if numel(x) <= delay, y = zeros(size(x)); return; end
    delayed = filter(b,1,x);
    y = [delayed(delay+1:end); zeros(delay,1)];
end

% Generate the spectral noise-floor reconstruction components.
function [noise_fill, components] = af_generate_bandpassed_noise_fill(x_ref, n_samples, fs, cfg)
    x_ref = x_ref(:); noise_fill = zeros(n_samples,1);
    seed0 = round(af_get_cfg_numeric(cfg, 'NOISE_FILL_RANDOM_SEED', 42));
    stat_mode = char(cfg.NOISE_FILL_MATCH_STAT);
    mults = cfg.ATTACK_HARMONIC_MULTS(:).';
    components = cell(1, numel(mults));
    for ii = 1:numel(mults)
        center = mults(ii)*cfg.NOMINAL_FREQ_HZ;
        [b_bp,~,valid] = af_design_paper_equiripple_filters(fs,center,cfg);
        if ~valid, error('Invalid noise-fill band at %.1f Hz.', center); end
        rng(seed0 + 100 + ii, 'combRecursive');
        shaped = af_apply_fir_single_pass_compensated(randn(n_samples,1), b_bp);
        [p1,p2,s1,s2,ok] = af_get_noise_fill_band_edges(center,fs,cfg);
        if ~ok, error('Invalid noise-fill band edges at %.1f Hz.', center); end
        neighbor_bw = af_get_cfg_numeric(cfg,'NOISE_FILL_NEIGHBOR_BW_HZ',2*cfg.ENF_SUPPRESS_HALF_BW_HZ);
        neighbors = af_prune_invalid_bands([max(0,s1-neighbor_bw),s1; s2,min(fs/2,s2+neighbor_bw)]);
        target = af_fft_band_stat_abs(x_ref,fs,neighbors,stat_mode);
        source = af_fft_band_stat_abs(shaped,fs,[p1 p2],stat_mode);
        if isfinite(target) && isfinite(source) && source > 0, shaped = shaped*(target/source); end
        components{ii} = shaped(:);
        noise_fill = noise_fill + shaped(:);
    end
end

% Add spectral noise-floor reconstruction while enforcing the suppression floor.
function [suppressed, fill_scales] = af_add_noise_fill_with_suppression_floor( ...
        host, enf_suppressed, noise_components, fs, cfg, minimum_suppression_db)
    % Neighboring-band matching can exceed a weak authentic harmonic and undo
    % the required suppression floor. Preserve the configured noise fill when
    % possible, but cap each independent harmonic contribution so the combined
    % suppression and reconstruction trace remains safely below the host peak.
    % A 0.5 dB guard band prevents FFT leakage from causing borderline
    % validation failures after all seven components are added.
    guard_db = 0.5;
    design_suppression_db = minimum_suppression_db + guard_db;
    suppressed = enf_suppressed(:);
    mults = cfg.ATTACK_HARMONIC_MULTS(:).';
    fill_scales = ones(1, numel(mults));

    for ii = 1:numel(mults)
        center_hz = mults(ii) * cfg.NOMINAL_FREQ_HZ;
        host_peak = af_fft_local_peak_abs( ...
            host, fs, center_hz, cfg.HARMONIC_PEAK_MATCH_BW_HZ);
        peak_limit = host_peak * 10^(-design_suppression_db / 20);
        base_peak = af_fft_local_peak_abs( ...
            suppressed, fs, center_hz, cfg.HARMONIC_PEAK_MATCH_BW_HZ);
        if ~isfinite(host_peak) || host_peak <= 0 || ~isfinite(base_peak)
            error('Invalid noise-fill suppression-floor peak at %.1f Hz.', center_hz);
        end
        if base_peak > peak_limit
            error(['ENF harmonic suppression at %.1f Hz is only %.3f dB before spectral noise-floor reconstruction; ' ...
                'the %.1f dB guarded floor cannot be enforced by scaling the noise fill.'], ...
                center_hz, 20*log10(host_peak/max(base_peak,eps)), design_suppression_db);
        end

        component = noise_components{ii}(:);
        candidate_peak = af_fft_local_peak_abs( ...
            suppressed + component, fs, center_hz, cfg.HARMONIC_PEAK_MATCH_BW_HZ);
        if candidate_peak <= peak_limit
            suppressed = suppressed + component;
            continue;
        end

        lo = 0;
        hi = 1;
        for iteration = 1:32
            mid = 0.5 * (lo + hi);
            mid_peak = af_fft_local_peak_abs( ...
                suppressed + mid*component, fs, center_hz, cfg.HARMONIC_PEAK_MATCH_BW_HZ);
            if mid_peak <= peak_limit
                lo = mid;
            else
                hi = mid;
            end
        end
        fill_scales(ii) = lo;
        suppressed = suppressed + lo*component;
    end
end



% Inject synthetic ENF harmonics and match their spectral peaks.
function [forged, scales, target_peaks, final_peaks, errors] = ...
        af_joint_peak_match_all_harmonics( ...
        host, suppressed, components, fs, cfg, harmonic_mults)
    % Independent peak matching is insufficient because a finite-record FFT
    % leaks energy from every injected harmonic into the other local peak
    % bands.  Optimize each nonnegative harmonic scale against the spectrum
    % of the complete forged trace, cycling over all coordinates until the
    % final combined spectrum satisfies the configured requirements.
    host = host(:);
    suppressed = suppressed(:);
    harmonic_count = numel(components);
    harmonic_mults = harmonic_mults(:).';
    if numel(harmonic_mults) ~= harmonic_count
        error('Injected harmonic multipliers and components must have equal lengths.');
    end
    n = numel(host);
    positive_count = floor(n/2) + 1;
    frequency = (0:positive_count-1).' * fs / n;
    host_fft = fft(host);
    suppressed_fft = fft(suppressed);
    host_fft = host_fft(1:positive_count);
    suppressed_fft = suppressed_fft(1:positive_count);
    component_fft = complex(zeros(positive_count, harmonic_count));
    for h = 1:harmonic_count
        component = components{h}(:);
        if numel(component) ~= n
            error('Synthetic harmonic component %d has an invalid length.', h);
        end
        spectrum = fft(component);
        component_fft(:,h) = spectrum(1:positive_count);
    end

    band_masks = cell(1, harmonic_count);
    target_peaks = nan(1, harmonic_count);
    for h = 1:harmonic_count
        center_hz = harmonic_mults(h) * cfg.NOMINAL_FREQ_HZ;
        mask = frequency >= center_hz-cfg.HARMONIC_PEAK_MATCH_BW_HZ & ...
            frequency <= center_hz+cfg.HARMONIC_PEAK_MATCH_BW_HZ;
        if ~any(mask), error('No FFT bins found for the %.1f Hz peak-match band.', center_hz); end
        band_masks{h} = mask;
        target_peaks(h) = max(abs(host_fft(mask)));
    end

    scales = zeros(1, harmonic_count);
    best_scales = scales;
    tolerances = cfg.PEAK_MATCH_TOL_HARM * ones(1, harmonic_count);
    tolerances(harmonic_mults == 1) = cfg.PEAK_MATCH_TOL_FUND;
    best_tolerance_ratio = inf;
    max_sweeps = 30;
    for sweep = 1:max_sweeps
        combined_fft = suppressed_fft + component_fft * scales(:);
        if mod(sweep,2) == 1
            harmonic_order = 1:harmonic_count;
        else
            harmonic_order = harmonic_count:-1:1;
        end
        for h = harmonic_order
            mask = band_masks{h};
            base_without_h = combined_fft - scales(h)*component_fft(:,h);
            new_scale = af_optimize_peak_scale_from_spectra( ...
                target_peaks(h), base_without_h(mask), component_fft(mask,h), scales(h));
            combined_fft = base_without_h + new_scale*component_fft(:,h);
            scales(h) = new_scale;
        end

        final_peaks = nan(1, harmonic_count);
        for h = 1:harmonic_count
            final_peaks(h) = max(abs(combined_fft(band_masks{h})));
        end
        errors = abs(final_peaks-target_peaks) ./ max(target_peaks,eps);
        current_tolerance_ratio = max(errors ./ tolerances);
        if current_tolerance_ratio < best_tolerance_ratio
            best_tolerance_ratio = current_tolerance_ratio;
            best_scales = scales;
        end
        if all(errors <= 0.9*tolerances)
            break;
        end
    end

    scales = best_scales;
    forged = suppressed;
    for h = 1:harmonic_count
        forged = forged + scales(h)*components{h}(:);
    end
    final_peaks = nan(1, harmonic_count);
    for h = 1:harmonic_count
        center_hz = harmonic_mults(h) * cfg.NOMINAL_FREQ_HZ;
        final_peaks(h) = af_fft_local_peak_abs( ...
            forged, fs, center_hz, cfg.HARMONIC_PEAK_MATCH_BW_HZ);
    end
    errors = abs(final_peaks-target_peaks) ./ max(target_peaks,eps);
end

% Return the per-harmonic peak-matching tolerances.
function tol = peak_match_tolerances(cfg)
    tol = cfg.PEAK_MATCH_TOL_HARM * ones(1, numel(cfg.ATTACK_HARMONIC_MULTS));
    tol(cfg.ATTACK_HARMONIC_MULTS == 1) = cfg.PEAK_MATCH_TOL_FUND;
end

% Optimize one harmonic scale against the host spectrum.
function scale = af_optimize_peak_scale_from_spectra( ...
        target_peak, base_spectrum, component_spectrum, initial_scale)
    component_max = max(abs(component_spectrum));
    if ~isfinite(component_max) || component_max <= 0
        scale = 0;
        return;
    end
    upper = max([1, 2*max(initial_scale,0), 4*target_peak/component_max]);
    grid_count = 257;
    for expansion = 1:10
        candidates = linspace(0, upper, grid_count);
        candidate_spectra = bsxfun(@plus, base_spectrum, component_spectrum*candidates);
        candidate_peaks = max(abs(candidate_spectra), [], 1);
        candidate_errors = abs(candidate_peaks-target_peak);
        [~, best_index] = min(candidate_errors);
        if best_index < grid_count
            break;
        end
        upper = 2*upper;
    end
    left_index = max(1, best_index-1);
    right_index = min(grid_count, best_index+1);
    left = candidates(left_index);
    right = candidates(right_index);
    if right <= left
        scale = candidates(best_index);
        return;
    end
    objective = @(value) abs(max(abs(base_spectrum + value*component_spectrum))-target_peak);
    options = optimset('Display','off','TolX',1e-10);
    [refined_scale, refined_error] = fminbnd(objective, left, right, options);
    grid_error = candidate_errors(best_index);
    if isfinite(refined_error) && refined_error <= grid_error
        scale = max(0, refined_scale);
    else
        scale = candidates(best_index);
    end
end

% Measure the local absolute FFT peak around one harmonic.
function peak = af_fft_local_peak_abs(x, fs, center, half_bw)
    [f,mag] = af_fft_mag_abs_no_dc(x,fs);
    mask = f >= center-half_bw & f <= center+half_bw;
    if any(mask), peak = max(mag(mask)); else, [~,i] = min(abs(f-center)); peak = mag(i); end
end

% Summarize FFT magnitude across one or more frequency bands.
function value = af_fft_band_stat_abs(x,fs,bands,mode)
    [f,mag] = af_fft_mag_abs_no_dc(x,fs); mask = false(size(f));
    for k = 1:size(bands,1), mask = mask | (f>=bands(k,1) & f<=bands(k,2)); end
    values = mag(mask); values = values(isfinite(values));
    if isempty(values), value = NaN; else, value = af_summarize_values(values,mode); end
end

% Remove invalid frequency bands before spectral measurement.
function bands = af_prune_invalid_bands(input_bands)
    valid = isfinite(input_bands(:,1)) & isfinite(input_bands(:,2)) & input_bands(:,2)>input_bands(:,1);
    bands = input_bands(valid,:);
end

% Calculate the noise-fill passband and stopband edges for one harmonic.
function [p1,p2,s1,s2,ok] = af_get_noise_fill_band_edges(center,fs,cfg)
    p1=center-cfg.ENF_SUPPRESS_HALF_BW_HZ; p2=center+cfg.ENF_SUPPRESS_HALF_BW_HZ;
    s1=p1-cfg.ENF_SUPPRESS_TRANSITION_BW_HZ; s2=p2+cfg.ENF_SUPPRESS_TRANSITION_BW_HZ;
    ok=isfinite(p1)&&isfinite(p2)&&isfinite(s1)&&isfinite(s2)&&s1>0&&s2<fs/2&&s1<p1&&p2<s2;
end

% Generate the deterministic synthetic ENF modulation component.
function synthetic = af_generate_syn_enf_component(n_samples,fs,cfg)
    seed = round(af_get_cfg_numeric(cfg,'SYNTH_ENF_RANDOM_SEED',cfg.SYNTH_ENF_BASE_SEED));
    rng(seed, 'combRecursive');
    t=(0:n_samples-1).'/fs; delta=zeros(n_samples,1);
    freqs=cfg.SYNTH_ENF_MOD_FREQS_HZ(:); amps=cfg.SYNTH_ENF_MOD_AMPS_HZ(:);
    for k=1:min(numel(freqs),numel(amps))
        delta=delta+amps(k)*sin(2*pi*freqs(k)*t+2*pi*rand());
    end
    drift=conv(randn(n_samples,1),ones(max(5,round(2*fs)),1)/max(5,round(2*fs)),'same');
    drift=drift/max(std(drift,1,'omitnan'),eps); delta=delta+0.02*drift;
    delta=cfg.SYNTH_ENF_MAX_DEV_HZ*delta/max(max(abs(delta)),eps);
    fundamental=cfg.NOMINAL_FREQ_HZ+delta; synthetic=zeros(n_samples,1);
    for m=cfg.ATTACK_HARMONIC_MULTS(:).'
        phase=2*pi*cumsum(m*fundamental)/fs+2*pi*rand();
        component=sin(phase);
        [b_bp,~,valid]=af_design_paper_equiripple_filters(fs,m*cfg.NOMINAL_FREQ_HZ,cfg);
        if ~valid, error('Invalid synthesis band at harmonic %g.',m); end
        synthetic=synthetic+af_apply_fir_single_pass_compensated(component,b_bp);
    end
    synthetic=detrend(synthetic-mean(synthetic,'omitnan'));
end


% Design the paper's equiripple band-pass and band-stop filters.
function [b_bp,b_bs,valid] = af_design_paper_equiripple_filters(fs,center,cfg)
    nyq=fs/2; p1=center-cfg.ENF_SUPPRESS_HALF_BW_HZ; p2=center+cfg.ENF_SUPPRESS_HALF_BW_HZ;
    s1=p1-cfg.ENF_SUPPRESS_TRANSITION_BW_HZ; s2=p2+cfg.ENF_SUPPRESS_TRANSITION_BW_HZ;
    valid=s1>0&&s2<nyq&&s1<p1&&p2<s2;
    if ~valid, b_bp=[]; b_bs=[]; return; end
    edges=[0 s1 p1 p2 s2 nyq]/nyq; order=cfg.ENF_SUPPRESS_FIR_ORDER; weights=cfg.ENF_SUPPRESS_FIR_WEIGHTS;
    if ismember(exist('firpm','file'), [2 3 5 6])
        b_bp=firpm(order,edges,[0 0 1 1 0 0],weights);
        b_bs=firpm(order,edges,[1 1 0 0 1 1],weights);
    elseif ismember(exist('remez','file'), [2 3 5 6])
        b_bp=remez(order,edges,[0 0 1 1 0 0],weights);
        b_bs=remez(order,edges,[1 1 0 0 1 1],weights);
    else
        b_bp=af_design_bandpass_fir_windowed_sinc(order,fs,p1,p2);
        b_bs=af_spectral_invert_fir(b_bp);
    end
end

% Apply zero-phase FIR filtering to one signal.
function y=af_apply_fir_zero_phase(x,b)
    if exist('filtfilt','file')==2 && numel(x)>3*(numel(b)-1)
        y=filtfilt(b,1,x);
    else
        y=flipud(filter(b,1,flipud(filter(b,1,x(:)))));
    end
end

% Design a windowed-sinc band-pass FIR filter.
function b=af_design_bandpass_fir_windowed_sinc(order,fs,f1,f2)
    if mod(order,2)~=0, order=order+1; end
    n=(0:order).'; k=n-order/2; fc1=f1/fs; fc2=f2/fs;
    b=(2*fc2*af_sincn(2*fc2*k)-2*fc1*af_sincn(2*fc1*k)).*(0.54-0.46*cos(2*pi*n/order));
    center=(f1+f2)/2; gain=abs(sum(b(:).'.*exp(-1j*2*pi*(center/fs)*(0:order))));
    if gain>0, b=b/gain; end
    b=b(:).';
end

% Convert a band-pass FIR filter to its spectral inverse.
function b=af_spectral_invert_fir(bp)
    b=-bp(:).'; b(floor(numel(b)/2)+1)=b(floor(numel(b)/2)+1)+1;
end

% Evaluate the normalized sinc function.
function y=af_sincn(x)
    y=ones(size(x)); mask=abs(x)>eps; y(mask)=sin(pi*x(mask))./(pi*x(mask));
end

% Calculate the one-sided absolute FFT magnitude without DC.
function [f,mag]=af_fft_mag_abs_no_dc(x,fs)
    x=double(x(:)); n=numel(x); spectrum=fft(x);
    count=floor(n/2)+1; mag=abs(spectrum(1:count)); f=(0:count-1).'*fs/n;
    if ~isempty(f) && f(1)==0, f=f(2:end); mag=mag(2:end); end
end

% Summarize values with the configured statistic.
function value=af_summarize_values(values,mode)
    if strcmpi(mode,'mean'), value=mean(values); else, value=median(values); end
end

% Read an optional numeric configuration value with a default.
function value=af_get_cfg_numeric(cfg,name,default_value)
    value=default_value;
    if isfield(cfg,name) && isnumeric(cfg.(name)) && isscalar(cfg.(name)) && isfinite(cfg.(name))
        value=double(cfg.(name));
    end
end



% Apply the bounded Fisher-z transformation.
function z=fisher_z(r,clip_value)
    r=max(-clip_value,min(clip_value,double(r)));
    z=atanh(r);
end

% Export a figure to the configured SVG path.
function save_svg_figure(fig,path)
    set(fig,'PaperPositionMode','auto'); print(fig,path,'-dsvg');
    print(fig,strrep(path,'.svg','.png'),'-dpng','-r150');
    savefig(fig,strrep(path,'.svg','.fig')); close(fig);
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID,varargin)
    message=sprintf(varargin{:});
    fprintf(1,'%s',message); fprintf(fileID,'%s',message);
end

% Format numeric values for configuration logging.
function text_value=format_numeric_list(values)
    text_value=strtrim(sprintf('%.6g ',values));
end

% Convert a Boolean value to a yes/no label.
function value=yes_no(tf)
    if tf, value='yes'; else, value='no'; end
end


