%%% @doc show reductions per applications and processes
%%% @copyright 2017 Klarna AB
-module(red_top).

-export([ all_level/0
        , app/1
        , set_sample_interval/1
        , start_link/0
        , top_level/0
        ]).

%%%_* Behaviors =========================================================
-behavior(gen_server).

%% gen_server callbacks
-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

%% Internal export
-export([ worker/3
        ]).

%%% -------------------------------------------------------------------------

-define(TAGS,            [reductions, group_leader, registered_name]).
%% Tags that are retrieved from `process_info' call in each sample.

-define(SAMPLE_INTERVAL, 3000).
%% Every `SAMPLE_INTERVAL' milliseconds a new sample is taken.

-define(TABLE,           reductions_table).
%% Current reductions table's name.

-define(SERVER,          ?MODULE).
-define(MAX_NR_WORKERS,  5).
%% Maximum number of workers allowed for querying this server.

%%%_* Records ===============================================================

-record(state, { sample_interval = ?SAMPLE_INTERVAL,
                 table           = undefined,
                 workers         = []
               }).

%%% -------------------------------------------------------------------------

-type worker_ref() :: {pid(), reference()}.

-type worker() :: {worker_ref(), pid(), ets:tab()}.

-type cpu_util() :: float().
%% Cpu utilisation percentage.

-type app_name() :: atom().
-type process_name() :: atom() | pid().

-type state() ::
        #state{ sample_interval :: pos_integer()
              , table :: ets:tab()
              , workers :: [worker()]
              }.

-export_type([ app_name/0
             , cpu_util/0
             , process_name/0
             ]).

%%% -------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
%% @doc Start `red_top' server.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec app(app_name()) ->
             [{app_name(), cpu_util(), [{process_name(), cpu_util()}]}].
%% @doc Return the calculated reductions for processes and the application
%% `AppName'
app(AppName) ->
  gen_server:call(?SERVER, {dump_app, AppName}, infinity).

-spec all_level() -> [{app_name(), cpu_util(), [{pid(), cpu_util()}]}].
% @doc Return a list of applications and their corresponding process list and
%% calculated cpu utilisation for all.
all_level() ->
  gen_server:call(?SERVER, {dump, all}, infinity).

-spec top_level() -> [{app_name(), cpu_util(), []}].
%% @doc Return a list of applications and calculated cpu utilisaton.
top_level() ->
  gen_server:call(?SERVER, {dump, top_level}, infinity).

-spec set_sample_interval(pos_integer()) ->
                             ok | {error, invalid_sample_interval}.
%% @doc Set sample interval
set_sample_interval(IntervalMs) when is_integer(IntervalMs), IntervalMs > 0 ->
  gen_server:cast(?SERVER, {set_sample_interval, IntervalMs});
set_sample_interval(_) ->
  {error, invalid_sample_interval}.

%%% -------------------------------------------------------------------------

init(_Args) ->
  schedule_sample(1000),
  {ok, #state{table = create_table()}}.

handle_cast({set_sample_interval, IntervalMs}, State)
  when is_integer(IntervalMs), IntervalMs > 0 ->
  {noreply, State#state{sample_interval = IntervalMs}};

handle_cast(_Request, State) ->
  {noreply, State}.

handle_call(Request, Caller, State=#state{ table = Table
                                       , workers = Workers}) ->
  case length(Workers) + 1 > ?MAX_NR_WORKERS of
    true ->
      {reply, max_number_of_workers_reached, State};
    false ->
      Worker = spawn_monitor(?MODULE, worker, [Request, Caller, Table]),
      {noreply, State#state{workers = [{Worker, Caller, Table} | Workers]}}
  end.

handle_info(sample, State=#state{sample_interval = SampleInterval}) ->
  schedule_sample(SampleInterval),
  {noreply, sample(State)};

handle_info({'DOWN', Ref, process, Pid, normal},
            State=#state{workers = Workers}) ->
  {_, NewWorkers} = handle_worker_exit(Pid, Ref, Workers, State),
  {noreply, State#state{workers = NewWorkers}};

handle_info({'DOWN', Ref, process, Pid, Reason},
            State=#state{workers = Workers}) ->
  {Caller, NewWorkers} = handle_worker_exit(Pid, Ref, Workers, State),
  if Caller =:= undefined -> ok;
     true ->
      gen_server:reply(Caller, []),
      error_logger:error_msg( "red_top worker exited with reason: ~p~n"
                            , [Reason])
  end,
  {noreply, State#state{workers = NewWorkers}};

handle_info(_, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

%%% -------------------------------------------------------------------------
%%% Internal Functions
%%% -------------------------------------------------------------------------

-spec worker(any(), pid(), ets:tab()) ->
                term() | {unrecognized_request, any()}.
%% Start a worker with respective request, caller's pid and table name
worker(Request, From, Table) ->
  Result =
    case Request of
      {dump, Mode}     -> get_latest_sample(Mode, Table);
      {dump_app, Name} -> get_latest_sample_for_app(Name, Table);
      _                -> {unrecognized_request, Request}
    end,
  gen_server:reply(From, Result).

-spec handle_worker_exit(pid(), reference(), [worker()], state()) ->
                            {pid(), [worker()]}.
%% This function is called whenever a worker exits as a mean of clening up
%% any resources that are being used by the worker.
%%
%% It checks if there are any other worker that is using the same table
%% and if not it removes that table.
%%
%% It returns the caller's pid that this worker is generated for and a list
%% of remaining workers.
handle_worker_exit(Pid, Ref, Workers, State) ->
  case lists:keyfind({Pid, Ref}, 1, Workers) of
    {_, Caller, Table} = Rec ->
      delete_ets_if_possible(Table, State),
      {Caller, lists:delete(Rec, Workers)};
    false ->
      {undefined, Workers}
  end.

-spec sample(state()) -> state().
%% This function is called for taking a sample of processes running in the
%% system. It works as follows:
%% * create a new ETS table(`NewTable')
%% * for every process info that still exists in the `OldTable' migrate it to
%%   the new table, otherwise create a new record in new table.
%% * check if `OldTable' is not used by any worker and if not then delete it.
%%
%% We always keep two last reductions for a process. By migrating data between
%% ETS tables we minimize application name resolution to only once per
%% process and also it becomes easier with process churn.
sample(State=#state{table = OldTable}) ->
  NewTable = create_table(),
  lists:foreach(
    fun({P, PidInfo}) ->
        NewR = reductions(PidInfo),
        GL = get_group_leader(PidInfo),
        case ets:lookup(OldTable, P) of
          [] ->
            RegisteredNames = registered_name(PidInfo),
            ets:insert(NewTable,
                       { P
                       , app_name(P, GL, RegisteredNames)
                       , RegisteredNames
                       , {0, NewR}});
          [{Pid, App, RN, {_, R2}}] ->
            ets:insert(NewTable, {Pid, App, RN, {R2, NewR}})
        end
    end, process_infos()),
  NewState = State#state{table = NewTable},
  delete_ets_if_possible(OldTable, NewState),
  NewState.

-spec delete_ets_if_possible(ets:tab(), state()) -> boolean().
%% Don't delete the table if:
%% * it's the current table and it is needed for next sampling, Or
%% * it's used by a worker at the moment.
delete_ets_if_possible(Table, #state{table = Table}) ->
  false;
delete_ets_if_possible(OldTable, #state{workers = Workers}) ->
  IsUsed = lists:any(fun({_, _, T}) -> T =:= OldTable end, Workers),
  case IsUsed of
    true  -> false;
    false -> ets:delete(OldTable)
  end.

-spec get_latest_sample_for_app(app_name(), ets:tab()) ->
                                   [ { app_name()
                                     , cpu_util()
                                     , [{process_name(), cpu_util()}]
                                     }
                                   ].
%% The same as {@link get_latest_sample/2} but it filters for the given
%% `AppName'.
get_latest_sample_for_app(AppName, Table) ->
  Result = get_latest_sample(all, Table),
  [R || {App, _, _} = R <- Result, App =:= AppName].

-spec get_latest_sample(all | top_level, ets:tab()) ->
                           [ { app_name()
                             , cpu_util()
                             , [{process_name(), cpu_util()}]
                             }
                           ].
%% Calculate reductions per application and processes from the given
%% `Table'. `Table' can be at least one sample behind.
%% `Mode' can be either:
%% * `top_level': only return application names and their corresponding
%%   cpu utilisations in descending order.
%% * `all': return applications' cpu utilisation with also their processes and
%%   their relative cpu utilisations.
get_latest_sample(Mode, Table) ->
  TotalReductions =
    ets:foldl(
      fun({_, _, _, {R1, R2}}, TotalRs) ->
          TotalRs + R2 - R1
      end, 0, Table),
  calc_reductions(Mode, Table, TotalReductions).

-spec calc_reductions(all | top_level, ets:tab(), pos_integer()) ->
                         [ { app_name()
                           , cpu_util()
                           , [{process_name(), cpu_util()}]
                           }
                         ].
%% Calculate reductions per application and processes by keeping the
%% result in a temporary ETS table and convert to list at the end.
calc_reductions(Mode, Table, TotalReductions) ->
  TmpTable = ets:new(result_tmp, [private, set]),
  ets:foldl(
    fun({Pid, App, RN, {R1, R2}}, _) ->
        DiffRed = (R2 - R1) * 100 / TotalReductions,
        case Mode of
          top_level ->
            calc_reductions_per_app(TmpTable, App, DiffRed, []);
          _ ->
            NewProcess = {pid_to_name(Pid, RN), DiffRed},
            calc_reductions_per_app(TmpTable, App, DiffRed, [NewProcess])
        end
    end, undefined, Table),
  Result = sort(ets:tab2list(TmpTable)),
  ets:delete(TmpTable),
  Result.

-spec calc_reductions_per_app( ets:tab()
                             , app_name()
                             , float()
                             , [{process_name(), cpu_util()}]) ->
                                 boolean().
%% Calculate reductions per application by updating the application's
%% reduction with the `NewProcess'. If application is already in the table
%% we only partially update the record.
calc_reductions_per_app(TmpTable, App, DiffReduction, NewProcess) ->
  case ets:lookup(TmpTable, App) of
    [] ->
      Rec = {App, DiffReduction, NewProcess},
      ets:insert(TmpTable, Rec);
    [{_, AppRed, Processes}] ->
      NewProcesses =
        case NewProcess of
          []  -> [];
          [H] -> sort([H | Processes])
        end,
      ets:update_element(TmpTable, App, [ {2, AppRed + DiffReduction}
                                        , {3, NewProcesses}])
  end.

sort(Processes) ->
  lists:reverse(lists:keysort(2, Processes)).

schedule_sample(Timeout) ->
  erlang:send_after(Timeout, self(), sample).

process_infos() ->
  [{P, process_info(P, ?TAGS)} || P <- processes()].

reductions(undefined) ->
  0;
reductions(PidInfo) ->
  get_value(reductions, PidInfo, 0).

get_group_leader(undefined) ->
  undefined;
get_group_leader(PidInfo) ->
  get_value(group_leader, PidInfo, undefined).

registered_name(undefined) ->
  undefined;
registered_name(PidInfo) ->
  get_value(registered_name, PidInfo, undefined).

get_value(Key, List, DefaultValue) ->
  case lists:keyfind(Key, 1, List) of
    {_, V} -> V;
    false  -> DefaultValue
  end.

app_name(Pid, GroupLeader, RegisteredNames) ->
  case application_controller:get_application(GroupLeader) of
    {ok, App} -> App;
    undefined -> pid_to_name(Pid, RegisteredNames)
  end.

pid_to_name(Pid, undefined) ->
  Pid;
pid_to_name(Pid, []) ->
  Pid;
pid_to_name(_, [H | _]) ->
  H;
pid_to_name(_, Name) ->
  Name.

create_table() ->
  ets:new(?TABLE, [protected, set]).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
