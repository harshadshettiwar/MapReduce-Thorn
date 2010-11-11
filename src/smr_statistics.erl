-module(smr_statistics).

-behaviour(gen_server).

-export([start_link/0, register_worker/2, unregister_worker/2,
        worker_failed/2, worker_batch_started/6, worker_batch_ended/5,
        worker_batch_failed/3]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {workers = dict:new_dict()}).

-record(worker, {node, 
                 num_exec = 0,
                 num_failed = 0,
                 num_succ = 0,
                 num_jobs = 0,
                 busy_time = 0,
                 num_map_jobs = 0,
                 num_reduce_jobs = 0,
                 start_time = dict:new_dict()}).

%------------------------------------------------------------------------------
% Internal API
%------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, [], []).

register_worker(Pid, Node) ->
    gen_server:cast(Pid, {register_worker, Node}).

unregister_worker(Pid, Node) ->
    gen_server:cast(Pid, {unregister_worker, Node}).

worker_failed(Pid, Node) ->
    gen_server:cast(Pid, {worker_failed, Node}).

worker_batch_started(Pid, Node, JobType, JobId, Time, BatchSize) ->
    gen_server:cast(Pid, {batch_started, Node, JobType, JobId, Time, 
                          BatchSize}).

worker_batch_failed(Pid, Node, BatchSize) ->
    gen_server:cast(Pid, {batch_failed, Node, BatchSize}).

worker_batch_ended(Pid, Node, JobId, Time, BatchSize) ->
    gen_server:cast(Pid, {batch_ended, Node, JobId, Time, BatchSize}).

%------------------------------------------------------------------------------
% Handlers
%------------------------------------------------------------------------------

init([]) ->
    {ok, none}.

handle_call(Request, _From, State) ->
    {stop, {unexpected_call, Request}, State}.

handle_cast({register_worker, Node},
            State = #state{workers = Workers}) ->
    {noreply, State#state{workers = dict:store(Node,
                                               #worker{node = Node},
                                               Workers)}};

handle_cast({unregister_worker, Node},
            State = #state{workers = Workers}) ->
    {noreply, State#state{workers = dict:erase(Node, Workers)}};

handle_cast({worker_failed, Node},
            State = #state{workers = Workers}) ->
    Worker = #worker{num_failed = Failed,
                     num_exec = Exec} = dict:fetch(Node, Workers),
    {noreply, State#state{
                workers = dict:store(Node, 
                                     Worker#worker{num_failed = Failed + Exec,
                                                   num_exec = 0}, 
                                     Workers)}};

handle_cast({batch_started, Node, JobType, JobId, Time, Size},
            State = #state{workers = Workers}) ->
    Worker = #worker{num_exec = Exec,
                     num_map_jobs = NumMap,
                     num_reduce_jobs = NumReduce,
                     start_time = StartTime} = dict:fetch(Node, Workers),
    StartTime = dict:store(JobId, Time, StartTime),
    case JobType of
        map    -> NewWorker = Worker#worker{num_exec = Exec + Size, 
                                            num_map_jobs = NumMap,
                                            start_time = StartTime};
        reduce -> NewWorker = Worker#worker{num_exec = Exec + Size,
                                            num_reduce_jobs = NumReduce,
                                            start_time = StartTime}
    end,
    {noreply, State#state{workers = dict:store(Node, NewWorker, Workers)}};

handle_cast({batch_ended, Node, JobId, Time, Size},
            State = #state{workers = Workers}) ->
    Worker = #worker{num_exec = Exec,
                     num_succ = Succ,
                     start_time = STime,
                     busy_time = BTime} = dict:fetch(Node, Workers),
    NewBTime = BTime + Time - dict:fetch(JobId, STime),
    {noreply, State#state{workers = 
                 dict:store(Node,
                            Worker#worker{num_exec = Exec - Size,
                                          num_succ = Succ + Size,
                                          busy_time = NewBTime,
                                          start_time = dict:erase(JobId, 
                                                                  STime)},
                            Workers)}};

handle_cast({batch_failed, Node, Size},
            State = #state{workers = Workers}) ->
    Worker = #worker{num_failed = Failed,
                     num_exec = Exec} = dict:fetch(Node, Workers),
    {noreply, State#state{workers = dict:store(Node,
                                               Worker#worker{
                                                  num_exec = Exec - Size,
                                                  num_failed = Failed + Size},
                                               Workers)}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(Msg, State) ->
    {stop, {unexpected_message, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

