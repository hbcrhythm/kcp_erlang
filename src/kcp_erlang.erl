-module(kcp_erlang).
-author('labihbc@gmail.com').
-include("kcp_erlang.hrl").

-export([start/0]).

start() ->
    application:ensure_started(?APPLICATION),
    erlang:spawn(fun() -> observer:start() end).

