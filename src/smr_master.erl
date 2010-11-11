
-module(smr_master).

-behavior(gen_server).

-export([start_link/0, spawn_worker/2, shutdown_worker/2, get_worker_nodes/1,
         get_worker_pids/1, map_reduce/4]).
-export([job_result/3, allocate_workers/1]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, 
        code_change/3]).

-record(state, {workers = dict:new(),
                jobs = dict:new(),
                workers_pid = dict:new(),
                monitor_pid}).

-record(worker, {node, pid}).

-record(job, {pid, from, map_fun, reduce_fun, input}).

-define(MIN_BACKOFF_MS, 64).
-define(MAX_BACKOFF_MS, 32768).

%------------------------------------------------------------------------------
% API
%------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, [], []).

spawn_worker(Pid, Node) -> 
    gen_server:call(Pid, {spawn_worker, Node}, infinity).

shutdown_worker(Pid, Node) -> 
    gen_server:call(Pid, {shutdown_worker, Node}, infinity).

get_worker_nodes(Pid) -> gen_server:call(Pid, get_worker_nodes, infinity).

get_worker_pids(Pid) -> gen_server:call(Pid, get_worker_pids, infinity).

map_reduce(Pid, Map, Reduce, Input) -> 
    gen_server:call(Pid, {map_reduce, Map, Reduce, Input}, infinity).

%------------------------------------------------------------------------------
% Internal API
%------------------------------------------------------------------------------

job_result(Pid, JobPid, Result) ->
    gen_server:cast(Pid, {job_result, JobPid, Result}).

allocate_workers(Pid) ->
    gen_server:call(Pid, allocate_workers, infinity).

%------------------------------------------------------------------------------
% Handlers
%------------------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    {ok, MonitorPid} = smr_statistics:start_link(),
    {ok, #state{monitor_pid = MonitorPid}}.

handle_call({spawn_worker, Node}, _From,
            State = #state{workers = Workers, monitor_pid = MonitorPid}) ->
    case dict:find(Node, Workers) of
        {ok, _Val} -> {reply, {error, already_registered}, State};
        error      -> smr_statistics:register_worker(MonitorPid, Node),
                      {reply, ok, restart_worker(Node, State)}
    end;

handle_call({shutdown_worker, Node}, _From,
            State = #state{workers_pid = WorkersPid, workers = Workers}) ->
    case dict:find(Node, Workers) of
        {ok, #worker{pid = Pid}} ->
            {reply, ok,
             remove_worker(Node, State#state{workers_pid =
                                                 dict:erase(Pid, WorkersPid)})};
        error ->
            {reply, {error, not_registered}, State}
    end;

handle_call(get_worker_nodes, _From, State) ->
    {reply, dict:fetch_keys(State#state.workers), State};

handle_call(get_worker_pids, _From, State) ->
    {reply, dict:fetch_keys(State#state.workers_pid), State};

handle_call(allocate_workers, _From, State = #state{workers = Workers}) ->
    {reply, dict:fold(fun (_, #worker{pid = Pid}, Acc) -> [Pid | Acc] end,
                      [], Workers),
     State};

handle_call({map_reduce, Map, Reduce, Input}, From, 
            State = #state{jobs = Jobs}) ->
    {ok, JobPid} = smr_job:start_link(self(), Map, Reduce, Input),
    {noreply, State#state{jobs = dict:store(JobPid, #job{pid = JobPid,
                                                         from = From,
                                                         map_fun = Map,
                                                         reduce_fun = Reduce,
                                                         input = Input},
                                            Jobs)}}.

handle_cast({job_result, JobPid, Result}, State = #state{jobs = Jobs}) ->
    gen_server:reply((dict:fetch(JobPid, Jobs))#job.from, Result),
    {noreply, State}.

handle_info({restart_worker, Node, BackOff}, State) ->
    {noreply, restart_worker(Node, 2 * BackOff, State)};

handle_info({'EXIT', Pid, Reason}, State = #state{workers_pid = WorkersPid}) ->
    case dict:find(Pid, WorkersPid) of
        {ok, WorkerNode} -> handle_worker_exit(Pid, WorkerNode, Reason, State);
        error            -> handle_other_exit(Pid, Reason, State)
    end;
    
handle_info(Msg, State) ->
    {stop, {unexpected_message, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%------------------------------------------------------------------------------
% Internal
%------------------------------------------------------------------------------

handle_worker_exit(Pid, Node, Reason,
                   State = #state{workers_pid = WorkersPid}) ->
    NewState = State#state{workers_pid = dict:erase(Pid, WorkersPid)},
    case Reason of normal -> {noreply, remove_worker(Node, NewState)};
                   _      -> {noreply, restart_worker(Node, NewState)}
    end.

% TODO: We are assuming job pid
handle_other_exit(Pid, normal, State = #state{jobs = Jobs}) ->
    {noreply, State#state{jobs = dict:erase(Pid, Jobs)}}.

remove_worker(Node, State = #state{monitor_pid = MonitorPid,
                                   workers = Workers}) ->
    smr_statistics:unregister_worker(MonitorPid, Node),
    State#state{workers = dict:erase(Node, Workers)}.

restart_worker(Node, State) ->
    restart_worker(Node, ?MIN_BACKOFF_MS, State).

restart_worker(Node, BackOff, State = #state{workers = Workers,
                                             workers_pid = WorkersPid}) ->
    %% TODO log me
    case smr_worker:start_link(Node) of
        {ok, Pid} ->
            Worker = case dict:find(Node, Workers) of
                         {ok, W} -> W;
                         error   -> #worker{pid = Pid}
                     end,
            State#state{workers = dict:store(Node, Worker#worker{node = Node},
                                             Workers),
                        workers_pid = dict:store(Pid, Node, WorkersPid)};
        _Error when BackOff > ?MAX_BACKOFF_MS ->
            %% TODO log me
            remove_worker(Node, State);
        _Error ->
            %% TODO log me
            erlang:send_after(BackOff, self(), {restart_worker, Node, BackOff}),
            State
    end.
