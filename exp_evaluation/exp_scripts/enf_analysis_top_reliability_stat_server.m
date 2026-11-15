%% ENF Server-Room Robustness
% Purpose:
%   Evaluate ENF-recovery robustness across the existing server-room sensor
%   positions and recording days.
%
% Experiment:
%   Main paper Section 6.2; 20 recording pairs at the SBOX and SPSU positions
%   on MON and WED, with five trials per condition.
%
% Analysis:
%   Extract Pearson correlations, apply the Fisher-z transformation, perform
%   repeated-measures analyses, and generate the publication figure.
%
% Inputs:
%   exp_evaluation/exp_inputs/SRV_L; 20 pairs across two positions and two
%   days, with five trials per condition.
%
% Outputs:
%   A combined PNG/SVG/FIG under
%   exp_evaluation/exp_results/srv_room_robustness and the script log under
%   exp_evaluation/exp_logs.
%
% Dependencies:
%   Shared exp_validation/exp_scripts/proc_enf_analysis.p; Signal Processing
%   and Statistics toolboxes.
%
% Usage:
%   Run from any working directory; edit only the centralized configuration
%   for a new experiment.


%% STEP_1) Script Configuration
% Set repository paths, fixed experiment inventory, and ENF settings.
config = struct();
standardization_timer = tic;

% Repository and Output Paths
script_dir = fileparts(mfilename('fullpath'));
evaluation_root = fileparts(script_dir);
repository_root = fileparts(evaluation_root);
config.baseDir = fullfile(evaluation_root, 'exp_inputs', 'SRV_L');
config.shared_dir = fullfile(repository_root, 'exp_validation', 'exp_scripts');
config.results_dir = fullfile(evaluation_root, 'exp_results', 'srv_room_robustness');
config.log_dir = fullfile(evaluation_root, 'exp_logs');

% Experimental Conditions
config.sites = {'SBOX','SPSU'};
config.days = {'MON','WED'};
config.trials = {'T01','T02','T03','T04','T05'};

% ENF Extraction Parameters
config.nominal_freq = 60;
config.harmonics = 60:60:420;
config.frame_size = 8000; % samples, not milliseconds
config.overlap_size = 0;
config.nfft = 32768;

%% STEP_2) Setup: Logging and Output Directories
% Resolve the shared processor and initialize output directories and log cleanup.

% Protected MATLAB Analysis Dependency
assert(isfile(fullfile(config.shared_dir, 'proc_enf_analysis.p')), ...
    'Shared processor is missing from exp_validation/exp_scripts.');
addpath(config.shared_dir, '-begin');
assert(strcmp(which('proc_enf_analysis'), fullfile(config.shared_dir, 'proc_enf_analysis.p')), ...
    'MATLAB resolved a different shared ENF processor.');

% Output Directories
if ~isfolder(config.log_dir), mkdir(config.log_dir); end
if ~isfolder(config.results_dir), mkdir(config.results_dir); end

% Logging Setup
[~, script_name] = fileparts(mfilename('fullpath'));
log_filename = fullfile(config.log_dir, [script_name '_log.txt']);
fileID = fopen(log_filename, 'w');
assert(fileID >= 0, 'Cannot open server-room robustness log.');
cleanupObj = onCleanup(@() fclose(fileID));
log_both(fileID, '%s\nENF SERVER-ROOM ROBUSTNESS\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
log_both(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));

%% STEP_3) Input Discovery and Validation
% Validate required recordings and preserve documented duration exceptions.
try
    log_both(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    [results_tbl, short_duration] = build_inventory(config);
    log_both(fileID, '\nExperiment design:\n    Sites: SBOX, SPSU\n    Days: MON, WED\n    Trials: T01-T05\n');
    log_both(fileID, '    Expected configurations: 4; five trials each.\n    Expected pairs: 20\n    Found pairs: %d\n', height(results_tbl));
    log_both(fileID, '    Input dataset: exp_evaluation/exp_inputs/SRV_L/\n');
    log_both(fileID, '    SBOX: middle of chassis near processor; SPSU: near power supply.\n');
    log_both(fileID, '    WAVs: mono, 44100 Hz, nominally 200 s.\n');
    log_both(fileID, '    Duration tolerance: one source sample; the reference below has an accepted 0.05-s shortfall tolerance.\n');
    log_both(fileID, '    SPSU/MON/T05/mains_pow_trace_ac.wav: %.9f s; allowed shortfall <=0.05 s.\n', short_duration);
    log_both(fileID, '\nENF configuration:\n    Nominal frequency: 60 Hz\n    Method: weighted-energy (1), gamma=3\n');
    log_both(fileID, '    Harmonics: %s\n    Frame: %d samples\n    Overlap: %d samples\n    FFT setting: %d\n', ...
        mat2str(config.harmonics), config.frame_size, config.overlap_size, config.nfft);
    log_both(fileID, '    Comparison: zero-lag Pearson r; LagOptEnable=false; Quiet=true; plotting=false.\n');
    log_both(fileID, '    Preprocessing: factor=3; 44100-to-1050 Hz decimation.\n');
    log_both(fileID, '    Method 1 FFT resolution: 0.03 Hz.\n');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_4) ENF Extraction and Processing
% Extract the existing zero-lag ENF correlation for every required pair.
try
    log_both(fileID, '\nSTEP_4) ENF EXTRACTION AND PROCESSING\n%s\n', repmat('%',1,85));
    for index = 1:height(results_tbl)
        folder = fullfile(config.baseDir, results_tbl.Site(index), results_tbl.Day(index), results_tbl.Trial(index));
        key = sprintf('%s/%s/%s', results_tbl.Site(index), results_tbl.Day(index), results_tbl.Trial(index));
        try
            r = proc_enf_analysis(string(fullfile(folder, 'mains_pow_trace_ac.wav')), ...
                string(fullfile(folder, 'fpga_em_trace_dc.wav')), ...
                config.nfft, config.frame_size, config.overlap_size, ...
                config.harmonics, config.nominal_freq, config.harmonics, config.nominal_freq, ...
                1, config.nominal_freq, config.harmonics, 1, config.nominal_freq, config.harmonics, ...
                'AC mains reference', 'Ambient EM sensed', false, 'LagOptEnable', false, 'Quiet', true);
        catch processing_error
            error('ServerRobustness:ProcessingFailed', 'Processing failed for %s: %s', key, processing_error.message);
        end
        assert(isscalar(r) && isfinite(r) && abs(r) <= 1, 'Invalid Pearson correlation for %s.', key);
        results_tbl.Correlation(index) = r;
    end
    assert(height(results_tbl) == 20 && all(isfinite(results_tbl.Correlation)), 'Require exactly 20 finite correlations.');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_5) Statistical Analysis
% Retain descriptive statistics, Fisher transforms, and experiment-specific hypothesis tests.
try
    log_both(fileID, '\nSTEP_5) STATISTICAL ANALYSIS\n%s\n', repmat('%',1,85));
    [r_stats, z_data, z_stats] = calculate_basic_stats(results_tbl.Correlation);
    log_both(fileID, '\n    Processed pairs: %d\n', height(results_tbl));
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (r)\n');
    print_stats_table(r_stats, 'All Correlations (r)', fileID);
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (Fisher z)\n');
    print_stats_table(z_stats, 'All Correlations (z'')', fileID);
    log_both(fileID, '%-22s | %20.6f\n', 'Mean (r from z-mean)', tanh(z_stats.mean));
    ci_r = tanh(z_stats.mean + [-1 1] * z_stats.ci95_margin);
    log_both(fileID, '%-22s | [%.6f, %.6f]\n', '95% CI (r from z)', ci_r(1), ci_r(2));
    log_both(fileID, 'Fisher transform: atanh(r); exact limits use +/-0.9999999.\n');

    log_both(fileID, '\n\nInferential tests (within-trial repeated measures)\n');
    out_day = run_rm_anova(results_tbl, 'Day', config.days, fileID);
    out_site = run_rm_anova(results_tbl, 'Site', config.sites, fileID);
    log_both(fileID, '\nSignificance summary: alpha = 0.05; unadjusted tests, no multiple-test correction.\n');
    for output = {out_day, out_site}
        test = output{1};
        if test.p_raw < 0.05, decision = 'SIGNIFICANT'; else, decision = 'not significant'; end
        log_both(fileID, '    %s: p=%.6f -> %s\n', test.factor, test.p_raw, decision);
    end
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_6) Results and Figures
% Generate the two-panel day-of-week and sensor-position publication figure.
try
    log_both(fileID, '\nSTEP_6) RESULTS AND FIGURES\n%s\n', repmat('%',1,85));
    plot_combined_inferential(out_day, out_site, config.results_dir);
    log_both(fileID, '\nFIGURE GENERATION\n    Combined figure saved successfully.\n    Y-axis: [0.987, 0.999]\n');
    log_both(fileID, '    exp_evaluation/exp_results/srv_room_robustness/inferential_dotwhisker_combined.{png,svg,fig}\n');
    for output = {out_day, out_site}
        test = output{1};
        for index = 1:numel(test.levels)
            if test.ci_lo_r(index) < 0.987 || test.ci_hi_r(index) > 0.999
                log_both(fileID, '    CI CLIPPING: %s/%s computed CI [%.9f, %.9f] extends beyond the fixed axis.\n', ...
                    test.factor, test.levels{index}, test.ci_lo_r(index), test.ci_hi_r(index));
            end
        end
    end
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_7) Final Summary and Logging
% Report completion after successful processing, statistical analysis, and output generation.
try
    log_both(fileID, '\nSTEP_7) FINAL SUMMARY AND LOGGING\n%s\n', repmat('%',1,85));
    log_both(fileID, 'Execution status: SUCCESS\nTotal execution time: %.3f s\n', toc(standardization_timer));
    clear cleanupObj;
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% Local Functions
% Build and validate the fixed 20-pair server-room recording inventory.
function [tbl, short_duration] = build_inventory(config)
    site = strings(20,1); day = site; trial = site; index = 0;
    for s = 1:2
        for d = 1:2
            for k = 1:5
                index = index + 1;
                site(index) = config.sites{s}; day(index) = config.days{d}; trial(index) = config.trials{k};
            end
        end
    end
    tbl = table(site, day, trial, nan(20,1), 'VariableNames', {'Site','Day','Trial','Correlation'});
    assert(height(unique(tbl(:,1:3))) == 20, 'Duplicate expected server-room configurations.');
    expected_paths = strings(40,1);
    short_duration = NaN;
    for index = 1:20
        for channel = 1:2
            names = {'mains_pow_trace_ac.wav','fpga_em_trace_dc.wav'};
            relative = fullfile(tbl.Site(index), tbl.Day(index), tbl.Trial(index), names{channel});
            path = fullfile(config.baseDir, relative);
            assert(isfile(path), 'Missing required server-room input: %s.', relative);
            info = audioinfo(path);
            assert(info.NumChannels == 1 && info.SampleRate == 44100, ...
                'Expected mono 44100 Hz server-room input: %s.', relative);
            tolerance = 1/info.SampleRate;
            is_short_reference = tbl.Site(index) == "SPSU" && tbl.Day(index) == "MON" && ...
                tbl.Trial(index) == "T05" && channel == 1;
            if is_short_reference
                % This reference is 1968 samples shorter than the nominal 200 seconds.
                tolerance = 0.05;
                short_duration = info.Duration;
                assert(info.Duration <= 200 + 1/info.SampleRate, 'Unexpected excess duration: %s.', relative);
            end
            assert(abs(info.Duration-200) <= tolerance, 'Invalid nominal 200 s duration: %s (%.9f s).', relative, info.Duration);
            expected_paths(2*(index-1)+channel) = string(path);
        end
    end
    % Fixed inventory selects inputs; a secondary scan rejects alternate paths.
    found = dir(fullfile(config.baseDir, '**', '*.wav'));
    found_paths = strings(numel(found),1);
    for index = 1:numel(found)
        found_paths(index) = string(fullfile(found(index).folder, found(index).name));
    end
    assert(numel(found_paths) == 40 && isequal(sort(found_paths), sort(expected_paths)), ...
        'SRV_L has missing, duplicate, or unexpected WAV paths; require the exact 20-pair inventory.');
    assert(isfinite(short_duration), 'Missing metadata for the known short reference.');
end

% Run a repeated-measures ANOVA and report its estimates and test statistics.
function out = run_rm_anova(tbl, factorName, levels, fileID)
    % Preserve the original inference clipping and mean-z aggregation.
    T = tbl;
    T.z = atanh(max(min(T.Correlation, 0.9999999), -0.9999999));
    S = groupsummary(T, {'Trial',factorName}, 'mean', 'z');
    assert(height(S) == 10 && all(S.GroupCount == 2), ...
        'Require two observations in every Trial x %s mean.', factorName);
    W = unstack(S, 'mean_z', factorName, 'GroupingVariables', 'Trial');
    assert(all(ismember(levels, W.Properties.VariableNames)), 'Missing factor levels for %s.', factorName);
    Y = W{:,levels};
    assert(height(W) == 5 && isequal(sort(string(W.Trial)), ["T01";"T02";"T03";"T04";"T05"]) && all(isfinite(Y(:))), ...
        'Require five complete trial subjects for %s; no observations may be dropped.', factorName);
    tY = array2table(Y, 'VariableNames', levels);
    within = table(categorical(levels'), 'VariableNames', {factorName});
    rm = fitrm(tY, sprintf('%s-%s ~ 1', levels{1}, levels{end}), 'WithinDesign', within);
    ran = ranova(rm, 'WithinModel', factorName);
    rn = string(ran.Properties.RowNames);
    idx = find(rn == "(Intercept):" + string(factorName), 1);
    errIdx = find(rn == "Error(" + string(factorName) + ")", 1);
    assert(~isempty(idx) && ~isempty(errIdx), 'Missing ANOVA factor/error row for %s.', factorName);
    out = level_estimates(Y, levels);
    out.factor = factorName;
    out.F = ran.F(idx); out.df1 = ran.DF(idx); out.df2 = ran.DF(errIdx);
    out.p_raw = ran.pValue(idx);
    out.p_GG = out.p_raw;
    if ismember('pValueGG', ran.Properties.VariableNames) && isfinite(ran.pValueGG(idx))
        out.p_GG = ran.pValueGG(idx);
    end
    out.eta_p2 = ran.SumSq(idx)/(ran.SumSq(idx)+ran.SumSq(errIdx));
    assert(out.df1 == 1 && out.df2 == 4 && all(isfinite([out.F out.p_raw out.p_GG out.eta_p2])), ...
        'Invalid two-level RM-ANOVA for %s.', factorName);
    log_both(fileID, '\n[%s] Repeated-Measures ANOVA (subjects = Trial)\n', factorName);
    log_both(fileID, '    Complete subjects: %d; two-level sphericity is automatic.\n', out.n);
    log_both(fileID, '    RM-ANOVA Summary (%s)\n', factorName);
    log_both(fileID, '    %-10s | %4s | %4s | %12s | %12s | %12s | %12s\n', 'Effect','df1','df2','F','p','p(GG)','eta_p^2');
    log_both(fileID, '    %-10s | %4d | %4d | %12.6f | %12.6f | %12.6f | %12.6f\n', ...
        factorName, out.df1, out.df2, out.F, out.p_raw, out.p_GG, out.eta_p2);
    print_level_estimates(out, fileID);
end

% Generate the two-panel day-of-week and sensor-position figure.
function plot_combined_inferential(out_day, out_site, results_dir)
    fig = figure('Name','Inferential_DotWhisker_Combined','Visible','off','Position',[100,100,900,420]);
    violet_main = [63 81 181]/255;
    violet_dark = [26 35 126]/255;
    ax1 = subplot(1,2,1);
    draw_dotwhisker_on_ax(ax1, out_day.mu_r, out_day.ci_lo_r, out_day.ci_hi_r, ...
        out_day.levels, 'Day-of-week', true, violet_main, violet_dark);
    ax2 = subplot(1,2,2);
    draw_dotwhisker_on_ax(ax2, out_site.mu_r, out_site.ci_lo_r, out_site.ci_hi_r, ...
        out_site.levels, 'Sensor position', true, violet_main, violet_dark);
    fn = fullfile(results_dir, 'inferential_dotwhisker_combined');
    saveas(fig, [fn '.png']); saveas(fig, [fn '.svg']); savefig(fig, [fn '.fig']);
    close(fig);
end

% Print one descriptive-statistics table to the terminal and log.
function print_stats_table(stats, label, fileID)
    log_both(fileID, '%-22s | %20s\n', 'Statistic', label);
    log_both(fileID, '%-22s | %20d\n', 'Count (N)', stats.N);
    labels = {'Mean','Median','Std. Dev.','Variance','Skewness','Kurtosis','Std. Error'};
    fields = {'mean','median','std','var','skew','kurt','sem'};
    for index = 1:numel(fields)
        log_both(fileID, '%-22s | %20.6f\n', labels{index}, stats.(fields{index}));
    end
    log_both(fileID, '%-22s | [%.6f, %.6f]\n', '95% CI', ...
        stats.mean-stats.ci95_margin, stats.mean+stats.ci95_margin);
    log_both(fileID, '%-22s | %20.6f\n', 'Min', stats.min);
    log_both(fileID, '%-22s | %20.6f\n', 'Max', stats.max);
end

% Compute Fisher-z level means and back-transformed confidence intervals.
function out = level_estimates(Y, levels)
    % Retain condition-level t confidence intervals in z, then back-transform.
    nSubj = size(Y,1);
    mu_z = mean(Y,1);
    sd_z = std(Y,0,1);
    se_z = sd_z ./ sqrt(nSubj);
    tcrit = tinv(0.975, nSubj-1);
    out = struct('n',nSubj,'levels',{levels},'mu_z',mu_z,'mu_r',tanh(mu_z), ...
        'ci_lo_r',tanh(mu_z-tcrit.*se_z),'ci_hi_r',tanh(mu_z+tcrit.*se_z));
end

% Report level means and confidence intervals on the z and r scales.
function print_level_estimates(out, fileID)
    log_both(fileID, '    Level means (z): ');
    for index = 1:numel(out.levels)
        log_both(fileID, '%s=%.6f ', out.levels{index}, out.mu_z(index));
    end
    log_both(fileID, '\n    Level means (r from z): ');
    for index = 1:numel(out.levels)
        log_both(fileID, '%s=%.6f ', out.levels{index}, out.mu_r(index));
    end
    log_both(fileID, '\n    Level 95%% CI (r from z): ');
    for index = 1:numel(out.levels)
        log_both(fileID, '%s=[%.6f, %.6f] ', out.levels{index}, out.ci_lo_r(index), out.ci_hi_r(index));
    end
    log_both(fileID, '\n');
end

% Calculate descriptive statistics on the correlation and Fisher-z scales.
function [r_stats, z_data, z_stats] = calculate_basic_stats(all_r)
    r_stats = sub_calc_stats(all_r);
    r_safe = all_r;
    r_safe(r_safe >=  1) = 0.9999999;
    r_safe(r_safe <= -1) = -0.9999999;
    z_data  = atanh(r_safe);
    z_stats = sub_calc_stats(z_data);
end

% Calculate the descriptive statistics and confidence interval for one vector.
function stats = sub_calc_stats(x)
    if ~isempty(x)
        stats.N      = numel(x);
        stats.mean   = mean(x);
        stats.median = median(x);
        stats.std    = std(x);
        stats.min    = min(x);
        stats.max    = max(x);
        stats.var    = var(x);
        stats.skew   = skewness(x);
        stats.kurt   = kurtosis(x);
        stats.sem    = stats.std / sqrt(stats.N);
        df = max(stats.N - 1, 1);
        tcrit = tinv(0.975, df);
        stats.ci95_margin = tcrit * stats.sem;
    else
        stats = struct('N',0,'mean',NaN,'median',NaN,'std',NaN,'min',NaN,'max',NaN, ...
                       'var',NaN,'skew',NaN,'kurt',NaN,'sem',NaN,'ci95_margin',NaN);
    end
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID, varargin)
    message = sprintf(varargin{:});
    fprintf(1, '%s', message);
    fprintf(fileID, '%s', message);
end

% Draw one dot-and-whisker panel with fixed styling and correlation limits.
function draw_dotwhisker_on_ax(ax, mu_r, ci_lo_r, ci_hi_r, levels, title_str, showYLabel, ...
                               violet_main, violet_dark)
    axes(ax);
    hold(ax,'on');

    mu_r    = mu_r(:)';
    ci_lo_r = ci_lo_r(:)';
    ci_hi_r = ci_hi_r(:)';
    K       = numel(mu_r);
    x       = 1:K;

    whiskerColor = violet_main;
    dotFaceColor = violet_dark;
    dotEdgeColor = [1 1 1];

    for i = 1:K
        % Vertical confidence-interval line.
        line(ax, [x(i) x(i)], [ci_lo_r(i) ci_hi_r(i)], ...
            'Color', whiskerColor, ...
            'LineWidth', 2.0);
        % Mean dot.
        plot(ax, x(i), mu_r(i), 'o', ...
            'MarkerSize', 7, ...
            'MarkerFaceColor', dotFaceColor, ...
            'MarkerEdgeColor', dotEdgeColor, ...
            'LineWidth', 1.2);
    end

    if K > 1
        plot(ax, x, mu_r, '-', ...
            'Color', whiskerColor, ...
            'LineWidth', 1.0);
    end

    set(ax, 'XLim', [0.5 K+0.5], ...
            'XTick', x, ...
            'XTickLabel', levels, ...
            'FontName', 'Times', ...
            'FontSize', 9, ...
            'Box', 'off', ...
            'Layer', 'top', ...
            'YGrid', 'on', ...
            'GridColor', [0.90 0.91 0.97], ...
            'GridAlpha', 0.9, ...
            'LineWidth', 0.8);

    if showYLabel
        ylabel(ax, 'Pearson r', 'FontSize', 9);
    else
        ylabel(ax, '');
    end

    % Use the same fixed correlation scale for both panels.
    ylim(ax, [0.987 0.999]);
    set(ax, 'YTick', [0.987 0.989 0.991 0.993 0.995 0.997 0.999]);
    ytickformat(ax, '%.3f');

    title(ax, title_str, 'FontWeight','normal', 'FontSize',10);
    hold(ax,'off');
end
