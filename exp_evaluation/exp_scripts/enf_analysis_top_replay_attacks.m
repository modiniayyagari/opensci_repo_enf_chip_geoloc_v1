%% ENF Replay Attacks
% Purpose:
%   Evaluate the fixed signal-level stale-reference replay experiment.
%
% Experiment:
%   Main paper Section 6.4 and Figure 19.
%
% Analysis:
%   Compare eight authentic ambient targets with strictly older same-trial
%   mains references across 124 replay comparisons and eight controls.
%
% Inputs:
%   exp_evaluation/exp_inputs/TREND; eight fixed targets, eight controls, 124
%   older-reference pairings, and a separate T02 figure target.
%
% Outputs:
%   Raw and summary CSVs plus overlay PNG/SVG/FIG files under
%   exp_evaluation/exp_results/replay_attack_resilience and the script log
%   under exp_evaluation/exp_logs.
%
% Dependencies:
%   Shared exp_validation/exp_scripts/proc_enf_analysis.p; Signal Processing
%   and Statistics toolboxes.
%
% Usage:
%   Run from any working directory; preserve target selection, scheduled
%   ordering, threshold, and representative T02 recording.


%% STEP_1) Script Configuration
% Resolve repository-local input/shared roots and preserve all fixed replay settings.

% Repository and Input Paths
close all; clear; clc;
script_dir = fileparts(mfilename('fullpath'));
evaluation_dir = fileparts(script_dir);
repository_dir = fileparts(evaluation_dir);
shared_dir = fullfile(repository_dir,'exp_validation','exp_scripts');
addpath(shared_dir);
assert(strcmpi(which('proc_enf_analysis'),fullfile(shared_dir,'proc_enf_analysis.p')), ...
    'Replay:ProcessorPath','Unexpected shared ENF processor on MATLAB path.');
config = struct();
standardization_timer = tic;
config.baseDir = fullfile(evaluation_dir,'exp_inputs','TREND');
config.file_1_name_base = 'mains_pow_trace_ac';
config.file_2_name_base = 'fpga_em_trace_dc';

% ENF Extraction Parameters
config.nominal_freq = 60;
config.harmonics = (1:7)*config.nominal_freq;
config.frame_size = 8000;
config.overlap_size = 0;
config.nfft = 32768;
config.analysis_fs = 44100/7/6;

% Replay Detection Threshold
% Accept a comparison when its correlation is at least the fixed 0.9217 threshold.
config.threshold = 0.9217;

% Fixed Replay Target Selection
% Analyze eight targets against strictly older, same-trial reference recordings.
config.replay_target_specs = {
    'WK01','WDAY','THUR','AFTN','T01';
    'WK01','WEND','SAT','EMRN','T02';
    'WK01','WEND','SAT','EVEN','T03';
    'WK01','WEND','SUN','MORN','T04';
    'WK01','WEND','SUN','EVEN','T05';
    'WK02','WDAY','WED','EMRN','T01';
    'WK02','WEND','SAT','MORN','T02';
    'WK02','WEND','SUN','AFTN','T03'};

% Representative Figure Selection
% Keep the separate T02 figure target distinct from the eight pooled targets.
config.replay_overlay_target_spec = {'WK02','WEND','SUN','AFTN','T02'};
config.overlay_reference_specs = {
    'WK02','WEND','SUN','EMRN','T02';
    'WK02','WDAY','THUR','AFTN','T02';
    'WK01','WEND','SUN','AFTN','T02';
    'WK01','WDAY','WED','AFTN','T02'};

% Result and Log Paths
log_dir = fullfile(evaluation_dir,'exp_logs');
results_dir = fullfile(evaluation_dir,'exp_results','replay_attack_resilience');

%% STEP_2) Setup: Logging and Output Directories
% Create output directories and initialize console/file logging with cleanup.
if ~isfolder(log_dir), mkdir(log_dir); end
if ~isfolder(results_dir), mkdir(results_dir); end
[~,script_name] = fileparts(mfilename('fullpath'));
fileID = fopen(fullfile(log_dir,[script_name '_log.txt']),'w');
assert(fileID~=-1,'Replay:Log','Cannot open replay log.');
cleanup_log = onCleanup(@() fclose(fileID));
log_both(fileID, '%s\nENF REPLAY ATTACKS\n%s\n', repmat('%',1,85), repmat('%',1,85));
log_both(fileID, '\nSTEP_1) SCRIPT CONFIGURATION\n%s\n', repmat('%',1,85));
log_both(fileID, '\nSTEP_2) SETUP: LOGGING AND OUTPUT DIRECTORIES\n%s\n', repmat('%',1,85));
log_both(fileID,['\nEXPERIMENT CONFIGURATION\n' ...
    '    Dataset: exp_evaluation/exp_inputs/TREND/\n' ...
    '    Experiment: signal-level older-reference replay\n' ...
    '    Target recordings: 8; expected replay comparisons: 124; authentic controls: 8\n' ...
    '    Ordering: WK01, WK02; WED, THU, SAT, SUN; EMRN, MORN, AFTN, EVEN\n' ...
    '    Require reference ordinal < target ordinal; same trial only.\n' ...
    '    Ordering follows scheduled slots; acquisition timestamps are not independently verified.\n' ...
    '    Weighted-energy method 1, gamma=3; 60 Hz; harmonics 60:60:420 Hz\n' ...
    '    Frame=8000 samples; overlap=0; FFT setting=32768\n' ...
    '    WAV preprocessing: 44100 -> 1050 Hz; zero-lag Pearson r; lag optimization disabled\n' ...
    '    Accept if r >= %.6f\n'],config.threshold);
%% STEP_3) Input Discovery and Validation
% Build the deterministic manifest and validate every required WAV.
try
    log_both(fileID, '\nSTEP_3) INPUT DISCOVERY AND VALIDATION\n%s\n', repmat('%',1,85));
    [raw,targets,figure_target,figure_refs,required_files] = build_manifest(config);
    validate_inputs(config,required_files);
    log_both(fileID,['    Expected/validated targets: 8/8\n' ...
        '    Expected/validated stale-reference pairings: 124/124\n' ...
        '    Simultaneous authentic control pairings: 8\n' ...
        '    Invalid or duplicate comparisons: 0\n' ...
        '    Validated unique required WAV files: %d (mono, 44100 Hz, nominal 200 s, finite samples)\n' ...
        '    Older-reference counts: 6, 8, 11, 13, 15, 16, 25, 30\n'],numel(required_files));
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_4) ENF Extraction and Replay Comparisons
% Calculate all authentic and strictly older-reference zero-lag correlations.
try
    log_both(fileID, '\nSTEP_4) ENF EXTRACTION AND REPLAY COMPARISONS\n%s\n', repmat('%',1,85));
    target_results = repmat(replay_empty_result_struct(),8,1);
    authentic_controls = zeros(8,1);
    raw.AuthenticR = nan(124,1);
    raw.ReplayR = nan(124,1);
    raw.Threshold = repmat(config.threshold,124,1);
    raw.Accepted = false(124,1);
    for i=1:8
        target = char(targets(i));
        [authentic_controls(i),~,~] = run_pair(config,target,target);
        log_both(fileID,'\nTarget %d/8: %s\n    Authentic r = %.9f | %s\n', ...
            i,target,authentic_controls(i),verdict(authentic_controls(i)>=config.threshold));
        rows = find(raw.TargetIndex==i);
        log_both(fileID,'    Older references: %d\n',numel(rows));
        for j=1:numel(rows)
            k=rows(j);
            raw.AuthenticR(k)=authentic_controls(i);
            raw.ReplayR(k)=run_pair(config,target,char(raw.ReplayFolder(k)));
            raw.Accepted(k)=raw.ReplayR(k)>=config.threshold;
            log_both(fileID,'    %s | r = %.9f | %s\n',char(raw.ReplayFolder(k)), ...
                raw.ReplayR(k),verdict(raw.Accepted(k)));
        end
        r=raw.ReplayR(rows);
        result=replay_empty_result_struct();
        result.target_folder=targets(i);
        [~,leaf]=fileparts(target);
        result.leaf_folder=string(leaf);
        result.authentic_r=authentic_controls(i);
        result.replay_corrs=r;
        result.older_refs_available=numel(rows);
        result.n_replay=numel(rows);
        result.replay_mean=mean(r);
        result.replay_median=median(r);
        result.replay_std=std(r);
        result.replay_min=min(r);
        result.replay_max=max(r);
        target_results(i)=result;
        log_both(fileID,'    Complete: %d comparisons; accepted=%d; rejected=%d\n', ...
            numel(rows),sum(raw.Accepted(rows)),sum(~raw.Accepted(rows)));
    end
    assert(height(raw)==124 && all(isfinite(raw.ReplayR)) && numel(authentic_controls)==8, ...
        'Replay:Incomplete','Expected 124 finite replay results and eight authentic controls.');
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_5) Statistics and Attack Detection
% Pool the 124 raw correlations and apply the existing fixed acceptance rule.
try
    log_both(fileID, '\nSTEP_5) STATISTICS AND ATTACK DETECTION\n%s\n', repmat('%',1,85));
    summary_tbl=replay_build_target_summary_table(target_results);
    summary_tbl.Threshold=repmat(config.threshold,8,1);
    summary_tbl.AuthenticAccepted=authentic_controls>=config.threshold;
    summary_tbl.ReplayAccepted=zeros(8,1);
    for i=1:8
        summary_tbl.ReplayAccepted(i)=sum(raw.Accepted(raw.TargetIndex==i));
    end
    summary_tbl.ReplayRejected=summary_tbl.NReplay-summary_tbl.ReplayAccepted;
    log_both(fileID,'\nPOOLED REPLAY STATISTICS\n');
    print_stats(raw.ReplayR,fileID,'All 124 replay correlations (r)');
    log_both(fileID,'\nAUTHENTIC CONTROL STATISTICS\n');
    print_stats(authentic_controls,fileID,'Eight authentic controls (r)');
    accepted=sum(raw.Accepted);
    log_both(fileID,['\nATTACK DETECTION\n' ...
        '    Threshold: %.6f\n    Total replay comparisons: %d\n' ...
        '    Accepted replay attempts: %d\n    Rejected replay attempts: %d\n' ...
        '    Acceptance rate: %.6f%%\n    Rejection rate: %.6f%%\n' ...
        '    Maximum replay correlation: %.9f\n    Margin below threshold: %.9f\n' ...
        '    Authentic controls accepted: %d/8; rejected: %d/8\n'], ...
        config.threshold,height(raw),accepted,124-accepted,100*accepted/124, ...
        100*(124-accepted)/124,max(raw.ReplayR),config.threshold-max(raw.ReplayR), ...
        sum(summary_tbl.AuthenticAccepted),sum(~summary_tbl.AuthenticAccepted));
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_6) Representative Replay Figure
% Extract and plot the unchanged separate T02 example with its verified 1050 Hz time axis.
try
    log_both(fileID, '\nSTEP_6) REPRESENTATIVE REPLAY FIGURE\n%s\n', repmat('%',1,85));
    log_both(fileID,'\nFIGURE GENERATION\n    Representative target: %s\n',char(figure_target));
    log_both(fileID,'    Representative figure uses an independent T02 recording, separate from the eight pooled replay targets.\n');
    [traces.r_authentic,traces.enf_ambient,traces.enf_authentic]= ...
        run_pair(config,char(figure_target),char(figure_target));
    log_both(fileID,'    Authentic r = %.9f\n',traces.r_authentic);
    traces.sel_enf=cell(4,1);
    traces.sel_corrs=zeros(4,1);
    traces.sel_labels=cell(4,1);
    for i=1:4
        [traces.sel_corrs(i),ambient,traces.sel_enf{i}]= ...
            run_pair(config,char(figure_target),char(figure_refs(i)));
        assert(isequal(ambient,traces.enf_ambient),'Replay:Figure','Ambient ENF changed between pairs.');
        meta=replay_parse_folder_metadata(figure_refs(i));
        traces.sel_labels{i}=sprintf('%s/%s/%s/T02',meta.week,meta.day,meta.slot);
        log_both(fileID,'    Reference %s | r = %.9f\n',char(figure_refs(i)),traces.sel_corrs(i));
    end
    traces.frame_size_samp=config.frame_size;
    traces.overlap_samp=config.overlap_size;
    traces.analysis_fs=config.analysis_fs;
    log_both(fileID,'    Verified analysis Fs: %.6f Hz; plotting hop: %.12f s\n', ...
        config.analysis_fs,(config.frame_size-config.overlap_size)/config.analysis_fs);
    plot_replay_attack_enf_overlay(traces,results_dir,fileID);
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% STEP_7) Result Export and Execution Summary
% Export the existing two CSVs and report exact comparison counts and decisions.
try
    log_both(fileID, '\nSTEP_7) RESULT EXPORT AND EXECUTION SUMMARY\n%s\n', repmat('%',1,85));
    writetable(raw,fullfile(results_dir,'replay_attack_raw_results.csv'));
    writetable(summary_tbl,fullfile(results_dir,'replay_attack_target_summary.csv'));
    log_both(fileID,['\nRESULT FILES\n' ...
        '    exp_evaluation/exp_results/replay_attack_resilience/replay_attack_raw_results.csv (124 rows)\n' ...
        '    exp_evaluation/exp_results/replay_attack_resilience/replay_attack_target_summary.csv (8 rows)\n' ...
        '    exp_evaluation/exp_results/replay_attack_resilience/replay_attack_enf_overlay.{png,svg,fig}\n' ...
        '    exp_evaluation/exp_logs/enf_analysis_top_replay_attacks_log.txt\n' ...
        '\nFINAL\n    Total replay comparisons: 124\n    Accepted: %d\n    Rejected: %d\n' ...
        '    All analysis complete.\n'],accepted,124-accepted);
    log_both(fileID, 'Execution status: SUCCESS\nTotal execution time: %.3f s\n', toc(standardization_timer));
    clear cleanup_log;
catch execution_error
    log_both(fileID, 'Execution status: FAILED\n%s\n', execution_error.message);
    clear cleanup_log;
    rethrow(execution_error);
end

%% Local Functions
% Build the eight-target replay manifest and separate figure selection.
function [raw,targets,figure_target,figure_refs,required] = build_manifest(config)
    assert(size(config.replay_target_specs,1)==8,'Replay:Targets','Require eight targets.');
    targets=strings(8,1);
    required=strings(0,1);
    records=cell(0,13);
    expected=[6 8 11 13 15 16 25 30];
    for i=1:8
        folder=replay_spec_to_subfolder(config,config.replay_target_specs(i,:));
        target=relative_folder(config,folder);
        targets(i)=target;
        tm=replay_parse_folder_metadata(target);
        trial=config.replay_target_specs{i,5};
        assert(isfinite(tm.ordinal),'Replay:Metadata','Invalid target metadata: %s',target);
        required=[required; fullfile(target,[config.file_2_name_base '.wav']); ...
            fullfile(target,[config.file_1_name_base '.wav'])]; %#ok<AGROW>
        bank=replay_build_reference_bank(config,trial);
        count=0;
        for j=1:numel(bank)
            replay=relative_folder(config,fileparts(bank{j}));
            rm=replay_parse_folder_metadata(replay);
            [~,reference_trial]=fileparts(char(replay));
            assert(isfinite(rm.ordinal) && strcmp(reference_trial,trial), ...
                'Replay:Metadata','Invalid same-trial reference: %s',replay);
            if rm.ordinal<tm.ordinal
                count=count+1;
                records(end+1,:)={i,target,replay,tm.week,tm.day,tm.slot,string(trial), ...
                    rm.week,rm.day,rm.slot,string(reference_trial),tm.ordinal,rm.ordinal}; %#ok<AGROW>
                required(end+1,1)=fullfile(replay,[config.file_1_name_base '.wav']); %#ok<AGROW>
            end
        end
        assert(count==expected(i),'Replay:Count','Unexpected reference count for target %d.',i);
    end
    raw=cell2table(records,'VariableNames',{'TargetIndex','TargetFolder','ReplayFolder', ...
        'TargetWeek','TargetDay','TargetTimeOfDay','TargetTrial','ReplayWeek','ReplayDay', ...
        'ReplayTimeOfDay','ReplayTrial','TargetOrdinal','ReplayOrdinal'});
    assert(numel(unique(targets))==8 && height(raw)==124 && ...
        numel(unique(raw.TargetFolder+"|"+raw.ReplayFolder))==124 && ...
        all(raw.ReplayOrdinal<raw.TargetOrdinal) && all(raw.TargetTrial==raw.ReplayTrial), ...
        'Replay:Manifest','Invalid replay manifest.');
    figure_target=relative_folder(config,replay_spec_to_subfolder(config,config.replay_overlay_target_spec));
    assert(~any(targets==figure_target),'Replay:Figure','Figure target must remain separate.');
    required=[required;fullfile(figure_target,[config.file_2_name_base '.wav']); ...
        fullfile(figure_target,[config.file_1_name_base '.wav'])];
    figure_refs=strings(4,1);
    fm=replay_parse_folder_metadata(figure_target);
    for i=1:4
        figure_refs(i)=relative_folder(config,replay_spec_to_subfolder(config,config.overlay_reference_specs(i,:)));
        rm=replay_parse_folder_metadata(figure_refs(i));
        assert(rm.ordinal<fm.ordinal && strcmp(config.overlay_reference_specs{i,5},'T02'), ...
            'Replay:Figure','Representative reference must be strictly older and trial T02.');
        required(end+1,1)=fullfile(figure_refs(i),[config.file_1_name_base '.wav']); %#ok<AGROW>
    end
    assert(numel(unique(figure_refs))==4,'Replay:Figure','Duplicate figure references.');
    required=unique(required,'stable');
end

% Convert an absolute dataset folder to its repository-relative form.
function relative = relative_folder(config,folder)
    prefix=[config.baseDir filesep];
    assert(strncmp(folder,prefix,numel(prefix)),'Replay:Path','Folder outside TREND.');
    relative=string(strrep(folder(numel(prefix)+1:end),'\','/'));
end

% Verify all required replay WAV inputs and their recording metadata.
function validate_inputs(config,required)
    for i=1:numel(required)
        id=char(required(i));
        path=fullfile(config.baseDir,id);
        assert(isfile(path),'Replay:MissingInput','Missing required WAV: %s',id);
        info=audioinfo(path);
        assert(info.SampleRate==44100 && info.NumChannels==1, ...
            'Replay:WAVFormat','Expected mono 44100 Hz WAV: %s',id);
        assert(abs(info.TotalSamples-200*info.SampleRate)<=1, ...
            'Replay:Duration','Expected nominal 200-second WAV: %s (%.9f s).',id,info.Duration);
        [samples,fs]=audioread(path);
        assert(fs/7/6==config.analysis_fs && numel(samples)==info.TotalSamples && ...
            all(isfinite(samples(:))),'Replay:Samples','Invalid WAV samples: %s',id);
    end
end

% Extract one target/reference ENF pair and calculate zero-lag correlation.
function [r,enf_ambient,enf_reference] = run_pair(config,target,reference)
    ambient=fullfile(config.baseDir,target,[config.file_2_name_base '.wav']);
    mains=fullfile(config.baseDir,reference,[config.file_1_name_base '.wav']);
    [matched,lag_sec,lag_frames,r,enf_ambient,enf_reference]=proc_enf_analysis( ...
        ambient,mains,config.nfft,config.frame_size,config.overlap_size, ...
        config.harmonics,config.nominal_freq,config.harmonics,config.nominal_freq, ...
        1,config.nominal_freq,config.harmonics,1,config.nominal_freq,config.harmonics, ...
        config.file_1_name_base,config.file_2_name_base,false,'Quiet',true,'lagOptEnable',false);
    assert(isscalar(r) && isfinite(r) && r>=-1 && r<=1 && isequal(matched,r) && ...
        lag_sec==0 && lag_frames==0,'Replay:Correlation', ...
        'Invalid zero-lag correlation: %s versus %s',target,reference);
    assert(numel(enf_ambient)>=2 && numel(enf_reference)>=2 && ...
        all(isfinite(enf_ambient(:))) && all(isfinite(enf_reference(:))), ...
        'Replay:ENF','Invalid ENF estimates: %s versus %s',target,reference);
end

% Resolve the validated Thursday directory token used by the dataset.
function token = replay_get_thursday_token(config)
    token='THUR';
    for week={'WK01','WK02'}
        assert(isfolder(fullfile(config.baseDir,week{1},'WDAY',token)), ...
            'Replay:Thursday','Missing THUR directory in %s.',week{1});
    end
end

% Convert a Boolean acceptance result to its report label.
function label = verdict(accepted)
    if accepted, label='ACCEPT'; else, label='REJECT'; end
end

% Calculate and report descriptive correlation statistics.
function print_stats(x,fileID,label)
    assert(~isempty(x) && all(isfinite(x(:))),'Replay:Statistics','Nonfinite required results.');
    n=numel(x); sem=std(x)/sqrt(n); margin=tinv(0.975,n-1)*sem;
    log_both(fileID,'%-20s | %s\n%-20s | %20d\n','Statistic',label,'Count (N)',n);
    names={'Mean','Median','Std. Dev.','Variance','Skewness','Kurtosis','Std. Error','Min','Max'};
    values=[mean(x),median(x),std(x),var(x),skewness(x),kurtosis(x),sem,min(x),max(x)];
    for i=1:numel(names)
        log_both(fileID,'%-20s | %20.9f\n',names{i},values(i));
    end
    log_both(fileID,'%-20s | [%.9f, %.9f]\n','95% CI',mean(x)-margin,mean(x)+margin);
end

% Write the same formatted message to the Command Window and log file.
function log_both(fileID,varargin)
    fprintf(1,varargin{:});
    fprintf(fileID,varargin{:});
end

% Map scheduled week, day, and time metadata to a deterministic ordinal.
function ordinal = replay_get_time_ordinal(week_str, ~, day_str, slot_str)
    week_str = upper(char(week_str));
    day_str  = upper(char(day_str));
    slot_str = upper(char(slot_str));

    week_idx = NaN;
    switch week_str
        case 'WK01'
            week_idx = 1;
        case 'WK02'
            week_idx = 2;
    end

    day_idx = NaN;
    switch day_str
        case 'WED'
            day_idx = 1;
        case {'THU', 'THUR'}
            day_idx = 2;
        case 'SAT'
            day_idx = 3;
        case 'SUN'
            day_idx = 4;
    end

    slot_idx = NaN;
    switch slot_str
        case 'EMRN'
            slot_idx = 1;
        case 'MORN'
            slot_idx = 2;
        case 'AFTN'
            slot_idx = 3;
        case 'EVEN'
            slot_idx = 4;
    end

    if ~isfinite(week_idx) || ~isfinite(day_idx) || ~isfinite(slot_idx)
        ordinal = NaN;
        return;
    end

    ordinal = ((week_idx - 1) * 4 + (day_idx - 1)) * 4 + slot_idx;
end

% Build the ordered bank of same-trial reference recordings.
function all_ref_wavs = replay_build_reference_bank(config, leaf_folder)
    leaf_folder = char(leaf_folder);
    ref_name   = [config.file_1_name_base '.wav'];
    weeks      = {'WK01', 'WK02'};
    thu_token  = replay_get_thursday_token(config);
    day_paths  = {'WEND/SAT', 'WEND/SUN', 'WDAY/WED', ['WDAY/' thu_token]};
    time_slots = {'EMRN', 'MORN', 'AFTN', 'EVEN'};

    all_ref_wavs = cell(0,1);
    for wi = 1:numel(weeks)
        for di = 1:numel(day_paths)
            for ti = 1:numel(time_slots)
                p = fullfile(config.baseDir, weeks{wi}, day_paths{di}, time_slots{ti}, leaf_folder, ref_name);
                all_ref_wavs{end+1,1} = p; %#ok<AGROW>
            end
        end
    end
end

% Parse scheduled metadata from one TREND recording folder.
function meta = replay_parse_folder_metadata(folder_path)
    tokens = upper(regexp(char(folder_path), '[^\\/]+', 'match'));

    week = 'NA';
    if any(strcmp(tokens, 'WK01'))
        week = 'WK01';
    elseif any(strcmp(tokens, 'WK02'))
        week = 'WK02';
    end

    day_type = 'NA';
    if any(strcmp(tokens, 'WDAY'))
        day_type = 'WDAY';
    elseif any(strcmp(tokens, 'WEND'))
        day_type = 'WEND';
    end

    day = 'NA';
    if any(strcmp(tokens, 'WED'))
        day = 'WED';
    elseif any(strcmp(tokens, 'THU')) || any(strcmp(tokens, 'THUR'))
        day = 'THU';
    elseif any(strcmp(tokens, 'SAT'))
        day = 'SAT';
    elseif any(strcmp(tokens, 'SUN'))
        day = 'SUN';
    end

    slot = 'NA';
    if any(strcmp(tokens, 'EMRN'))
        slot = 'EMRN';
    elseif any(strcmp(tokens, 'MORN'))
        slot = 'MORN';
    elseif any(strcmp(tokens, 'AFTN'))
        slot = 'AFTN';
    elseif any(strcmp(tokens, 'EVEN'))
        slot = 'EVEN';
    end

    meta = struct( ...
        'week', string(week), ...
        'day_type', string(day_type), ...
        'day', string(day), ...
        'slot', string(slot), ...
        'ordinal', replay_get_time_ordinal(week, day_type, day, slot));
end

% Convert one fixed target specification to its dataset subfolder.
function subfolder = replay_spec_to_subfolder(config, spec)
    week      = char(spec{1});
    day_type  = char(spec{2});
    day_token = upper(char(spec{3}));
    time_slot = char(spec{4});
    leaf      = char(spec{5});

    if strcmp(day_token, 'THU') || strcmp(day_token, 'THUR')
        day_token = replay_get_thursday_token(config);
    end

    subfolder = fullfile(config.baseDir, week, day_type, day_token, time_slot, leaf);
end

% Create an empty replay-target result with the established schema.
function result = replay_empty_result_struct()
    result = struct( ...
        'target_folder', "", ...
        'leaf_folder', "", ...
        'authentic_r', NaN, ...
        'replay_corrs', [], ...
        'older_refs_available', 0, ...
        'n_replay', 0, ...
        'replay_mean', NaN, ...
        'replay_median', NaN, ...
        'replay_std', NaN, ...
        'replay_min', NaN, ...
        'replay_max', NaN);
end

% Build the eight-row per-target replay summary table.
function summary_tbl = replay_build_target_summary_table(target_results)
    n = numel(target_results);
    summary_tbl = table('Size', [n, 10], ...
                        'VariableTypes', {'string','string','double','double','double','double','double','double','double','double'}, ...
                        'VariableNames', {'TargetFolder','LeafFolder','AuthenticR','OlderRefsAvailable','NReplay','ReplayMean','ReplayMedian','ReplayStd','ReplayMin','ReplayMax'});

    for i = 1:n
        summary_tbl.TargetFolder(i)        = string(target_results(i).target_folder);
        summary_tbl.LeafFolder(i)          = string(target_results(i).leaf_folder);
        summary_tbl.AuthenticR(i)          = target_results(i).authentic_r;
        summary_tbl.OlderRefsAvailable(i) = target_results(i).older_refs_available;
        summary_tbl.NReplay(i)             = target_results(i).n_replay;
        summary_tbl.ReplayMean(i)          = target_results(i).replay_mean;
        summary_tbl.ReplayMedian(i)        = target_results(i).replay_median;
        summary_tbl.ReplayStd(i)           = target_results(i).replay_std;
        summary_tbl.ReplayMin(i)           = target_results(i).replay_min;
        summary_tbl.ReplayMax(i)           = target_results(i).replay_max;
    end
end

% Generate and export the representative replay ENF overlay.
function plot_replay_attack_enf_overlay(traces, results_dir, fileID)


    hop_sec = (traces.frame_size_samp - traces.overlap_samp) / traces.analysis_fs;

    N = numel(traces.enf_ambient);
    if ~isempty(traces.enf_authentic)
        N = min(N, numel(traces.enf_authentic));
    end
    for m = 1:numel(traces.sel_enf)
        if ~isempty(traces.sel_enf{m})
            N = min(N, numel(traces.sel_enf{m}));
        end
    end
    assert(N >= 2 && numel(traces.sel_enf)==4,'Require six complete ENF series for the replay figure.');

    t        = (0:N-1) * hop_sec;          % time axis in seconds
    enf_amb  = traces.enf_ambient(1:N);
    enf_auth = traces.enf_authentic(1:N);

    replay_specs = {
        [0.80 0.00 0.80], '-.', 1.6;   % magenta  dash-dot
        [0.00 0.50 0.00], ':',  2.0;   % dark green dotted
        [0.50 0.50 0.50], '--', 1.5;   % gray     dashed
        [0.90 0.48 0.00], '-.',  1.6;  % orange   dash-dot
    };

    fig = figure('Name', 'Replay_Attack_ENF_Overlay', ...
                 'Visible', 'off', ...
                 'Units',   'pixels', ...
                 'Position', [100, 100, 1480, 720]);

    ax = axes('Parent', fig, ...
              'Units',  'normalized', ...
              'Position', [0.07, 0.12, 0.60, 0.80]);
    hold(ax, 'on');

    n_replay = min(numel(traces.sel_enf), size(replay_specs, 1));
    leg_h    = gobjects(2 + n_replay, 1);
    leg_lbl  = cell(2 + n_replay, 1);

    for m = 1:n_replay
        assert(~isempty(traces.sel_enf{m}),'Missing representative replay ENF series.');
        enf_m = traces.sel_enf{m}(1:N);
        col   = replay_specs{m, 1};
        ls    = replay_specs{m, 2};
        lw    = replay_specs{m, 3};
        leg_h(2 + m) = plot(ax, t, enf_m, ls, ...
            'Color', col, 'LineWidth', lw);
        leg_lbl{2 + m} = sprintf('Replay: %s ($r = %.3f$)', ...
            traces.sel_labels{m}, traces.sel_corrs(m));
    end

    leg_h(2) = plot(ax, t, enf_auth, '--', ...
        'Color', [0.12 0.47 0.71], 'LineWidth', 1.8);
    leg_lbl{2} = sprintf('Authentic Match ($r = %.3f$)', traces.r_authentic);

    leg_h(1) = plot(ax, t, enf_amb, '-', ...
        'Color', [0.85 0.00 0.00], 'LineWidth', 2.5);
    leg_lbl{1} = 'Ambient Target (Device Trace)';

    hold(ax, 'off');

    set(ax, ...
        'FontName',  'Times New Roman', ...
        'FontSize',  10, ...
        'Box',       'off', ...
        'LineWidth', 0.8, ...
        'Layer',     'top', ...
        'XGrid',     'on', ...
        'YGrid',     'on', ...
        'GridColor', [0.78 0.78 0.78], ...
        'GridAlpha', 0.75, ...
        'TickDir',   'out', ...
        'XMinorGrid','off', ...
        'YMinorGrid','off');

    xlabel(ax, 'Time (s)', ...
        'FontName', 'Times New Roman', 'FontSize', 11);
    ylabel(ax, 'Instantaneous ENF Value (Hz)', ...
        'FontName', 'Times New Roman', 'FontSize', 11);
    title(ax, 'ENF Replay Attack: Intra-Correlation Resilience Test', ...
        'FontName', 'Times New Roman', 'FontSize', 11, 'FontWeight', 'normal');

    xlim(ax, [0, t(end)]);

    yvals = [enf_amb(:); enf_auth(:)];
    for m = 1:n_replay
        if ~isempty(traces.sel_enf{m})
            yvals = [yvals; traces.sel_enf{m}(1:N)]; %#ok<AGROW>
        end
    end
    assert(all(isfinite(yvals)),'Nonfinite ENF values in replay figure.');
    if isempty(yvals)
        ymin = 59.97;
        ymax = 60.01;
        step = 0.01;
    else
        yrange = max(yvals) - min(yvals);
        pad    = max(0.001, 0.08 * yrange);
        if yrange <= 0.02
            step = 0.002;
        elseif yrange <= 0.05
            step = 0.005;
        else
            step = 0.01;
        end
        ymin = floor((min(yvals) - pad) / step) * step;
        ymax = ceil((max(yvals) + pad) / step) * step;
        if ymin >= ymax
            ymin = ymin - step;
            ymax = ymax + step;
        end
    end
    ylim(ax, [ymin ymax]);
    set(ax, 'YTick', ymin:step:ymax);

    valid_mask = arrayfun(@(h) isvalid(h) && ...
        ~isa(h, 'matlab.graphics.GraphicsPlaceholder'), leg_h);
    leg = legend(ax, leg_h(valid_mask), leg_lbl(valid_mask), ...
        'Location',    'eastoutside', ...
        'Interpreter', 'latex', ...
        'FontName',    'Times New Roman', ...
        'FontSize',    9, ...
        'Box',         'on', ...
        'EdgeColor',   [0.75 0.75 0.75]);
    leg.Position(1) = 0.71;   % nudge legend to the right margin

    if ~exist(results_dir, 'dir'), mkdir(results_dir); end
    fn = fullfile(results_dir, 'replay_attack_enf_overlay');
    saveas(fig, [fn '.png']);
    saveas(fig, [fn '.svg']);
    savefig(fig, [fn '.fig']);
    close(fig);

    log_both(fileID,'    Saved exp_evaluation/exp_results/replay_attack_resilience/replay_attack_enf_overlay.{png,svg,fig}\n');
end



