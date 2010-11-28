
-module(smr_job_sup_sup).

-behaviour(supervisor).

-export([start_link/0, start_job_sup/5]).
-export([init/1]).

%------------------------------------------------------------------------------

start_link() ->
    supervisor:start_link(?MODULE, []).

start_job_sup(Sup, Master, MapFun, ReduceFun, Input) ->
    supervisor:start_child(Sup, [Master, MapFun, ReduceFun, Input]).

%------------------------------------------------------------------------------

init([]) ->
    {ok, {{simple_one_for_one, 0, 1},
          [{job_sup, {smr_job_sup, start_link, []}, temporary, 60, worker,
            [smr_job_sup]}]}}.