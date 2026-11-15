%% ENF Temporal Reliability
% Purpose:
%   Evaluate temporal stability of ambient-EM ENF recovery across the fixed
%   week, day, and time-of-day inventory.
%
% Experiment:
%   Main paper Section 6.1; 160 recording pairs across two weeks, four days,
%   four times of day, and five trials per condition.
%
% Analysis:
%   Extract Pearson correlations, apply the Fisher-z transformation, perform
%   repeated-measures analyses, and generate the publication figure.
%
% Inputs:
%   exp_evaluation/exp_inputs/TREND; 160 pairs across 32 conditions with five
%   trials per condition.
%
% Outputs:
%   A combined PNG/SVG/FIG under
%   exp_evaluation/exp_results/enf_temporal_reliability and the script log
%   under exp_evaluation/exp_logs.
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
config.baseDir = fullfile(evaluation_root, 'exp_inputs', 'TREND');
config.shared_dir = fullfile(repository_root, 'exp_validation', 'exp_scripts');
config.results_dir = fullfile(evaluation_root, 'exp_results', 'enf_temporal_reliability');
config.log_dir = fullfile(evaluation_root, 'exp_logs');

% Experimental Conditions
config.weeks = {'WK01','WK02'};
config.days = {'WED','THU','SAT','SUN'};
config.times = {'EMRN','MORN','AFTN','EVEN'};
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
assert(fileID >= 0, 'Cannot open temporal reliability log.');
cleanupObj = onCleanup(@() fclose(fileID));
log_both(fileID, '%s\nENF TEMPORAL RELIABILITY\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
log_both(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));

%% STEP_3) Input Discovery and Validation
% Validate required recordings and preserve documented duration exceptions.
try
    log_both(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    results_tbl = build_inventory(config);
    log_both(fileID, 'Conditions: 32; expected pairs: 160; found pairs: %d.\n', height(results_tbl));
    log_both(fileID, 'Input dataset: exp_evaluation/exp_inputs/TREND/\n');
    log_both(fileID, 'Design: WK01/WK02 x WED/THU/SAT/SUN x EMRN/MORN/AFTN/EVEN x T01-T05.\n');
    log_both(fileID, 'THU dataset directory: WDAY/THUR.\n');
    log_both(fileID, 'All recordings: mono, 44100 Hz, nominally 200 s; tolerance one source sample.\n');
    log_both(fileID, 'ENF: 60 Hz; method 1 on both channels; weighted-energy exponent gamma=3.\n');
    log_both(fileID, 'Harmonics: %s Hz; frame=%d samples; overlap=%d; FFT setting=%d.\n', ...
        mat2str(config.harmonics), config.frame_size, config.overlap_size, config.nfft);
    log_both(fileID, 'Preprocessing: factor=3; 44100-to-1050 Hz decimation.\n');
    log_both(fileID, 'Method 1 FFT resolution: 0.03 Hz.\n');
    log_both(fileID, 'Comparison: zero-lag Pearson r; LagOptEnable=false; plots=false; Quiet=true.\n');
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
        key = sprintf('%s/%s/%s/%s', results_tbl.Week(index), results_tbl.Day(index), ...
            results_tbl.TimeOfDay(index), results_tbl.Trial(index));
        reference = string(fullfile(config.baseDir, results_tbl.RelativeFolder(index), 'mains_pow_trace_ac.wav'));
        sensed = string(fullfile(config.baseDir, results_tbl.RelativeFolder(index), 'fpga_em_trace_dc.wav'));
        try
            r = proc_enf_analysis(reference, sensed, config.nfft, config.frame_size, config.overlap_size, ...
                config.harmonics, config.nominal_freq, config.harmonics, config.nominal_freq, ...
                1, config.nominal_freq, config.harmonics, 1, config.nominal_freq, config.harmonics, ...
                'AC mains reference', 'Ambient EM sensed', false, 'Quiet', true, 'LagOptEnable', false);
        catch processing_error
            error('TemporalReliability:ProcessingFailed', 'Processing failed for %s: %s', key, processing_error.message);
        end
        assert(isscalar(r) && isfinite(r) && abs(r) <= 1, 'Invalid Pearson correlation for %s.', key);
        results_tbl.Correlation(index) = r;
    end
    assert(height(results_tbl) == 160 && all(isfinite(results_tbl.Correlation)), 'Require 160 finite correlations.');
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
    results_tbl.z = z_data;
    log_both(fileID, '\nProcessed pairs: %d; valid N: %d\n', height(results_tbl), r_stats.N);
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (r)\n');
    print_stats_table(r_stats, 'All Correlations (r)', fileID);
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (Fisher z)\n');
    print_stats_table(z_stats, 'All Correlations (z'')', fileID);
    log_both(fileID, '%-22s | %20.6f\n', 'Mean (r from z-mean)', tanh(z_stats.mean));
    ci_r = tanh(z_stats.mean + [-1 1] * z_stats.ci95_margin);
    log_both(fileID, '%-22s | [%.6f, %.6f]\n', '95% CI (r from z)', ci_r(1), ci_r(2));
    log_both(fileID, 'Fisher transform: atanh(r); correlation limits clipped to +/-0.9999999.\n');

    log_both(fileID, '\n\nInferential tests (within-condition repeated measures)\n');
    out_time = run_rm_anova(results_tbl, {'Week','Day'}, 'TimeOfDay', config.times, fileID);
    out_day = run_rm_anova(results_tbl, {'Week','TimeOfDay'}, 'Day', config.days, fileID);
    out_week = run_week_pairwise_comparisons(results_tbl, config.weeks, fileID);
    holm_p = apply_holm_tests({out_time, out_day}, fileID);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_6) Results and Figures
% Generate the three-panel time-of-day, day-of-week, and week publication figure.
try
    log_both(fileID, '\nSTEP_6) RESULTS AND FIGURES\n%s\n', repmat('%',1,85));
    plot_combined_inferential_boxplots(out_time, out_day, out_week, config.results_dir);
    log_both(fileID, '\nFIGURE GENERATION: complete\n');
    log_both(fileID, 'exp_evaluation/exp_results/enf_temporal_reliability/inferential_dotwhisker_combined.{svg,png,fig}\n');
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

% Build and validate the fixed 160-pair temporal recording inventory.
function tbl = build_inventory(config)
    n = 160;
    week = strings(n,1); day = week; time = week; trial = week; folder = week;
    index = 0;
    day_folders = {'WED','THUR','SAT','SUN'};
    day_types = {'WDAY','WDAY','WEND','WEND'};
    for w = 1:2
        for d = 1:4
            if d == 2
                assert(~isfolder(fullfile(config.baseDir, config.weeks{w}, 'WDAY', 'THU')), ...
                    'Ambiguous Thursday layout: expected only WDAY/THUR for %s.', config.weeks{w});
            end
            for t = 1:4
                for k = 1:5
                    index = index + 1;
                    week(index) = config.weeks{w}; day(index) = config.days{d};
                    time(index) = config.times{t}; trial(index) = config.trials{k};
                    folder(index) = string(fullfile(config.weeks{w}, day_types{d}, day_folders{d}, config.times{t}, config.trials{k}));
                end
            end
        end
    end
    tbl = table(week, day, time, trial, folder, nan(n,1), ...
        'VariableNames', {'Week','Day','TimeOfDay','Trial','RelativeFolder','Correlation'});
    assert(height(unique(tbl(:,1:4))) == n, 'Duplicate expected temporal conditions.');
    expected_paths = strings(2*n,1);
    for index = 1:n
        for channel = 1:2
            names = {'mains_pow_trace_ac.wav','fpga_em_trace_dc.wav'};
            relative = fullfile(tbl.RelativeFolder(index), names{channel});
            path = fullfile(config.baseDir, relative);
            assert(isfile(path), 'Missing required temporal input: %s.', relative);
            info = audioinfo(path);
            assert(info.NumChannels == 1 && info.SampleRate == 44100, ...
                'Expected mono 44100 Hz temporal input: %s.', relative);
            assert(abs(info.Duration - 200) <= 1/info.SampleRate, ...
                'Recording is not nominally 200 seconds: %s (%.9f s).', relative, info.Duration);
            expected_paths(2*(index-1)+channel) = string(path);
        end
    end
    % A secondary scan detects duplicate/alternative labeled recordings.
    % Selection itself comes exclusively from the fixed inventory above.
    found = dir(fullfile(config.baseDir, '**', '*.wav'));
    found_paths = strings(numel(found),1);
    for index = 1:numel(found)
        found_paths(index) = string(fullfile(found(index).folder, found(index).name));
    end
    assert(numel(found_paths) == 320 && isequal(sort(found_paths), sort(expected_paths)), ...
        'TREND has missing, duplicate, or unexpected WAV paths; require the exact 160-pair inventory.');
end

% Aggregate Fisher-z values into complete repeated-measures condition means.
function [Y, W] = condition_means(tbl, grouping, factor, levels, expected_subjects)
    % Preserve the original groupsummary/unstack aggregation on Fisher z.
    S = groupsummary(tbl, [grouping, {factor}], 'mean', 'z');
    assert(all(S.GroupCount == 5), 'Each condition requires exactly five valid trials.');
    W = unstack(S, 'mean_z', factor, 'GroupingVariables', grouping);
    assert(all(ismember(levels, W.Properties.VariableNames)), 'Missing repeated-measures level for %s.', factor);
    Y = W{:,levels};
    assert(height(W) == expected_subjects && all(isfinite(Y(:))), ...
        'Require %d complete subjects for %s; none may be dropped.', expected_subjects, factor);
end

% Run a repeated-measures ANOVA and report its estimates and test statistics.
function out = run_rm_anova(tbl, subjectGroupingVars, factorName, levels, fileID)
    [Y, ~] = condition_means(tbl, subjectGroupingVars, factorName, levels, 8);
    nSubj = size(Y,1);
    tY = array2table(Y, 'VariableNames', levels);
    withinDesign = table(categorical(levels'), 'VariableNames', {factorName});
    formula = sprintf('%s-%s ~ 1', levels{1}, levels{end});
    rm = fitrm(tY, formula, 'WithinDesign', withinDesign);
    ran = ranova(rm, 'WithinModel', factorName);
    rn = string(ran.Properties.RowNames);
    idx = find(rn == "(Intercept):" + string(factorName), 1);
    errIdx = find(rn == "Error(" + string(factorName) + ")", 1);
    assert(~isempty(idx) && ~isempty(errIdx), 'Missing ANOVA factor/error row for %s.', factorName);
    assert(ismember('pValueGG', ran.Properties.VariableNames), 'Missing Greenhouse-Geisser correction.');
    out = level_estimates(Y, levels);
    out.factor = factorName;
    out.F = ran.F(idx);
    out.df1 = ran.DF(idx);
    out.df2 = ran.DF(errIdx);
    out.p_raw = ran.pValue(idx);
    out.p_GG = ran.pValueGG(idx);
    out.eta_p2 = ran.SumSq(idx) / (ran.SumSq(idx) + ran.SumSq(errIdx));
    assert(all(isfinite([out.F out.p_raw out.p_GG])) && out.df1 == 3 && out.df2 == 21, ...
        'Invalid four-level RM-ANOVA result for %s.', factorName);
    log_both(fileID, '\n[%s] Repeated-Measures ANOVA (subjects = %s)\n', factorName, strjoin(subjectGroupingVars,' x '));
    log_both(fileID, '    Complete retained subjects: %d\n', nSubj);
    log_both(fileID, '\n    RM-ANOVA Summary (%s)\n', factorName);
    log_both(fileID, '    %-10s | %4s | %4s | %12s | %12s | %12s | %12s\n', ...
        'Effect','df1','df2','F','p','p(GG)','eta_p^2');
    log_both(fileID, '    %-10s | %4d | %4d | %12.6f | %12.6f | %12.6f | %12.6f\n', ...
        factorName, out.df1, out.df2, out.F, out.p_raw, out.p_GG, out.eta_p2);
    print_level_estimates(out, fileID);
end

% Compare the two weeks with the established paired t-test.
function out = run_week_pairwise_comparisons(tbl, levels, fileID)
    [Y, ~] = condition_means(tbl, {'Day','TimeOfDay'}, 'Week', levels, 16);
    x = Y(:,1); y = Y(:,2); % Original comparison order: WK01 minus WK02.
    [~, p, ci, stats] = ttest(x, y);
    assert(isfinite(p) && isfinite(stats.tstat) && stats.df == 15, 'Week paired t-test failed.');
    out = level_estimates(Y, levels);
    out.mean_diff_z = mean(x-y);
    out.t = stats.tstat;
    out.df = stats.df;
    out.p = p;
    log_both(fileID, '\n[Week] Paired t-test (subjects = Day x TimeOfDay)\n');
    log_both(fileID, '    Complete matched conditions: %d\n', size(Y,1));
    log_both(fileID, '    %-11s | %4s | %12s | %12s | %s\n', ...
        'Pair','df','t','p (two-sided)','Mean diff z [95% CI]');
    log_both(fileID, '    %-11s | %4d | %12.6f | %12.6f | %.6f [%.6f, %.6f]\n', ...
        'WK01-WK02', out.df, out.t, out.p, out.mean_diff_z, ci(1), ci(2));
    print_level_estimates(out, fileID);
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

% Apply Holm-Bonferroni correction to the two omnibus repeated-measures tests.
function adjusted = apply_holm_tests(outputs, fileID)
    pvals = cellfun(@(out) out.p_GG, outputs);
    assert(numel(pvals) == 2 && all(isfinite(pvals)), 'Holm family requires exactly two finite GG p-values.');
    adjusted = holm_adjust_pvalues(pvals);
    [sorted, order] = sort(pvals);
    continuing = true;
    log_both(fileID, '\n[Holm-Bonferroni across the two omnibus RM tests (GG p-values)]\n');
    log_both(fileID, '    Familywise alpha = 0.05\n');
    for index = 1:2
        original = order(index);
        threshold = 0.05/(3-index);
        reject = continuing && sorted(index) <= threshold;
        continuing = continuing && reject;
        if reject, decision = 'SIGNIFICANT'; else, decision = 'not significant'; end
        log_both(fileID, '    %s: p(GG)=%.6f, p_Holm=%.6f vs alpha_Holm=%.6f -> %s\n', ...
            outputs{original}.factor, pvals(original), adjusted(original), threshold, decision);
    end
    if all(adjusted > 0.05)
        log_both(fileID, '    Result: No RM effect survives Holm correction.\n');
    else
        log_both(fileID, '    Result: At least one RM effect survives Holm correction.\n');
    end
    log_both(fileID, 'The week paired t-test is outside this two-test correction family.\n');
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID, varargin)
    message = sprintf(varargin{:});
    fprintf(1, '%s', message);
    fprintf(fileID, '%s', message);
end

% Calculate descriptive statistics on the correlation and Fisher-z scales.
function [r_stats, z_data, z_stats] = calculate_basic_stats(all_correlations)
    r_stats = sub_calc_stats(all_correlations);

    r_safe = all_correlations;
    r_safe(r_safe >= 1.0)  = 0.9999999;
    r_safe(r_safe <= -1.0) = -0.9999999;

    z_data  = atanh(r_safe);
    z_stats = sub_calc_stats(z_data);
end

% Calculate the descriptive statistics and confidence interval for one vector.
function stats = sub_calc_stats(x)
    x = x(isfinite(x));
    if isempty(x)
        stats = struct('N',0,'mean',NaN,'median',NaN,'std',NaN,'min',NaN,'max',NaN, ...
                       'var',NaN,'skew',NaN,'kurt',NaN,'sem',NaN,'ci95_margin',NaN);
        return;
    end
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
    df           = max(stats.N - 1, 1);
    tcrit        = tinv(0.975, df);
    stats.ci95_margin = tcrit * stats.sem;
end

% Compute Holm-adjusted p-values while preserving their original order.
function p_adjusted = holm_adjust_pvalues(p_values)
    p_adjusted = nan(size(p_values));
    valid = find(isfinite(p_values));
    if isempty(valid), return; end

    [p_sorted, order] = sort(p_values(valid));
    m = numel(p_sorted);
    adjusted_sorted = zeros(size(p_sorted));
    running_max = 0;
    for ii = 1:m
        running_max = max(running_max, (m - ii + 1) * p_sorted(ii));
        adjusted_sorted(ii) = min(running_max, 1);
    end
    p_adjusted(valid(order)) = adjusted_sorted;
end

% Generate the three-panel time-of-day, day-of-week, and week figure.
function plot_combined_inferential_boxplots(out_time, out_day, out_week, results_dir)
    fig = figure('Name','Inferential_DotWhisker_Combined', ...
                 'Visible','off', ...
                 'Position',[100,100,1350,420]);

    violet_main = [63  81 181] / 255;
    violet_dark = [26  35 126] / 255;

    % Time-of-day panel.
    ax1 = subplot(1,3,1);
    if isfield(out_time,'mu_r') && ~isempty(out_time.mu_r)
        draw_dotwhisker_on_ax(ax1, out_time.mu_r, out_time.ci_lo_r, out_time.ci_hi_r, ...
            out_time.levels, 'Time-of-day', true, violet_main, violet_dark);
    else
        axis(ax1,'off');
        text(0.5,0.5,'Time-of-day N/A','HorizontalAlignment','center');
    end

    % Day-of-week panel.
    ax2 = subplot(1,3,2);
    if isfield(out_day,'mu_r') && ~isempty(out_day.mu_r)
        draw_dotwhisker_on_ax(ax2, out_day.mu_r, out_day.ci_lo_r, out_day.ci_hi_r, ...
            out_day.levels, 'Day-of-week', false, violet_main, violet_dark);
    else
        axis(ax2,'off');
        text(0.5,0.5,'Day-of-week N/A','HorizontalAlignment','center');
    end

    % Week panel.
    ax3 = subplot(1,3,3);
    if isfield(out_week,'mu_r') && ~isempty(out_week.mu_r)
        draw_dotwhisker_on_ax(ax3, out_week.mu_r, out_week.ci_lo_r, out_week.ci_hi_r, ...
            out_week.levels, 'Week-to-week', false, violet_main, violet_dark);
    else
        axis(ax3,'off');
        text(0.5,0.5,'Week N/A','HorizontalAlignment','center');
    end

    % Save the combined figure.
    fn = fullfile(results_dir, 'inferential_dotwhisker_combined');
    saveas(fig, [fn '.png']);
    saveas(fig, [fn '.svg']);
    savefig(fig, [fn '.fig']);
    close(fig);

    fprintf('  Saved inferential_dotwhisker_combined.{png,svg,fig}\n');
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

    % Use the same fixed correlation scale for all three panels.
    ylim(ax, [0.980 0.999]);
    set(ax, 'YTick', [0.980 0.985 0.990 0.995 0.999]);
    ytickformat(ax, '%.3f');

    title(ax, title_str, 'FontWeight','normal', 'FontSize',10);
    hold(ax,'off');
end
