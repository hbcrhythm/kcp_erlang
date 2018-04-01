-module(kcp_erlang_woeker_sup).
-author('labihbc@gmail.com').

-behaviour(supervisor).

-include("kcp_erlang.hrl").

%% API
-export([start_link/0, start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @end
%%--------------------------------------------------------------------
start_link() ->
  	start_link(?MODULE).
start_link(Ref) ->
	supervisor:start_link({local, Ref},?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
    MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
    [ChildSpec :: supervisor:child_spec()]
  }} |
  ignore |
  {error, Reason :: term()}).
init([]) ->
  RestartStrategy = simple_one_for_one,
  MaxR = 10,
  MaxT = 10,
  SupFlags = {RestartStrategy, MaxR, MaxT},

  Opts = application:get_env(?APPLICATION, opts, []),
  Callback = application:get_env(?APPLICATION, callback, kcp_erlang_callback),
  CallbackOpts = application:get_env(?APPLICATION, callback_opts, []),

  AChild = {kcp_erlang_worker, {kcp_erlang_worker, start_link, [Opts, Callback, CallbackOpts]},
    temporary, 5000, worker, [kcp_erlang_worker]},
  {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

