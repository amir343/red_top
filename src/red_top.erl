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
-define(SAMPLE_INTERVAL, 3000).
-define(TABLE,           reductions_table).
-define(SERVER,          ?MODULE).
-define(MAX_NR_WORKERS,  5).

%%%_* Records =========================================================

-record(state, { sample_interval = ?SAMPLE_INTERVAL,
                 table           = undefined,
                 workers         = []
               }).

%%% -------------------------------------------------------------------------

-type cpu_util() :: float().

-type app_name() :: atom().


%%% -------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec app(atom()) -> [{app_name(), cpu_util(), [{pid(), cpu_util()}]}].
%% Return the calculated reductions for processes and the application `AppName'
app(AppName) ->
  gen_server:call(?SERVER, {dump_app, AppName}, infinity).

-spec all_level() -> [{app_name(), cpu_util(), [{pid(), cpu_util()}]}].
% Return a list of applications and their corresponding process list and
%% calculated cpu utilisation for all.
all_level() ->
  gen_server:call(?SERVER, {dump, all}, infinity).

-spec top_level() -> [{app_name(), cpu_util(), []}].
%% Return a list of applications and calculated cpu utilisaton.
top_level() ->
  gen_server:call(?SERVER, {dump, top_level}, infinity).

-spec set_sample_interval(pos_integer()) ->
                             ok | {error, invalid_sample_interval}.
%% Set sample interval
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
      klog:format(debug, "red_top worker exited with reason :~p~n", [Reason])
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

worker(Request, From, Table) ->
  Result =
    case Request of
      {dump, Mode}     -> get_latest_sample(Mode, Table);
      {dump_app, Name} -> get_latest_sample_for_app(Name, Table);
      _                -> {unrecognized_request, Request}
    end,
  gen_server:reply(From, Result).

handle_worker_exit(Pid, Ref, Workers, State) ->
  case lists:keyfind({Pid, Ref}, 1, Workers) of
    {_, Caller, Table} = Rec ->
      delete_ets_if_possible(Table, State),
      {Caller, lists:delete(Rec, Workers)};
    false ->
      {undefined, Workers}
  end.

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

%% Don't delete the table if it's the current table and it is needed
%% for next sampling.
delete_ets_if_possible(Table, #state{table = Table}) ->
  ok;
delete_ets_if_possible(OldTable, #state{workers = Workers}) ->
  IsUsed = lists:any(fun({_, _, T}) -> T =:= OldTable end, Workers),
  case IsUsed of
    true  -> ok;
    false -> ets:delete(OldTable)
  end.

get_latest_sample_for_app(AppName, Table) ->
  Result = get_latest_sample(all, Table),
  [R || {App, _, _} = R <- Result, App =:= AppName].

get_latest_sample(Mode, Table) ->
  TotalReductions =
    ets:foldl(
      fun({_, _, _, {R1, R2}}, TotalRs) ->
          TotalRs + R2 - R1
      end, 0, Table),
  calc_reductions(Mode, Table, TotalReductions).

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
  Result = lists:reverse(lists:keysort(2, ets:tab2list(TmpTable))),
  ets:delete(TmpTable),
  Result.

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
