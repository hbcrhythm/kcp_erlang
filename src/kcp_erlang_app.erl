%%%-------------------------------------------------------------------
%% @doc kcp_erlang public API
%% @end
%%%-------------------------------------------------------------------

-module(kcp_erlang_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    {ok, Pid} = kcp_erlang_sup:start_link(),
    {ok, KcpSupPid} = supervisor:start_child(kcp_erlang_sup, kcp_sup_spec()),
    {ok, KcpServerPid} = supervisor:start_child(kcp_erlang_sup, kcp_server_spec()),
    kcp_erlang_server:set_listener_sup(KcpServerPid, KcpSupPid),
    kcp_erlang_server:start_connection(false, []),	%% This need to execure in user opts
    {ok, Pid}.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
kcp_sup_spec() ->
	{kcp_erlang_woeker_sup, {kcp_erlang_woeker_sup, start_link, []}, permanent, infinity, supervisor, [kcp_erlang_woeker_sup]}.

kcp_server_spec() ->
	{kcp_erlang_server, {kcp_erlang_server, start_link, []}, permanent, infinity, worker, [kcp_erlang_server]}.