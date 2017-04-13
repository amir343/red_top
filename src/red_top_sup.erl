
-module(red_top_sup).

-behaviour(supervisor).

%% External exports
-export([ start_link/0
        ]).

%% supervisor callbacks
-export([ init/1
        ]).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(SERVER, ?MODULE).
-define(SUP2, red_top2_sup).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, ?SERVER).

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

server(Name, Type) ->
  server(Name, Type, 2000).

server(Name, Type, Shutdown) ->
  {Name, {Name, start_link, []}, permanent, Shutdown, Type, [Name]}.

worker(Name) -> server(Name, worker).

init(?SERVER) ->
  %% The top level supervisor *does not allow restarts*; if a component
  %% directly under this supervisor crashes, the entire node will shut
  %% down and restart. Thus, only those components that must never be
  %% unavailable should be directly under this supervisor.

  SecondSup = {?SUP2,
               {supervisor, start_link,
                [{local, ?SUP2}, ?MODULE, ?SUP2]},
               permanent, 2000, supervisor, [?MODULE]},

  {ok, {{one_for_one,0,1},  % no restarts allowed!
        [SecondSup]
       }};

init(?SUP2) ->
  %% The second-level supervisor allows some restarts. This is where the
  %% normal services live.
  {ok, {{one_for_one, 10, 20},
        [ worker(red_top)
        ]
       }}.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
