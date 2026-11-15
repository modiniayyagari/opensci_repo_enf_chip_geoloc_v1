%% ENF Multi-Location Grid Discrimination
% Purpose:
%   Evaluate discrimination between the selected synchronous power grids.
%
% Experiment:
%   Main paper Section 6.3 and Figures 15-17.
%
% Analysis:
%   Compare intra-grid and inter-grid correlations using descriptive
%   statistics, Fisher-z analysis, a Welch test, and Gaussian EER models.
%
% Inputs:
%   exp_evaluation/exp_inputs/MULTI; 18 folders, 81 WAVs, and 162 pairs
%   comprising 63 intra-grid and 99 inter-grid comparisons.
%
% Outputs:
%   PNG/SVG/FIG figures under exp_evaluation/exp_results/multiloc_validation
%   and the script log under exp_evaluation/exp_logs.
%
% Dependencies:
%   Shared exp_validation/exp_scripts/proc_enf_analysis.p; Signal Processing
%   and Statistics toolboxes.
%
% Usage:
%   Run from any working directory; retain the validated phase, season, and
%   trial inventory and capture-tail allowance.


%% STEP_1) Script Configuration
% Set MULTI roots and retain the experiment-specific ENF configuration.
config = struct();
standardization_timer = tic;

% Repository and Output Paths
script_dir = fileparts(mfilename('fullpath'));
evaluation_root = fileparts(script_dir);
repository_root = fileparts(evaluation_root);
config.input_root = fullfile(evaluation_root, 'exp_inputs', 'MULTI');
config.shared_dir = fullfile(repository_root, 'exp_validation', 'exp_scripts');
config.results_dir = fullfile(evaluation_root, 'exp_results', 'multiloc_validation');
config.log_dir = fullfile(evaluation_root, 'exp_logs');

% ENF Extraction Parameters
config.frame_size = 8000; % samples
config.overlap_size = 0;
config.nfft = 32768;

%% STEP_2) Setup: Logging and Output Directories
% Initialize shared dependencies, output directories, and dual console/file logging.

% Protected MATLAB Analysis Dependency
assert(isfile(fullfile(config.shared_dir,'proc_enf_analysis.p')), 'Missing shared ENF processor.');
addpath(config.shared_dir, '-begin');
assert(strcmp(which('proc_enf_analysis'), fullfile(config.shared_dir,'proc_enf_analysis.p')), ...
    'MATLAB resolved a different shared ENF processor.');

% Output Directories
if ~isfolder(config.log_dir), mkdir(config.log_dir); end
if ~isfolder(config.results_dir), mkdir(config.results_dir); end

% Logging Setup
[~, script_name] = fileparts(mfilename('fullpath'));
log_filename = fullfile(config.log_dir, [script_name '_log.txt']);
fileID = fopen(log_filename,'w');
assert(fileID >= 0, 'Cannot open multi-location log.');
cleanupObj = onCleanup(@() fclose(fileID));
log_both(fileID, '%s\nENF MULTI-LOCATION GRID DISCRIMINATION\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
log_both(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));

%% STEP_3) Input Discovery and Validation
% Validate the fixed 18-folder, 81-WAV inventory that produces 162 pairwise
% comparisons partitioned into 63 intra-grid and 99 inter-grid pairs.
try
    log_both(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    [inventory, duration_range] = build_inventory(config);
    log_both(fileID, '\nEXPERIMENT CONFIGURATION\nDataset: exp_evaluation/exp_inputs/MULTI/\n');
    log_both(fileID, 'Phases: US_60 then DE_50; seasons: AUG/OCT; trials: T01-T03.\n');
    log_both(fileID, 'Expected/found: 18 folders; 81 WAVs; 162 unordered pairs (63 intra, 99 inter).\n');
    log_both(fileID, 'US_60: AUG/WED, OCT/MON, OCT/WED; DE_50: AUG/WED, OCT/THU, OCT/TUE.\n');
    log_both(fileID, 'Mono 44100 Hz captures; nominal duration 200 s, allowed +/-1.5 s.\n');
    log_both(fileID, 'Observed duration range: [%.9f, %.9f] s; no padding or trimming.\n', duration_range);
    log_both(fileID, 'ENF: weighted-energy method 1 on both traces; gamma=3; seven harmonics.\n');
    log_both(fileID, '60 Hz harmonics: [60 120 180 240 300 360 420]; 50 Hz: [50 100 150 200 250 300 350].\n');
    log_both(fileID, 'Frame=8000 samples; overlap=0; FFT setting=32768; zero-lag Pearson r.\n');
    log_both(fileID, 'LagOptEnable=false; Quiet=true; plotting=false during extraction.\n');
    log_both(fileID, 'Preprocessing: 44100-to-1050 Hz decimation; method-1 FFT resolution=0.03 Hz.\n');
    log_both(fileID, 'Grid mapping: egrid/local DE control=Eastern 60 Hz; tgrid=Texas 60 Hz; wgrid=Western 60 Hz; dresden=European 50 Hz.\n');
    log_both(fileID, 'ST=ambient EM sensed trace; AR=AC mains reference. All EM/AC and AC/AC pairs retained.\n');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_4) ENF Extraction and Pairwise Correlation
% Process all 162 fixed pairs with the existing intra/inter partition.
try
    log_both(fileID, '\nSTEP_4) ENF EXTRACTION AND PAIRWISE CORRELATION\n%s\n', repmat('%',1,85));
    results_tbl = run_pairwise_analysis(inventory, config, fileID);
    intra = results_tbl.Correlation(results_tbl.PairClass == "Intra-Grid");
    inter = results_tbl.Correlation(results_tbl.PairClass == "Inter-Grid");
    assert(height(results_tbl)==162 && numel(intra)==63 && numel(inter)==99 && all(isfinite(results_tbl.Correlation)), ...
        'Require exactly 162 finite correlations with the 63/99 partition.');
    print_exp_analysis_summary(results_tbl, fileID);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_5) Descriptive Statistics
% Calculate raw-correlation and Fisher-z descriptive statistics, effect sizes,
% overlap, and class-separation metrics.
try
    log_both(fileID, '\nSTEP_5) DESCRIPTIVE STATISTICS\n%s\n', repmat('%',1,85));
    r_stats.intra = calculate_basic_stats(intra); r_stats.inter = calculate_basic_stats(inter);
    z_intra = calculate_fisher_z_transform(intra); z_inter = calculate_fisher_z_transform(inter);
    z_stats.intra = calculate_basic_stats(z_intra); z_stats.inter = calculate_basic_stats(z_inter);
    z_stats.cohens_d = sub_calc_cohens_d(z_intra,z_inter);
    cliff_delta = sub_calc_cliff_delta(intra,inter);
    raw_overlap = sub_calc_overlap(intra,inter);
    separation_margin = sub_calc_margin(intra,inter);
    assert(isfinite(raw_overlap), 'Raw-r overlap estimation failed.');
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (r)\n');
    print_stats_table(r_stats.intra,r_stats.inter,fileID,'Intra-grid r','Inter-grid r');
    log_both(fileID, '\nDESCRIPTIVE STATISTICS (Fisher z)\n');
    print_stats_table(z_stats.intra,z_stats.inter,fileID,'Intra-grid z','Inter-grid z');
    log_both(fileID, 'Descriptive CIs retain mean +/-1.96*SEM; Fisher limits retain +/-0.9999999.\n');
    log_both(fileID, '\nComparison Metrics\n');
    log_both(fileID, '%-30s | %.9f\n', 'Cohen''s d (Fisher z)', z_stats.cohens_d);
    log_both(fileID, '%-30s | %.9f\n', 'Cliff''s delta (raw r)', cliff_delta);
    log_both(fileID, '%-30s | %.9f\n', 'KDE overlap coefficient (raw r)', raw_overlap);
    log_both(fileID, '%-30s | %.9f\n', 'Separation margin (raw r)', separation_margin);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_6) Correlation Heatmaps
% Generate the existing file-level and grid-level correlation heatmaps.
try
    log_both(fileID, '\nSTEP_6) CORRELATION HEATMAPS\n%s\n', repmat('%',1,85));
    file_matrices = generate_heatmaps(results_tbl, inventory, config.results_dir, fileID, false);
    log_both(fileID, '\nGrid-Level Correlation Heatmaps\n');
    grid_matrices = generate_heatmaps(results_tbl, inventory, config.results_dir, fileID, true);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_7) Hypothesis Tests and EER Analysis
% Apply the one-sided Fisher-z Welch test and both Gaussian EER variance models.
try
    log_both(fileID, '\nSTEP_7) HYPOTHESIS TESTS AND EER ANALYSIS\n%s\n', repmat('%',1,85));
    [~, welch_p, ~, welch] = ttest2(z_intra,z_inter,'Vartype','unequal','Tail','right');
    assert(all(isfinite([welch.tstat welch.df welch_p])), 'Welch test failed.');
    log_both(fileID, 'Welch unequal-variance test on Fisher z: intra > inter (one-sided right tail).\n');
    log_both(fileID, 'N_intra=%d; N_inter=%d; t=%.9f; df=%.9f; p=%.9e; Cohen''s d=%.9f\n', ...
        numel(intra),numel(inter),welch.tstat,welch.df,welch_p,z_stats.cohens_d);
    eer_stats = compute_parametric_eer_gaussian(z_stats,intra,inter,fileID);
    gaussian_overlap = plot_z_score_distributions(z_stats,config.results_dir,fileID);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_8) Representative ENF Figure
% Render the fixed representative six-trace ENF overlay used for Figure 15.
try
    log_both(fileID, '\nSTEP_8) REPRESENTATIVE ENF FIGURE\n%s\n', repmat('%',1,85));
    figure15_correlations=plot_representative_enf_overlay(results_tbl,config,fileID);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% STEP_9) Final Summary and Logging
% Report successful figure generation and preserved output locations.
try
    log_both(fileID, '\nSTEP_9) FINAL SUMMARY AND LOGGING\n%s\n', repmat('%',1,85));
    log_both(fileID, '\nFIGURE GENERATION\nSix paper-relevant figures saved as PNG, SVG, FIG under exp_evaluation/exp_results/multiloc_validation/.\n');
    log_both(fileID, 'avg_file_heatmap_US; avg_file_heatmap_DE; summary_correlation_heatmap_US; summary_correlation_heatmap_DE; z_score_distributions.\n');
    log_both(fileID, 'enf_trace_overlay_US_60_AUG_WED_T02.\n');
    log_both(fileID, 'Execution status: SUCCESS\nTotal execution time: %.3f s\n', toc(standardization_timer));
    clear cleanupObj;
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanupObj;
    rethrow(execution_error);
end

%% Local Functions
% Generate and verify the fixed representative six-trace ENF overlay.
function correlations = plot_representative_enf_overlay(results_tbl,config,fileID)
    folder=fullfile('US_60','AUG','WED','T02');
    files={'fpga_em_trace_dc_egrid_citya_lab.wav', ...
        'mains_pow_trace_ac_egrid_citya_lab.wav', ...
        'mains_pow_trace_ac_egrid_citya_home.wav', ...
        'mains_pow_trace_ac_egrid_worcester.wav', ...
        'mains_pow_trace_ac_tgrid_richardson.wav', ...
        'mains_pow_trace_ac_wgrid_tucson.wav'};
    labels={'ST: ambient EM','AR1: local lab / Eastern','AR2: local home / Eastern', ...
        'AR3: third Eastern reference','AR4: Texas reference','AR5: Western reference'};
    common_path=string(fullfile(config.input_root,folder,files{2}));
    harmonics=60:60:420;
    effective_fs=1050; % Shared-core conversion of the validated 44100 Hz WAVs.
    hop_sec=(config.frame_size-config.overlap_size)/effective_fs;
    series=cell(1,6);
    common_reference=[];
    log_both(fileID,'\nFIGURE 15: REPRESENTATIVE SIX-TRACE ENF OVERLAY\n');
    log_both(fileID,'Selected folder: US_60/AUG/WED/T02/\n');
    log_both(fileID,'Shared core: method 1, gamma=3, 60 Hz, seven harmonics, frame=8000 samples, overlap=0, FFT setting=32768.\n');
    log_both(fileID,'Effective Fs=1050 Hz; hop=%.12f s; time origin=0; no shifts, smoothing, or interpolation.\n',hop_sec);
    log_both(fileID,'All extractions use the local lab mains recording as the common reference.\n');
    for index=1:6
        path=string(fullfile(config.input_root,folder,files{index}));
        [~,~,~,~,reference,enf]=proc_enf_analysis(common_path,path, ...
            config.nfft,config.frame_size,config.overlap_size, ...
            harmonics,60,harmonics,60,1,60,harmonics,1,60,harmonics, ...
            'Local lab mains reference',labels{index},false,'LagOptEnable',false,'Quiet',true);
        if index==1
            common_reference=reference;
        else
            assert(isequal(reference,common_reference),'Common Figure 15 reference changed across extractions.');
        end
        assert(isvector(enf) && all(isfinite(enf)),'Invalid Figure 15 ENF series: %s.',files{index});
        series{index}=enf(:);
        log_both(fileID,'    %s: %s\n',labels{index},files{index});
    end
    correlations=zeros(5,1);
    selected=results_tbl.Phase=="US_60" & results_tbl.Season=="AUG" & ...
        results_tbl.CollectionDay=="WED" & results_tbl.Trial=="T02";
    for index=1:5
        n=min(numel(series{1}),numel(series{index+1}));
        correlations(index)=corr(series{1}(1:n),series{index+1}(1:n));
        pair=selected & ((results_tbl.TraceA==string(files{1}) & results_tbl.TraceB==string(files{index+1})) | ...
            (results_tbl.TraceB==string(files{1}) & results_tbl.TraceA==string(files{index+1})));
        assert(sum(pair)==1 && isfinite(correlations(index)) && ...
            abs(correlations(index)-results_tbl.Correlation(pair))<=1e-12, ...
            'Figure 15 plotted ST-to-AR correlation disagrees with pairwise analysis: %s.',files{index+1});
        log_both(fileID,'    ST vs AR%d: r=%.9f\n',index,correlations(index));
    end
    fig=figure('Name','Representative multi-location ENF','Visible','off', ...
        'Color','w','Position',[100 100 1200 480]);
    ax=axes('Parent',fig); hold(ax,'on');
    colors=[0.90 0.10 0.10;0.10 0.25 0.85;0.85 0.15 0.75;0.00 0.35 0.35;0.60 0.10 0.90;0.35 0.65 0.20];
    styles={'-','-.','--',':','-.',':'};
    handles=gobjects(6,1);
    for index=1:6
        time=(0:numel(series{index})-1).' * hop_sec;
        width=1.5;
        if index==1, width=2.0; end
        handles(index)=plot(ax,time,series{index},'Color',colors(index,:), ...
            'LineStyle',styles{index},'LineWidth',width);
    end
    values=vertcat(series{:});
    margin=max(0.002,0.06*(max(values)-min(values)));
    ylim(ax,[min(values)-margin,max(values)+margin]);
    xlim(ax,[0 200]); xticks(ax,0:40:200);
    xlabel(ax,'Time (s)'); ylabel(ax,'Instantaneous ENF (Hz)');
    title(ax,'Simultaneously Captured ENF Traces');
    set(ax,'FontName','Arial','FontSize',11,'LineWidth',1,'GridAlpha',0.25);
    grid(ax,'on'); box(ax,'on');
    legend(ax,handles,labels,'Location','eastoutside','Interpreter','none');
    save_figure_formats(fig,config.results_dir,'enf_trace_overlay_US_60_AUG_WED_T02',fileID);
    log_both(fileID,'Figure 15 generated successfully: exp_evaluation/exp_results/multiloc_validation/enf_trace_overlay_US_60_AUG_WED_T02.{png,svg,fig}\n');
end

% Build and validate the fixed dataset inventory and grid identities.
function [inventory, duration_range] = build_inventory(config)
    conditions = {'US_60','AUG','WED';'US_60','OCT','MON';'US_60','OCT','WED'; ...
        'DE_50','AUG','WED';'DE_50','OCT','THU';'DE_50','OCT','TUE'};
    us_files = {'fpga_em_trace_dc_egrid_citya_lab.wav','mains_pow_trace_ac_egrid_citya_lab.wav', ...
        'mains_pow_trace_ac_egrid_citya_home.wav','mains_pow_trace_ac_egrid_worcester.wav', ...
        'mains_pow_trace_ac_tgrid_richardson.wav','mains_pow_trace_ac_wgrid_tucson.wav'};
    de_files = {'fpga_em_trace_dc_citya_lab.wav','mains_pow_trace_ac_citya_lab.wav','mains_pow_trace_ac_dresden.wav'};
    inventory = struct('Phase',{},'Season',{},'Day',{},'Trial',{},'Folder',{},'Files',{});
    expected_paths = strings(81,1); next_file=0; classes=[0 0]; durations=zeros(81,1);
    for condition=1:6
        for trial=1:3
            phase=conditions{condition,1}; season=conditions{condition,2}; day=conditions{condition,3};
            label=sprintf('T%02d',trial); folder=fullfile(phase,season,day,label);
            if strcmp(phase,'US_60'), files=us_files; else, files=de_files; end
            listing=dir(fullfile(config.input_root,folder,'*.wav'));
            assert(isequal(sort({listing.name}),sort(files)), 'Missing, duplicate, or unexpected WAV names in %s.',folder);
            grids=cell(1,numel(files));
            for k=1:numel(files)
                next_file=next_file+1;
                path=fullfile(config.input_root,folder,files{k});
                info=audioinfo(path);
                assert(info.NumChannels==1 && info.SampleRate==44100, 'Expected mono 44100 Hz input: %s/%s.',folder,files{k});
                assert(abs(info.Duration-200)<=1.5, 'Capture outside nominal duration allowance: %s/%s (%.9f s).',folder,files{k},info.Duration);
                durations(next_file)=info.Duration; expected_paths(next_file)=string(path);
                id=get_file_identity(files{k},phase); grids{k}=id.grid;
            end
            for a=1:numel(files)-1
                for b=a+1:numel(files)
                    is_intra=strcmp(grids{a},grids{b});
                    classes(2-is_intra)=classes(2-is_intra)+1;
                end
            end
            inventory(end+1)=struct('Phase',phase,'Season',season,'Day',day,'Trial',label,'Folder',folder,'Files',{files});
        end
    end
    listing=dir(fullfile(config.input_root,'**','*.wav'));
    found=strings(numel(listing),1);
    for k=1:numel(listing), found(k)=string(fullfile(listing(k).folder,listing(k).name)); end
    assert(numel(inventory)==18 && numel(unique(string({inventory.Folder})))==18 && ...
        next_file==81 && numel(found)==81 && isequal(sort(found),sort(expected_paths)), ...
        'MULTI inventory must contain exactly 18 unique folders and 81 expected WAVs.');
    assert(isequal(classes,[63 99]), 'Inventory grid partition must be 63 intra / 99 inter.');
    duration_range=[min(durations),max(durations)];
end

% Map one filename and phase to its trace type and power-grid identity.
function identity = get_file_identity(filename, phase)
    if strcmp(phase,'US_60')
        if contains(filename,'egrid')
            grid='US_EGrid_60Hz';
        elseif contains(filename,'tgrid')
            grid='US_TGrid_60Hz';
        elseif contains(filename,'wgrid')
            grid='US_WGrid_60Hz';
        else
            error('Unrecognized US trace identity: %s.',filename);
        end
        freq=60;
    elseif strcmp(phase,'DE_50')
        if strcmp(filename,'mains_pow_trace_ac_dresden.wav')
            grid='DE_50Hz'; freq=50;
        elseif ismember(filename,{'fpga_em_trace_dc_citya_lab.wav','mains_pow_trace_ac_citya_lab.wav'})
            grid='US_EGrid_60Hz'; freq=60;
        else
            error('Unrecognized DE trace identity: %s.',filename);
        end
    else
        error('Unrecognized phase: %s.',phase);
    end
    identity=struct('grid',grid,'freq',freq,'harmonics',(1:7)*freq);
end

% Process every unordered trace pair and record its ENF correlation class.
function tbl = run_pairwise_analysis(inventory,config,fileID)
    names={'Phase','Season','CollectionDay','Trial','TraceA','TraceB','GridA','GridB','Correlation','PairClass'};
    rows=cell(162,10); index=0;
    for item=inventory
        n=numel(item.Files);
        log_both(fileID,'\nProcessing folder: %s\nNumber of traces: %d; pairwise comparisons: %d\n', ...
            strrep(item.Folder,'\','/'),n,nchoosek(n,2));
        for a=1:n-1
            for b=a+1:n
                id_a=get_file_identity(item.Files{a},item.Phase); id_b=get_file_identity(item.Files{b},item.Phase);
                path_a=string(fullfile(config.input_root,item.Folder,item.Files{a}));
                path_b=string(fullfile(config.input_root,item.Folder,item.Files{b}));
                try
                    [matched,lag,~,r]=proc_enf_analysis(path_a,path_b,config.nfft,config.frame_size,config.overlap_size, ...
                        id_a.harmonics,id_a.freq,id_b.harmonics,id_b.freq, ...
                        1,id_a.freq,id_a.harmonics,1,id_b.freq,id_b.harmonics, ...
                        item.Files{a},item.Files{b},false,'LagOptEnable',false,'Quiet',true);
                catch processing_error
                    error('MultiLocation:ProcessingFailed','%s: %s versus %s: %s',item.Folder,item.Files{a},item.Files{b},processing_error.message);
                end
                assert(isscalar(r) && isfinite(r) && abs(r)<=1 && matched==r && lag==0, ...
                    'Invalid zero-lag correlation: %s / %s versus %s.',item.Folder,item.Files{a},item.Files{b});
                if strcmp(id_a.grid,id_b.grid), pair_class='Intra-Grid'; else, pair_class='Inter-Grid'; end
                index=index+1;
                rows(index,:)={string(item.Phase),string(item.Season),string(item.Day),string(item.Trial), ...
                    string(item.Files{a}),string(item.Files{b}),string(id_a.grid),string(id_b.grid),r,string(pair_class)};
                log_both(fileID,'    [%s] %s vs %s: r=%.9f\n',pair_class,item.Files{a},item.Files{b},r);
            end
        end
    end
    assert(index==162,'Expected 162 processed comparisons.');
    tbl=cell2table(rows,'VariableNames',names);
end

% Report the fixed pair inventory and intra-grid/inter-grid partition.
function print_exp_analysis_summary(tbl,fileID)
    folder_count=height(unique(tbl(:,{'Phase','Season','CollectionDay','Trial'})));
    log_both(fileID,'\nFULL EXPERIMENT SUMMARY\nTotal trace folders: %d\n',folder_count);
    for phase={"US_60","DE_50"}
        selected=tbl.Phase==phase{1};
        folders=unique(tbl(selected,{'Season','CollectionDay','Trial'}));
        same=sum(selected & tbl.PairClass=="Intra-Grid"); different=sum(selected & tbl.PairClass=="Inter-Grid");
        log_both(fileID,'%s: folders=%d; intra-grid=%d; inter-grid=%d; total=%d\n',phase{1},height(folders),same,different,same+different);
    end
    log_both(fileID,'OVERALL: total=%d; intra-grid=%d; inter-grid=%d\n',height(tbl),sum(tbl.PairClass=="Intra-Grid"),sum(tbl.PairClass=="Inter-Grid"));
    labels=unique([tbl.TraceA;tbl.TraceB],'stable');
    log_both(fileID,'Per-trace participation counts (each pair contributes to two traces):\n');
    for name=labels'
        selected=tbl.TraceA==name | tbl.TraceB==name;
        log_both(fileID,'    %s: total=%d; intra=%d; inter=%d\n',name,sum(selected), ...
            sum(selected & tbl.PairClass=="Intra-Grid"),sum(selected & tbl.PairClass=="Inter-Grid"));
    end
end

% Print side-by-side descriptive statistics for two correlation classes.
function print_stats_table(a,b,fileID,label_a,label_b)
    log_both(fileID,'%-16s | %24s | %24s\n','Statistic',label_a,label_b);
    log_both(fileID,'%-16s | %24d | %24d\n','Count (N)',a.N,b.N);
    labels={'Mean','Median','Std. Dev.','Variance','Skewness','Kurtosis','Std. Error'};
    fields={'mean','median','std','var','skew','kurt','sem'};
    for k=1:numel(fields)
        log_both(fileID,'%-16s | %24.9f | %24.9f\n',labels{k},a.(fields{k}),b.(fields{k}));
    end
    log_both(fileID,'%-16s | [%10.9f,%10.9f] | [%10.9f,%10.9f]\n','95% CI', ...
        a.mean-a.ci95_margin,a.mean+a.ci95_margin,b.mean-b.ci95_margin,b.mean+b.ci95_margin);
    log_both(fileID,'%-16s | %24.9f | %24.9f\n','Min',a.min,b.min);
    log_both(fileID,'%-16s | %24.9f | %24.9f\n','Max',a.max,b.max);
end

% Build, report, and export file-level or grid-level correlation heatmaps.
function matrices = generate_heatmaps(tbl,inventory,results_dir,fileID,by_grid)
    matrices=struct();
    for phase={"US_60","DE_50"}
        key=phase{1};
        selected=tbl(tbl.Phase==key,:);
        item=inventory(find(strcmp({inventory.Phase},char(key)),1));
        if by_grid
            if key=="US_60"
                identifiers={'US_EGrid_60Hz','US_TGrid_60Hz','US_WGrid_60Hz'};
                labels={'Eastern 60 Hz','Texas 60 Hz','Western 60 Hz'};
            else
                identifiers={'US_EGrid_60Hz','DE_50Hz'};
                labels={'Eastern 60 Hz','European 50 Hz'};
            end
            a=selected.GridA; b=selected.GridB;
        else
            identifiers=item.Files; labels=[{'ST'},arrayfun(@(n)sprintf('AR%d',n),1:numel(identifiers)-1,'UniformOutput',false)];
            a=selected.TraceA; b=selected.TraceB;
            for index=1:numel(identifiers)
                log_both(fileID,'    %s %s = %s\n',key,labels{index},identifiers{index});
            end
        end
        n=numel(identifiers); M=nan(n);
        for i=1:n
            M(i,i)=1; % Self-correlation reference, as in the original matrices.
            for j=1:i-1
                mask=(a==string(identifiers{i}) & b==string(identifiers{j})) | ...
                    (a==string(identifiers{j}) & b==string(identifiers{i}));
                expected=9;
                if by_grid && key=="US_60" && (i==1 || j==1), expected=36; end
                if by_grid && key=="DE_50", expected=18; end
                assert(sum(mask)==expected,'Unexpected matrix-cell comparison count for %s.',key);
                M(i,j)=mean(selected.Correlation(mask));
            end
        end
        matrices.(char(key))=M;
        assert(all(isfinite(M(tril(true(n))))),'Missing correlation matrix cell for %s.',key);
        fig=figure('Name',char(key),'Visible','off','Position',[100 100 800 650]);
        if by_grid
            vmin=-0.06; vmax=1; gamma=0.35;
            center=(((vmin+vmax)/2-vmin)/(vmax-vmin))^gamma;
            T=max(min((M-vmin)/(vmax-vmin),1),0).^gamma;
            imagesc(T,'AlphaData',~isnan(M));
            colormap(setup_diverging_colormap(0,1,center,2048)); caxis([0 1]);
            cb=colorbar; cb.Ticks=linspace(0,1,6);
            values=vmin+cb.Ticks.^(1/gamma)*(vmax-vmin);
            cb.TickLabels=arrayfun(@(x)sprintf('%.2f',x),values,'UniformOutput',false);
            title(sprintf('Summary Correlation Matrix (%s)',key),'Interpreter','none');
            xlabel('Grid'); ylabel('Grid');
            basename=['summary_correlation_heatmap_' char(extractBefore(key,'_'))];
        else
            imagesc(M,'AlphaData',~isnan(M)); colormap(setup_enf_colormap()); caxis([-0.06 1]);
            cb=colorbar;
            title(sprintf('Average Per-File Correlation (%s)',key),'Interpreter','none');
            xlabel('Trace Type'); ylabel('Trace Type');
            basename=['avg_file_heatmap_' char(extractBefore(key,'_'))];
        end
        ylabel(cb,'Correlation'); set(gca,'Color',[1 1 1]); axis equal tight;
        xticks(1:n); yticks(1:n); xticklabels(labels); yticklabels(labels); xtickangle(45);
        for i=1:n
            for j=1:i
                text(j,i,sprintf('%.3f',M(i,j)),'HorizontalAlignment','center','FontSize',9,'Color','k');
            end
        end
        box on;
        save_figure_formats(fig,results_dir,basename,fileID);
    end
    log_both(fileID,'Matrices use mean raw pairwise r over all nine folders; diagonal 1 denotes self-correlation.\n');
end

% Export one figure in PNG, SVG, and FIG formats and log its basename.
function save_figure_formats(fig,results_dir,basename,fileID)
    saveas(fig,fullfile(results_dir,[basename '.png']));
    saveas(fig,fullfile(results_dir,[basename '.svg']));
    savefig(fig,fullfile(results_dir,[basename '.fig']));
    close(fig);
    log_both(fileID,'    Saved %s.{png,svg,fig}\n',basename);
end

% Report the Gaussian EER thresholds and fixed-error operating points.
function print_eer_results(eer_stats,fileID)
    log_both(fileID,'\nParametric EER (Gaussian Fisher-z model)\n');
    log_both(fileID,'mu0 (inter)=%.9f; sigma0=%.9f; mu1 (intra)=%.9f; sigma1=%.9f\n', ...
        eer_stats.mu0,eer_stats.sigma0,eer_stats.mu1,eer_stats.sigma1);
    log_both(fileID,'Adjusted model replaces only intra sigma1 with %.6f.\n',eer_stats.sigma1_adj);
    models={eer_stats.EER,eer_stats.EER_ADJ}; labels={'Unadjusted','Adjusted'};
    for k=1:2
        model=models{k}; empirical=model.empirical;
        assert(isfinite(model.rate) && isfinite(model.r_threshold), 'Invalid Gaussian EER model.');
        log_both(fileID,'\n%s model: z threshold=%.12f; r threshold=%.12f\n',labels{k},model.tau,model.r_threshold);
        log_both(fileID,'EER probability=%.12e; EER percent=%.9f%%; FPR=%.12e; FNR=%.12e\n', ...
            model.rate,100*model.rate,model.FPR,model.FNR);
        log_both(fileID,'Empirical decision: accept intra-grid if r >= the full-precision model threshold.\n');
        log_both(fileID,'Intra=%d; inter=%d; minimum intra r=%.9f; maximum inter r=%.9f\n', ...
            empirical.N_intra_total,empirical.N_inter_total,empirical.min_intra_r,empirical.max_inter_r);
        log_both(fileID,'True accepts=%d; false rejects=%d; false accepts=%d; correct rejects=%d; total errors=%d\n', ...
            empirical.intra_at_or_above,empirical.intra_below,empirical.inter_at_or_above,empirical.inter_below,empirical.total_errors);
    end
    for k=1:numel(eer_stats.fixed_FPR.targets)
        a=eer_stats.fixed_FPR.original(k); b=eer_stats.fixed_FPR.adjusted(k);
        log_both(fileID,'Fixed FPR=%.3e: unadjusted z threshold=%.9f, FNR=%.9e; adjusted z threshold=%.9f, FNR=%.9e\n',a.FPR,a.tau,a.FNR,b.tau,b.FNR);
    end
    for k=1:numel(eer_stats.fixed_FNR.targets)
        a=eer_stats.fixed_FNR.original(k); b=eer_stats.fixed_FNR.adjusted(k);
        log_both(fileID,'Fixed FNR=%.3e: unadjusted z threshold=%.9f, FPR=%.9e; adjusted z threshold=%.9f, FPR=%.9e\n',a.FNR,a.tau,a.FPR,b.tau,b.FPR);
    end
end

% Apply the bounded Fisher-z transformation to correlation values.
function z_transform_data = calculate_fisher_z_transform(r_data)
    r_safe = r_data;
    r_safe(r_safe >= 1.0)  = 0.9999999;
    r_safe(r_safe <= -1.0) = -0.9999999;
    z_transform_data = atanh(r_safe);
end

% Calculate descriptive statistics and confidence limits for one vector.
function stats = calculate_basic_stats(data_array)
    if ~isempty(data_array)
        stats.N    = length(data_array);
        stats.mean = mean(data_array);
        stats.median = median(data_array);
        stats.std  = std(data_array);
        stats.min  = min(data_array);
        stats.max  = max(data_array);
        stats.var  = var(data_array);
        stats.skew = skewness(data_array);
        stats.kurt = kurtosis(data_array);
        stats.sem  = stats.std / sqrt(stats.N);
        stats.ci95_margin = 1.96 * stats.sem;
    else
        stats.N = 0;
        stats.mean = NaN; stats.median = NaN; stats.std = NaN;
        stats.min = NaN; stats.max = NaN; stats.var = NaN;
        stats.skew = NaN; stats.kurt = NaN; stats.sem = NaN;
        stats.ci95_margin = NaN;
    end
end

% Calculate Cliff's delta between two correlation groups.
function cliff_d = sub_calc_cliff_delta(g1, g2)
    if isempty(g1) || isempty(g2)
        cliff_d = NaN;
        return;
    end
    n1 = length(g1);
    n2 = length(g2);
    g1_matrix = repmat(g1(:), 1, n2);
    g2_matrix = repmat(g2(:)', n1, 1);
    comparisons = sign(g1_matrix - g2_matrix);
    cliff_d = sum(comparisons(:)) / (n1 * n2);
end

% Estimate the distribution-overlap coefficient for two groups.
function ovl = sub_calc_overlap(g1, g2)
    if isempty(g1) || isempty(g2)
        ovl = NaN;
        return;
    end
    try
        min_val = min(min(g1), min(g2));
        max_val = max(max(g1), max(g2));
        x_range = linspace(min_val, max_val, 1000);

        [f1, ~] = ksdensity(g1, x_range);
        [f2, ~] = ksdensity(g2, x_range);

        f1 = f1 / trapz(x_range, f1);
        f2 = f2 / trapz(x_range, f2);

        overlap_curve = min(f1, f2);
        ovl = trapz(x_range, overlap_curve);
    catch
        ovl = NaN;
    end
end

% Calculate the raw-correlation separation margin between two groups.
function margin = sub_calc_margin(g1, g2)
    if isempty(g1) || isempty(g2)
        margin = NaN;
        return;
    end
    margin = min(g1) - max(g2);
end

% Calculate Cohen's d for two Fisher-z groups.
function cohens_d = sub_calc_cohens_d(g1, g2)
    if isempty(g1) || isempty(g2)
        cohens_d = NaN;
        return;
    end
    n1 = length(g1);
    n2 = length(g2);
    mean1 = mean(g1);
    mean2 = mean(g2);
    std1 = std(g1);
    std2 = std(g2);

    s_pooled = sqrt(((n1-1)*std1^2 + (n2-1)*std2^2) / (n1 + n2 - 2));

    if s_pooled == 0
        cohens_d = Inf;
    else
        cohens_d = (mean1 - mean2) / s_pooled;
    end
end

% Construct the fixed ENF correlation heatmap colormap.
function cmap = setup_enf_colormap()
% ENF diverging colormap tuned for correlation heatmaps.
% [-0.060, 0.40] -> orange tones
%  0.50         -> white (pivot)
% [0.60, 1.00]  -> blue tones
% Extra contrast & resolution in [0.90, 1.00] with gamma shaping.

    vmin        = -0.10;
    vwhite      =  0.50;
    vblue_start =  0.60;   % Kept for clarity.
    vfocus      =  0.99;   % start of high-resolution blue zone
    vmax        =  1.00;

    % Colors
    orange     = [253,174, 97]/255;   % warm orange for low values
    white      = [1,1,1];            % neutral center
    blue_mid   = [144,202,249]/255;  % light/medium blue
    blue_dark  = [66,133,244]/255;  % lighter "deep" blue so black text is legible

    % High-res samples for [0.90, 1.00]
    hi_step = 0.001;
    n_hi    = ceil((vmax - vfocus)/hi_step) + 1;

    % Total samples in colormap
    N_total = 2048 + n_hi;

    % Allocate between segments [vmin,vwhite], [vwhite,vfocus]
    base_span = (vwhite - vmin) + (vfocus - vwhite); % = 1.0 here
    N_base    = N_total - n_hi;

    n_low = max(80, round(N_base * (vwhite - vmin)/base_span)); % orange -> white
    n_mid = max(80, N_base - n_low);                            % white -> blue_mid

    % Build value grid
    vals_low  = linspace(vmin,   vwhite, n_low);                  % includes white
    vals_mid  = linspace(vwhite, vfocus, n_mid+1); vals_mid(1) = [];
    vals_high = linspace(vfocus, vmax,   n_hi+1);  vals_high(1) = [];

    vals = [vals_low, vals_mid, vals_high];

    % Gamma shaping for [vfocus, vmax] to emphasize differences near 1.0
    gamma_blue = 3;

    cmap = zeros(numel(vals), 3);

    for k = 1:numel(vals)
        v = vals(k);

        if v <= vwhite
            % Orange -> White
            t = (v - vmin) / (vwhite - vmin);
            t = max(min(t,1),0);
            cmap(k,:) = orange + t*(white - orange);

        elseif v <= vfocus
            % White -> Medium Blue
            t = (v - vwhite) / (vfocus - vwhite);
            t = max(min(t,1),0);
            cmap(k,:) = white + t*(blue_mid - white);

        else
            % Medium Blue -> Lighter Dark Blue with gamma shaping
            t_lin = (v - vfocus) / (vmax - vfocus);
            t = max(min(t_lin,1),0).^gamma_blue;
            cmap(k,:) = blue_mid + t*(blue_dark - blue_mid);
        end
    end
end
% Construct a diverging colormap around the requested center value.
function cmap = setup_diverging_colormap(vmin, vmax, vcenter, numColors)
    % Diverging colormap with extra resolution near the upper end.
    % - vmin maps to red
    % - vcenter maps to white
    % - vmax maps to deep blue
    % - Majority of colors concentrated between 0.9 and 1.0 so that
    %   values like 0.998 vs 1.000 get visibly different colors.

    if nargin < 4
        numColors = 2048;  % high resolution
    end
    if nargin < 3 || isempty(vcenter)
        vcenter = (vmin + vmax) / 2;
    end

    % Anchor colors
    neg_dark = [229,115,115]/255;   % red
    neu_color = [1,1,1];            % white
    pos_dark = [21,101,192]/255;    % deep blue

    span = vmax - vmin;

    % Piecewise value mapping:
    %  - First 20% of colormap:  vmin -> 0.9   (compressed)
    %  - Remaining 80%:          0.9  -> vmax (expanded; high resolution)
    split_val = 0.9;
    split_alpha = 0.20;  % fraction of colormap for [vmin, split_val]

    idx = linspace(0,1,numColors);  % normalized colormap index in [0,1]
    val = zeros(size(idx));

    low_mask = idx <= split_alpha;
    hi_mask  = ~low_mask;

    if any(low_mask)
        val(low_mask) = vmin + (split_val - vmin) * (idx(low_mask) / split_alpha);
    end
    if any(hi_mask)
        val(hi_mask) = split_val + (vmax - split_val) * ((idx(hi_mask) - split_alpha) / (1 - split_alpha));
    end

    % Now map each "val" to RGB via diverging scheme
    cmap = zeros(numColors, 3);
    for k = 1:numColors
        if val(k) <= vcenter
            t = (val(k) - vmin) / max(vcenter - vmin, eps);
            t = max(min(t,1),0);
            cmap(k,:) = neg_dark + t * (neu_color - neg_dark);
        else
            t = (val(k) - vcenter) / max(vmax - vcenter, eps);
            t = max(min(t,1),0);
            cmap(k,:) = neu_color + t * (pos_dark - neu_color);
        end
    end
end

% Plot the Fisher-z Gaussian models and their overlap region.
function overlap_area = plot_z_score_distributions(z_stats, results_dir, fileID)
% Plot parametric separation between intra- and inter-grid scores
% using normal fits on Fisher z'-transformed correlations.

    % ---------- Summary stats ----------
    mu_intra = z_stats.intra.mean;
    sd_intra = z_stats.intra.std;
    N_intra  = z_stats.intra.N;

    mu_inter = z_stats.inter.mean;
    sd_inter = z_stats.inter.std;
    N_inter  = z_stats.inter.N;

    se_intra = sd_intra / sqrt(N_intra);
    se_inter = sd_inter / sqrt(N_inter);
    ci_intra = [mu_intra - 1.96*se_intra, mu_intra + 1.96*se_intra];
    ci_inter = [mu_inter - 1.96*se_inter, mu_inter + 1.96*se_inter];

    % ---------- Range & PDFs ----------
    lo = min(mu_inter - 4*sd_inter, mu_intra - 4*sd_intra);
    hi = max(mu_inter + 4*sd_inter, mu_intra + 4*sd_intra);
    x  = linspace(lo, hi, 2000);

    pdf_intra = normpdf(x, mu_intra, sd_intra);
    pdf_inter = normpdf(x, mu_inter, sd_inter);

    % ---------- Overlap ----------
    overlap_curve = min(pdf_intra, pdf_inter);
    overlap_area  = trapz(x, overlap_curve);
    overlap_pct   = overlap_area * 100;

    log_both(fileID, 'Gaussian Fisher-z overlap: probability=%.12e; percent=%.9f%%\n', overlap_area, overlap_pct);

    % ---------- Parametric EER threshold ----------
    tau_star = NaN;
    eer_val  = NaN;
    if all(isfinite([mu_inter, sd_inter, mu_intra, sd_intra])) && ...
       sd_inter > 0 && sd_intra > 0

        tau_star = (sd_inter*mu_intra + sd_intra*mu_inter) / (sd_inter + sd_intra);

        z0 = (tau_star - mu_inter) / sd_inter;
        z1 = (tau_star - mu_intra) / sd_intra;
        fpr_eer = 1 - normcdf(z0);
        fnr_eer = normcdf(z1);
        eer_val = 0.5 * (fpr_eer + fnr_eer);
    end

    % ---------- Colors ----------
    col_intra = [0.0000 0.4470 0.7410];  % blue
    col_inter = [0.8500 0.3250 0.0980];  % orange
    col_ovlp_main  = [0.85 0.85 0.95];   % light for main
    col_ovlp_inset = [0.75 0.75 0.75];   % gray for inset

    % ---------- Figure & main axes ----------
    fig = figure('Name', 'Z-Transformed Distributions', ...
                 'Visible', 'off', ...
                 'Position', [100, 100, 1000, 600]);

    % Shrink main axes width to leave space on the right for inset
    ax = axes('Parent', fig, 'Position', [0.08 0.18 0.60 0.75]);
    hold(ax, 'on');

    % PDFs (primary)
    h_intra = plot(ax, x, pdf_intra, 'Color', col_intra, 'LineWidth', 2.2);
    h_inter = plot(ax, x, pdf_inter, 'Color', col_inter, 'LineWidth', 2.2);

    % Overlap (light)
    h_ovlp = fill(ax, x, overlap_curve, col_ovlp_main, ...
                  'EdgeColor', 'none', 'FaceAlpha', 0.7);

    % Mean lines
    yl = ylim(ax);
    h_mean_intra = line(ax, [mu_intra mu_intra], yl, ...
                        'Color', col_intra, 'LineStyle', '--', 'LineWidth', 1.2);
    h_mean_inter = line(ax, [mu_inter mu_inter], yl, ...
                        'Color', col_inter, 'LineStyle', '--', 'LineWidth', 1.2);

    % EER threshold (if defined)
    if ~isnan(tau_star) && ~isnan(eer_val)
        h_tau = line(ax, [tau_star tau_star], yl, ...
                     'Color', [0 0 0], 'LineStyle', '-.', 'LineWidth', 1.5);
    else
        h_tau = gobjects(0);
    end
    ylim(ax, yl);

    % ---------- Axes styling & ticks ----------
    xlim(ax, [lo hi]);
    grid(ax, 'on');
    ax.GridAlpha = 0.15;
    ax.Box = 'on';

    % More ticks:
    x_step = 0.5;
    xticks(ax, ceil(lo/x_step)*x_step : x_step : floor(hi/x_step)*x_step);

    max_pdf = max([pdf_intra, pdf_inter]);
    y_step = 0.1;
    yticks(ax, 0 : y_step : ceil(max_pdf / y_step) * y_step);

    xlabel(ax, 'Z-Score (z'')');
    ylabel(ax, 'Probability Density');
    title(ax, 'Separation of Same-Grid vs Cross-Grid Scores (Fisher z'')');

    set(ax, 'FontName', 'Helvetica', 'FontSize', 9);

    % ---------- Legend at bottom ----------
    leg_entries = {
        sprintf('Intra (\\mu=%.2f, \\sigma=%.2f, 95%% CI [%.2f, %.2f])', ...
                mu_intra, sd_intra, ci_intra(1), ci_intra(2)), ...
        sprintf('Inter (\\mu=%.2f, \\sigma=%.2f, 95%% CI [%.2f, %.2f])', ...
                mu_inter, sd_inter, ci_inter(1), ci_inter(2)), ...
        sprintf('Overlap = %.4f%%', overlap_pct)
    };

    h_for_legend = [h_intra, h_inter, h_ovlp];

    if ~isempty(h_tau)
        leg_entries{end+1} = sprintf('\\tau^* (EER \\approx %.2e)', eer_val);
        h_for_legend(end+1) = h_tau;
    end

    lgd = legend(ax, h_for_legend, leg_entries, ...
                 'Location', 'southoutside', ...
                 'Orientation', 'vertical', ...
                 'Box', 'on', ...
                 'FontSize', 8);
    % Slightly tighten legend box
    lgd.Position(2) = 0.02;

        % ---------- Inset: zoomed overlap on the right ----------
        ax_inset = axes('Parent', fig, 'Position', [0.72 0.45 0.22 0.40]);
        hold(ax_inset, 'on');

        % PDFs in inset
        plot(ax_inset, x, pdf_intra, 'Color', col_intra, 'LineWidth', 1.0);
        plot(ax_inset, x, pdf_inter, 'Color', col_inter, 'LineWidth', 1.0);

        % Gray overlap shading
        fill(ax_inset, x, overlap_curve, col_ovlp_inset, ...
             'EdgeColor', 'none', 'FaceAlpha', 0.7);

        % Center zoom around max overlap
        [~, idx_max_ovlp] = max(overlap_curve);
        x_c = x(idx_max_ovlp);
        w   = max(sd_intra, sd_inter) * 3;   % span around crossing

        x_min_z = max(lo, x_c - w/2);
        x_max_z = min(hi, x_c + w/2);
        if x_max_z <= x_min_z
            x_min_z = x_c - 0.5;
            x_max_z = x_c + 0.5;
        end
        xlim(ax_inset, [x_min_z, x_max_z]);

        % Y-limits based on local overlap
        local_idx   = (x >= x_min_z) & (x <= x_max_z);
        max_pdf_z   = max(overlap_curve(local_idx));
        if isempty(max_pdf_z) || max_pdf_z <= 0
            max_pdf_z = max(pdf_intra(local_idx) + pdf_inter(local_idx));
        end
        if isempty(max_pdf_z) || max_pdf_z <= 0
            max_pdf_z = max_pdf / 5;
        end
        ylim(ax_inset, [0, max_pdf_z * 1.2]);

        % High-resolution inset ticks.
        desired_ticks = 8;
        raw_step = (x_max_z - x_min_z) / max(desired_ticks - 1, 1);
        step = max(0.01, round(raw_step / 0.01) * 0.01);  % 0.01, 0.02, 0.03, ...
        xt = x_min_z : step : x_max_z;
        if numel(xt) < 4
            step = step / 2;
            xt = x_min_z : step : x_max_z;
        end
        xt = round(xt, 3);  % avoid ugly floating labels

        xticks(ax_inset, xt);
        xticklabels(ax_inset, arrayfun(@(v) sprintf('%.2f', v), xt, 'UniformOutput', false));

        title(ax_inset, 'Overlap (Zoomed)', 'FontSize', 8);
        xlabel(ax_inset, 'z''', 'FontSize', 7);
        ylabel(ax_inset, 'Density', 'FontSize', 7);

        set(ax_inset, 'FontSize', 7, 'Box', 'on');
        grid(ax_inset, 'on');
        ax_inset.GridAlpha = 0.15;



    save_figure_formats(fig, results_dir, 'z_score_distributions', fileID);
end
% Fit the Gaussian EER models and calculate their operating points.
function eer_stats = compute_parametric_eer_gaussian( ...
        z_stats, intra_correlations, inter_correlations, fileID)
    % Classes:
    %   inter ~ N(mu0, s0)      (impostor / different-grid)
    %   intra ~ N(mu1, s1)      (genuine / same-grid)
    % Decision rule (on Fisher z'): accept "at expected site" if z >= tau.
    %
    % EER (unequal-variance) threshold:
    %   tau* solves FPR(tau) = FNR(tau) and equals:
    %   tau* = (mu0*s1 + mu1*s0) / (s0 + s1)
    %   EER  = 1 - Phi((tau* - mu0)/s0) = Phi((tau* - mu1)/s1)
    %
    % Fixed-FPR alpha:
    %   tau(alpha) = mu0 + s0 * Phi^{-1}(1 - alpha)
    %   FNR(alpha) = Phi((tau(alpha) - mu1)/s1)
    %
    % Fixed-FNR beta:
    %   tau(beta)  = mu1 + s1 * Phi^{-1}(beta)
    %   FPR(beta)  = 1 - Phi((tau(beta) - mu0)/s0)

    % --- Means & stds from data
    mu0 = z_stats.inter.mean;
    s0  = z_stats.inter.std;
    mu1 = z_stats.intra.mean;
    s1  = z_stats.intra.std;

    s1_adj = 0.6366; % Temporal Fisher-z spread, applied only to the intra class.
    assert(all(isfinite([mu0 mu1 s0 s1 s1_adj])) && all([s0 s1 s1_adj]>0), 'Invalid Gaussian model parameters.');

    % Sanity check
    if any(isnan([mu0,mu1,s0,s1,s1_adj])) || any([s0,s1,s1_adj] <= 0)
        tau_star    = NaN; eer = NaN; fpr_eer = NaN; fnr_eer = NaN;
        tau_star_ad = NaN; eer_adj = NaN;
        fpr_eer_ad  = NaN; fnr_eer_ad = NaN;
    else
        % --------- ORIGINAL (unadjusted) EER ----------
        tau_star = (mu0*s1 + mu1*s0) / (s0 + s1);
        z0 = (tau_star - mu0)/s0;
        z1 = (tau_star - mu1)/s1;
        fpr_eer = 1 - normcdf(z0);
        fnr_eer = normcdf(z1);
        %eer     = 0.5*(fpr_eer + fnr_eer);  % numerically identical here
        eer = normcdf((mu0 - mu1)/(s0 + s1));

        % --------- ADJUSTED EER (replace intra std by s1_adj) ----------
        tau_star_ad = (mu0*s1_adj + mu1*s0) / (s0 + s1_adj);
        z0_ad = (tau_star_ad - mu0)/s0;
        z1_ad = (tau_star_ad - mu1)/s1_adj;
        fpr_eer_ad = 1 - normcdf(z0_ad);
        fnr_eer_ad = normcdf(z1_ad);
        %eer_adj    = 0.5*(fpr_eer_ad + fnr_eer_ad);
        eer_adj = normcdf((mu0 - mu1)/(s0 + s1_adj));
    end

    % --------- Operating points for fixed FPR or FNR ----------
    % Retain the existing diagnostic operating points.
    alpha_targets = [1e-6];  % fixed FPR = alpha
    beta_targets  = [1e-6];  % fixed FNR = beta

    % ORIGINAL (uses s0, s1)
    ops_fixed_fpr = arrayfun(@(a) fixed_fpr_point(a, mu0, s0, mu1, s1), alpha_targets);
    ops_fixed_fnr = arrayfun(@(b) fixed_fnr_point(b, mu0, s0, mu1, s1), beta_targets);

    % ADJUSTED (uses s0, s1_adj)
    ops_fixed_fpr_adj = arrayfun(@(a) fixed_fpr_point(a, mu0, s0, mu1, s1_adj), alpha_targets);
    ops_fixed_fnr_adj = arrayfun(@(b) fixed_fnr_point(b, mu0, s0, mu1, s1_adj), beta_targets);

    % --------- Package outputs ----------
    eer_stats = struct();
    eer_stats.mu0 = mu0; eer_stats.sigma0 = s0;
    eer_stats.mu1 = mu1; eer_stats.sigma1 = s1;
    eer_stats.sigma1_adj = s1_adj;

    r_threshold = tanh(tau_star);
    r_threshold_adj = tanh(tau_star_ad);
    empirical = calculate_empirical_threshold_classification( ...
        intra_correlations, inter_correlations, r_threshold);
    empirical_adj = calculate_empirical_threshold_classification( ...
        intra_correlations, inter_correlations, r_threshold_adj);

    eer_stats.EER = struct( ...
        'tau', tau_star, 'r_threshold', r_threshold, ...
        'FPR', fpr_eer, 'FNR', fnr_eer, 'rate', eer, ...
        'empirical', empirical);
    eer_stats.EER_ADJ = struct( ...
        'tau', tau_star_ad, 'r_threshold', r_threshold_adj, ...
        'FPR', fpr_eer_ad, 'FNR', fnr_eer_ad, 'rate', eer_adj, ...
        'empirical', empirical_adj);

    % Fixed-FPR tables
    eer_stats.fixed_FPR = struct( ...
        'targets', alpha_targets, ...
        'original', ops_fixed_fpr, ...
        'adjusted', ops_fixed_fpr_adj);

    % Fixed-FNR tables
    eer_stats.fixed_FNR = struct( ...
        'targets', beta_targets, ...
        'original', ops_fixed_fnr, ...
        'adjusted', ops_fixed_fnr_adj);

    print_eer_results(eer_stats,fileID);
end

% Calculate empirical threshold-classification metrics at one threshold.
function summary = calculate_empirical_threshold_classification( ...
        intra_correlations, inter_correlations, r_threshold)
    intra_all = intra_correlations(:);
    inter_all = inter_correlations(:);
    intra = intra_all(isfinite(intra_all));
    inter = inter_all(isfinite(inter_all));

    summary.N_intra_total = numel(intra_all);
    summary.N_inter_total = numel(inter_all);
    summary.N_intra_valid = numel(intra);
    summary.N_inter_valid = numel(inter);
    summary.N_intra_nonfinite = summary.N_intra_total - summary.N_intra_valid;
    summary.N_inter_nonfinite = summary.N_inter_total - summary.N_inter_valid;

    if isempty(intra), summary.min_intra_r = NaN;
    else, summary.min_intra_r = min(intra); end
    if isempty(inter), summary.max_inter_r = NaN;
    else, summary.max_inter_r = max(inter); end

    if ~isfinite(r_threshold)
        summary.intra_at_or_above = NaN;
        summary.intra_below = NaN;
        summary.inter_at_or_above = NaN;
        summary.inter_below = NaN;
        summary.total_errors = NaN;
        return;
    end

    % The full-precision threshold is used here. Rounding is only for output.
    summary.intra_at_or_above = sum(intra >= r_threshold);
    summary.intra_below = sum(intra < r_threshold);
    summary.inter_at_or_above = sum(inter >= r_threshold);
    summary.inter_below = sum(inter < r_threshold);
    summary.total_errors = summary.intra_below + summary.inter_at_or_above;
end

% Calculate the Gaussian operating point for a fixed false-positive rate.
function out = fixed_fpr_point(alpha, mu0, s0, mu1, s1)
    % tau that yields FPR = alpha
    tau = mu0 + s0 * norminv(1 - alpha);
    fnr = normcdf((tau - mu1)/s1);
    out = struct('tau', tau, 'FPR', alpha, 'FNR', fnr);
end

% ===== Helper: fixed FNR beta (returns struct with tau and resulting FPR) =====
% Calculate the Gaussian operating point for a fixed false-negative rate.
function out = fixed_fnr_point(beta, mu0, s0, mu1, s1)
    % tau that yields FNR = beta
    tau = mu1 + s1 * norminv(beta);
    fpr = 1 - normcdf((tau - mu0)/s0);
    out = struct('tau', tau, 'FNR', beta, 'FPR', fpr);
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID, varargin)
    message = sprintf(varargin{:});
    fprintf(1, '%s', message);
    fprintf(fileID, '%s', message);
end

