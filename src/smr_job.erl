
-module(smr_job).

-behavior(gen_server).

-export([start_link/3, add_input/2, start/1, result/3]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {sup,
                phase = input, % input | map | reduce
                map_fun,
                reduce_fun,
                master,
                ongoing = 0,
                input = [],
                result}).

-define(MAP_BATCH_SIZE, 1).
-define(REDUCE_BATCH_SIZE, 1).

%------------------------------------------------------------------------------
% Internal API
%------------------------------------------------------------------------------

start_link(Master, MapFun, ReduceFun) ->
    gen_server:start_link(?MODULE, [self(), Master, MapFun, ReduceFun], []).

add_input(Job, Input) ->
    gen_server:cast(Job, {add_input, Input}).

start(Job) ->
    gen_server:cast(Job, start).

result(Job, Worker, Result) ->
    gen_server:cast(Job, {result, Worker, Result}).

%------------------------------------------------------------------------------
% Handlers
%------------------------------------------------------------------------------

init([Sup, Master, MapFun, ReduceFun]) ->
    error_logger:info_msg("Job ~p created~n", [self()]),
    {ok, #state{sup = Sup,
                map_fun = MapFun,
                reduce_fun = ReduceFun,
                master = Master}}.

handle_call(_Request, _From, State) ->
    {stop, unexpected_call, State}.

handle_cast(start, State) ->
    {noreply, set_phase(map, State)};
handle_cast({add_input, NewInput}, State = #state{phase = input,
                                                  input = CurInput}) ->
    {noreply, State#state{input = NewInput ++ CurInput}};
handle_cast({result, _, Result}, State0) ->
    State1 = #state{ongoing = Ongoing} = agregate_result(Result, State0),
    State2 = State1#state{ongoing = Ongoing - 1},
    case State2 of #state{ongoing = 0} -> handle_phase_finished(State2);
                   _                   -> {noreply, State2}
    end.

handle_info(Msg, State) ->
    {stop, {unexpected_message, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%------------------------------------------------------------------------------
% Internal
%------------------------------------------------------------------------------

handle_phase_finished(State = #state{phase = map, result = Result}) ->
    {noreply, set_phase(reduce, State#state{input = dict:to_list(Result)})};
handle_phase_finished(State = #state{phase = reduce,
                              result = Result,
                              master = Master}) ->
    smr_master:job_result(Master, self(), Result),
    {stop, normal, State}.

set_phase(map, State = #state{input = Input}) ->
    error_logger:info_msg("Job ~p: map phase started~n", [self()]),
    send_tasks(Input, State#state{phase = map,
                                  input = undefined, % free
                                  result = dict:new()});
set_phase(reduce, State = #state{input = Input}) ->
    error_logger:info_msg("Job ~p: reduce phase started~n", [self()]),
    send_tasks(Input, State#state{phase = reduce,
                                  input = undefined, % free
                                  result = []}).

agregate_result(Result, State = #state{phase = map, result = Dict}) ->
    State#state{result =
        lists:foldl(fun ({K, V}, DictAcc) ->
                            case dict:is_key(K, DictAcc) of
                                true  -> dict:append(K, V, DictAcc);
                                false -> dict:store(K, [V], DictAcc)
                            end
                    end, Dict, Result)};
agregate_result(Result, State = #state{phase = reduce, result = List}) ->
    State#state{result = Result ++ List}.

send_tasks([], State) ->
    State;
send_tasks(Input, State = #state{sup = Sup,
                                 phase = Phase,
                                 map_fun = MapFun,
                                 reduce_fun = ReduceFun,
                                 ongoing = Ongoing}) ->
    {TaskInput, RestInput} = lists:split(?MAP_BATCH_SIZE, Input),
    {TaskType, Fun} = case Phase of map    -> {map, MapFun};
                                    reduce -> {reduce, ReduceFun}
                      end,
    {ok, _} =
        smr_task_sup_sup:start_task(smr_job_sup:task_sup_sup(Sup),
                                    self(), TaskType, Fun, TaskInput),
    send_tasks(RestInput, State#state{ongoing = Ongoing + 1}).
