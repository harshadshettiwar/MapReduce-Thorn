
-module(smr_task_sup_sup).

-behaviour(supervisor).

-export([start_link/0, start_task/5]).
-export([init/1]).

%------------------------------------------------------------------------------

start_link() ->
    supervisor:start_link(?MODULE, []).

start_task(Sup, JobPid, TaskType, TaskFun, Input) ->
    supervisor:start_child(Sup, [JobPid, TaskType, TaskFun, Input]).

%------------------------------------------------------------------------------

init([]) ->
    {ok, {{simple_one_for_one, 10, 60 * 60},
          [{task_sup, {smr_task_sup, start_link, []}, transient,
            60, supervisor, [smr_task_sup]}]}}.