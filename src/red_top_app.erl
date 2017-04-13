-module(red_top_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _StartArgs) ->
  red_top_sup:start_link().

stop(_State) ->
  ok.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
