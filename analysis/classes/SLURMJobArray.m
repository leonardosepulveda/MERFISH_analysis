classdef SLURMJobArray < handle
% ------------------------------------------------------------------------
% jobArrayObj = SLURMJobArray(varargin)
%--------------------------------------------------------------------------
% Jeffrey Moffitt
% lmoffitt@mcb.harvard.edu
% September 21, 2017
%--------------------------------------------------------------------------
% Copyright Presidents and Fellows of Harvard College, 2018.
%--------------------------------------------------------------------------
% This class is a wrapper around an array of SLURMJob objects, allowing coordination of a set of related jobs

% -------------------------------------------------------------------------
% Define properties
% -------------------------------------------------------------------------
properties
   verbose = true       % Control the verbosity of the class 
end

properties (SetAccess=protected)
    % Properties that describe the job array
    name = ''           % Name of the job array
    numJobs = 0         % Number of jobs
    
    % The jobs
    jobs                % The jobs in the array
    
    % Job array status
    completed = false;              % Whether or not the job array is completed
    submitted = false;              % Whether or not the job array is running
    failed = false;                 % Whether or not the job array has failed
    
    % Triggers for signals from contained jobs 
    jobSubmittedListeners   % Listeners to the job array submitted events
    jobCompletedListeners   % Listeners to the job array complete events
    jobFailedListeners      % Listeners to the job array failed events
    
    % Triggers for external events 
    jobSubmitListeners      % Listeners to control when to submit the job
    submitJobFlags          % Flags to record triggered listeners
    
    % Jobs status
    jobsSubmitted       % Boolean array marking whether a job has been submitted
    jobsCompleted       % Boolean array marking whether a job is completed
    jobsFailed          % Boolean array marking whether a job failed
    
    % Information on job array progress
    arrayTimer          % Timer to measure duration of job array
    startTime           % The time at which the array was submitted
    endTime             % The time at which the array ended
    duration = 0        % The total duration (in s) of the job array
end

% -------------------------------------------------------------------------
% Define events
% -------------------------------------------------------------------------
events
    JobArraySubmitted            % Signal the array as submitted
    JobArrayComplete             % Signal the array as completed
    JobArrayFailed               % Signal the array as failed
end

% -------------------------------------------------------------------------
% Public Methods
% -------------------------------------------------------------------------
methods
    
    % -------------------------------------------------------------------------
    % Define constructor
    % -------------------------------------------------------------------------
    function obj = SLURMJobArray(jobs, varargin)
        % This class is a wrapper around a set of related SLURM jobs.  Its
        % job is to listen to the events generated by these jobs,
        % accumulate completed/failed events, and trigger additional events
        % that other jobs/job arrays can use
        
        % -------------------------------------------------------------------------
        % Parse variable inputs
        % -------------------------------------------------------------------------
        % Define defaults
        defaults = cell(0,3); 
        
        % Basic array properties
        defaults(end+1,:) = {'name', ...
            'string', ''};
        defaults(end+1,:) = {'verbose', ...
            'boolean', false};
        
        % Create parameters structure
        parameters = ParseVariableArguments(varargin, defaults, mfilename);
        
        % Pass fields to new object
        foundFields = fields(parameters);
        for f=1:length(foundFields)
            obj.(foundFields{f}) = parameters.(foundFields{f});
        end
        
        % Return empty object          
        if nargin < 1
            return;
        end
        
        % -------------------------------------------------------------------------
        % Check necessary input
        % -------------------------------------------------------------------------
        if ~strcmp(class(jobs), 'SLURMJob')
            error('matlabFunctions:invalidInput', ...
                'The provided jobs must be instances of SLURMJob');
        end
        
        % -------------------------------------------------------------------------
        % Add jobs
        % -------------------------------------------------------------------------
        for j=1:length(jobs)
            obj.AddJob(jobs(j));
        end
        
        % -------------------------------------------------------------------------
        % Register job array
        % -------------------------------------------------------------------------
        obj.RegisterJobArray(obj)
        
    end
    
    % -------------------------------------------------------------------------
    % Submit jobs
    % -------------------------------------------------------------------------
    function Submit(obj)
        % Submit all jobs in the job array
        
        % Display progress
        if obj.verbose
            PageBreak();
            disp(['Submitting: ' obj.name]);
            disp(['... at ' datestr(now)]);
            obj.arrayTimer = tic;
        end
        
        if ~obj.submitted
            % Submit jobs
            for j=1:obj.numJobs
                obj.jobs(j).Submit();
            end

            % Mark array as submitted
            obj.submitted = true;
        end
        
        % Record time string
        obj.startTime = datetime('now');
    end
    
    % -------------------------------------------------------------------------
    % Resubmit the job array
    % -------------------------------------------------------------------------
    function Resubmit(obj)
        % Resubmit all jobs in the job array
        
        % Display progress
        if obj.verbose
            PageBreak();
            disp(['Resubmitting: ' obj.name]);
            disp(['... at ' datestr(now)]);
            obj.arrayTimer = tic;
        end
        
        % Remove the job submitted flag
        obj.completed = false;             
        obj.submitted = false;              
        obj.failed = false;                 

        obj.jobsSubmitted(1:end) = false;
        obj.jobsCompleted(1:end) = false;      
        obj.jobsFailed(1:end) = false; 
        
        % Submit jobs
        for j=1:obj.numJobs
            obj.jobs(j).Resubmit();
        end

        % Mark array as submitted
        obj.submitted = true;
        
        % Record time string
        obj.startTime = datetime('now');
    end

    
    % -------------------------------------------------------------------------
    % Cancel jobs
    % -------------------------------------------------------------------------
    function Cancel(obj)
        % Cancel all jobs in the job array
        
        % Determine if a cancel is appropriate
        if obj.submitted && ~obj.completed
        
            % Display progress
            if obj.verbose
                PageBreak();
                disp(['Canceling: ' obj.name]);
                disp(['... at ' char(obj.endTime)]);
                disp(['... array ran for ' num2str(obj.duration) ' s']);
            end

            % Cancel jobs
            for j=1:obj.numJobs
                obj.jobs(j).Cancel();
            end

            % Record stop time and duration
            obj.endTime = datetime('now');
            obj.duration = toc(obj.arrayTimer);
        end

    end

    % -------------------------------------------------------------------------
    % Configure start condition
    % -------------------------------------------------------------------------
    function AddSubmitTrigger(obj, sourceObj, eventName)
        % Add a submission listener
        
        if isempty(obj.jobSubmitListeners)
            listenerID = 1;
            obj.jobSubmitListeners = addlistener(sourceObj, eventName, ...
                @(src,event)obj.HandleSubmitTrigger(src, event, listenerID));
            obj.submitJobFlags = false;
        else
            listenerID = length(obj.jobSubmitListeners)+1;
            obj.jobSubmitListeners(end+1) = addlistener(sourceObj, eventName, ...
                @(src,event)obj.HandleSubmitTrigger(src, event, listenerID));
            obj.submitJobFlags(end+1) = false;
        end
        
    end 
    
    % -------------------------------------------------------------------------
    % Handle submit trigger
    % -------------------------------------------------------------------------
    function HandleSubmitTrigger(obj, source, event, listenerID)
        % Register one (of possibly many) events
        
        % Register event
        obj.submitJobFlags(listenerID) = true;

        % Display progress
        if obj.verbose
            disp([obj.name ' received a submit trigger from ' ...
                source.name]);
        end
        
        % Submit if all events are registered
        if all(obj.submitJobFlags)
            obj.Submit();
        end
    end
    
    % -------------------------------------------------------------------------
    % Add jobs
    % -------------------------------------------------------------------------
    function AddJob(obj, job)
        % Add a job to the job array
        
        % Check job class
        if ~strcmp(class(job), 'SLURMJob')
            error('matlabFunctions:invalidInput', ...
                'The provided job must be an instance of SLURMJob');
        end
        
        % Add jobs to the list
        if isempty(obj.jobs)
            obj.jobs = job;
            obj.jobsSubmitted = false;
            obj.jobsCompleted = false;      
            obj.jobsFailed = false;         
        else
            obj.jobs(end+1) = job;
            obj.jobsSubmitted(end+1) = false;
            obj.jobsCompleted(end+1) = false;      
            obj.jobsFailed(end+1) = false; 
        end
        
        % Update job number
        obj.numJobs = length(obj.jobs);
        
        % Define local jobID
        jobID = obj.numJobs;
        
        % Create a listener and custom callback for each job
        % complete/failed signal
        if obj.numJobs == 1
            obj.jobSubmittedListeners = addlistener(job, 'JobSubmitted', ...
                @(~,~)obj.MarkJobSubmitted(jobID));
            obj.jobCompletedListeners = addlistener(job, 'JobComplete', ...
                @(~,~)obj.MarkJobComplete(jobID));
            obj.jobFailedListeners = addlistener(job, 'JobFailed', ...
                @(~,~)obj.MarkJobFailed(jobID));
        else
            obj.jobSubmittedListeners(end+1) = addlistener(job, 'JobSubmitted', ...
                @(~,~)obj.MarkJobSubmitted(jobID));
            obj.jobCompletedListeners(end+1) = addlistener(job, 'JobComplete', ...
                @(~,~)obj.MarkJobComplete(jobID));
            obj.jobFailedListeners(end+1) = addlistener(job, 'JobFailed', ...
                @(~,~)obj.MarkJobFailed(jobID));
        end
    end
    
    % -------------------------------------------------------------------------
    % Mark job as submitted
    % -------------------------------------------------------------------------
    function MarkJobSubmitted(obj, jobID)
        % Mark a job as submitted
        
        % Mark the indicated job as submitted
        obj.jobsSubmitted(jobID) = true;
                
    end
    
    % -------------------------------------------------------------------------
    % Mark job as complete
    % -------------------------------------------------------------------------
    function MarkJobComplete(obj, jobID)
        % Mark a job as complete
        
        % Mark the indicated job as complete
        obj.jobsCompleted(jobID) = true;
                
        % Prepare to send message
        if all(obj.jobsCompleted)
            % Record stop time and duration
            obj.endTime = datetime('now');
            obj.duration = toc(obj.arrayTimer);
            
            if obj.verbose
                PageBreak();
                disp(['Completed: ' obj.name]);
                disp(['... at ' char(obj.endTime)]);
                disp(['... array ran for ' num2str(obj.duration) ' s']);
            end
            
            % Mark the array as complete
            obj.completed = true;
            
            % Send notification of complete job array
            notify(obj,'JobArrayComplete');

        end
            
    end
    
    % -------------------------------------------------------------------------
    % Mark job as failed
    % -------------------------------------------------------------------------
    function MarkJobFailed(obj, jobID)
        % Mark a job as failed
        
        % Mark indicated job as failed
        obj.jobsFailed(jobID) = true;
        
        % Record stop time and duration
        obj.endTime = datetime('now');
        obj.duration = toc(obj.arrayTimer);

        % Report failure
        if obj.verbose
            PageBreak();
            disp(['Failed: ' obj.name]);
            disp(['... at ' char(obj.endTime)]);
            disp(['... array ran for ' num2str(obj.duration) ' s']);
        end       
        
        % Mark the array as failed
        obj.failed = true;

        % Send notification of failed job
        notify(obj,'JobArrayFailed');

    end
    
    % -------------------------------------------------------------------------
    % Mark job as failed
    % -------------------------------------------------------------------------
    function [shortStatus, longStatus] = Status(obj)
        % Generate a status report for the job array
        
        % Determine current job array state
        state = 'unknown';
        relevantTime = datetime('now');
        if obj.submitted && ~(obj.completed || obj.failed)
            state = 'submitted';
            relevantTime = obj.startTime;
        end
        if obj.completed
            state = 'completed';
            relevantTime = obj.endTime;
        end
        if obj.failed
            state = 'failed';
            relevantTime = obj.endTime;
        end
        
        % Create short status
        shortStatus = [obj.name ': ' state ' at ' char(relevantTime)];
        
        % Create long report
        displayStrings = {};
        displayStrings{end+1} = ['Status report for job array: ' obj.name];
        displayStrings{end+1} = ['Current state: ' state];
        displayStrings{end+1} = ['Start time: ' char(obj.startTime)];
        displayStrings{end+1} = ['End time: ' char(obj.endTime)];
        displayStrings{end+1} = ['Duration (s): ' num2str(obj.duration)];
        displayStrings{end+1} = PageBreak('nodisplay');
        displayStrings{end+1} = ['Number of jobs: ' num2str(obj.numJobs)];
        displayStrings{end+1} = ['Number submitted: ' num2str(sum(obj.jobsSubmitted))];
        displayStrings{end+1} = ['Number complete: ' num2str(sum(obj.jobsCompleted))];
        displayStrings{end+1} = ['Number failed: ' num2str(sum(obj.jobsFailed))];
        displayStrings{end+1} = ['Average duration (s): ' ...
            num2str(mean([obj.jobs.duration]))];
        
        longStatus = char(displayStrings);
  
    end
    
end

methods (Static)
    % -------------------------------------------------------------------------
    % Enter the job array into a global registry
    % -------------------------------------------------------------------------
    function RegisterJobArray(jobArrayObject)
        
        % Load and check the global registry
        global slurmJobArrayRegistry
        
        if ~isempty(slurmJobArrayRegistry)
            if ~isa(slurmJobArrayRegistry, 'SLURMJobArray')
                error('matlabFunctions:invalidVariable', 'The job array registery appears to be corrupted!');
            end
        end
        
        % If the registry is empty, initialize it
        if isempty(slurmJobArrayRegistry)
            slurmJobArrayRegistry = repmat(SLURMJobArray(), [0 1]);
        end
        
        % Confirm that the provided object is a SLURM job array
        if ~isa(jobArrayObject, 'SLURMJobArray')
            error('matlabFunctions:invalidVariable', 'The provided object is not a SLURMJobArray!');
        end

        % Register the job array
        slurmJobArrayRegistry(end+1) = jobArrayObject;
        
        % And report this registration if appropriate
        if jobArrayObject.verbose
            PageBreak();
            disp(['Registered a SLURMJobArray to the global registry'])
            disp(['...name: ' jobArrayObject.name]);
            disp(['...number of jobs: ' num2str(jobArrayObject.numJobs)]);
        end
        
    end
        
    % -------------------------------------------------------------------------
    % Return the SLURMJobArray registry
    % -------------------------------------------------------------------------
    function registry = GetJobArrayRegistry()
        % Load and check the global registry
        global slurmJobArrayRegistry
        
        if ~isempty(slurmJobArrayRegistry)
            if ~isa(slurmJobArrayRegistry, 'SLURMJobArray')
                error('matlabFunctions:invalidVariable', 'The job array registery appears to be corrupted!');
            end
        end
        
        % Return the registry
        registry = slurmJobArrayRegistry;
    end
    
    % -------------------------------------------------------------------------
    % Return the SLURMJobArray registry
    % -------------------------------------------------------------------------
    function ClearRegistry()
        % Load and check the global registry
        global slurmJobArrayRegistry

        % Clear the registry
        slurmJobArrayRegistry = [];
        
    end
    
    % -------------------------------------------------------------------------
    % Cancel all active job arrays
    % -------------------------------------------------------------------------
    function CancelAllJobArrays()
        % Load and check the global registry
        global slurmJobArrayRegistry
        
        if ~isempty(slurmJobArrayRegistry)
            if ~isa(slurmJobArrayRegistry, 'SLURMJobArray')
                error('matlabFunctions:invalidVariable', 'The job array registery appears to be corrupted!');
            end
        end
        
        % Loop over the registry and call the cancel function
        for j=1:length(slurmJobArrayRegistry)
            slurmJobArrayRegistry(j).Cancel();
        end
    end

    
end % end static methods
 
end % end classdef
