-module(kcp_erlang_server).
-author('labihbc@gmail.com').

-behaviour(gen_server).

-include("kcp_erlang.hrl").

%% API
-export([
  start_link/0
  ,start_link/1
  ,start_connection/2
  ,start_connection/3
  ,set_listener_sup/2]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  ref = undefined,
  listener_sup = undefined,
  sup_monitor = undefined,
  max_conns,
  cur_conns = 0,
  waiter = []}).


start_connection(Block, Args) -> 
  gen_server:call(?MODULE, {start_connection, Block, Args}).
start_connection(Ref, Block, Args) ->
  gen_server:call(Ref, {start_connection, Block, Args}).

set_listener_sup(PID, SupPID) ->
  gen_server:call(PID, {set_listener_sup, SupPID}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% Options contains the following option:
%% {max_conns, MaxConns} -> max connections allowed within this sup
%% {sock_opts, SockOpts} -> sock options when open a new socked
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  start_link(?MODULE).
start_link(Ref) ->
  gen_server:start_link({local, Ref}, ?MODULE, [Ref], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).

init([Ref]) ->
  erlang:process_flag(trap_exit, true),

  MaxConnect = application:get_env(?APPLICATION, max_connect, ?MAX_CONNECT),

  {ok, #state{max_conns = MaxConnect, ref = Ref}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).

handle_call({set_listener_sup, SupPID}, _From, State) ->
  MonitorRef = erlang:monitor(process, SupPID),
  {reply, ok, State#state{listener_sup = SupPID, sup_monitor = MonitorRef}};

%% Start a new connection
handle_call({start_connection, Block, Args}, From, State) ->
  start_callback_proc(Block, Args, From, State);

%% Fetch active connections count
handle_call(active_connections, _From, State) ->
  {reply, {ok, State#state.cur_conns}, State};

%% Remove a connection count from this sup
handle_call(remove_connection, _From, State) ->
  Cur = State#state.cur_conns - 1,
  case Cur > 0 of
    true  -> {reply, {ok, Cur}, State#state{cur_conns = Cur}};
    false -> {reply, {error, "cur conns less than zero"}, State}
  end;

%% Set a new max connection value
handle_call({set_max_conns, NewMax}, _From, State) ->
  case NewMax < State#state.max_conns of
    true ->
      {reply, {ok, State#state.cur_conns}, State#state{max_conns = NewMax}};
    false ->
      State2 = State#state{max_conns = NewMax},
      State3 = wake_up_waiters(NewMax - State#state.max_conns, State2),
      {reply, {ok, State3#state.cur_conns}, State3}
  end;

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({'DOWN', MonitorRef,  process, PID, Reason}, State = #state{listener_sup = PID, sup_monitor = MonitorRef}) ->
  ?ERRORLOG("listener sup exit with reason ~p", [Reason]),
  {stop, Reason, State};
handle_info({'DOWN', _MonitorRef, process, PID, Reason}, State) ->
  ?ERRORLOG("connection ~p exit beacause of ~p", [PID, Reason]),
  {noreply, State#state{cur_conns = State#state.cur_conns - 1}};
handle_info(dump_state, State) ->
  io:format("State is ~p", [State]),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.
  % close_all_conns(ets:first(ditch_sup_ets)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
wake_up_waiters(Count, State) ->
  #state{waiter = Waiter, cur_conns = Cur} = State,
  Wcnt = case length(Waiter) < Count of
           true -> length(Waiter);
           false -> Count
         end,
  {ToWake, Left} = lists:split(Wcnt, State#state.waiter),
  lists:foldl(fun({From, Args}, S) ->
    case start_callback_proc2(S, Args) of
      {reply, R, S2} ->
        gen_server:reply(From, R), S2;
      {noreply, S2, _} -> S2
    end
              end, State, ToWake),
  State#state{waiter = Left, cur_conns = Cur}.


start_callback_proc(Block, Args, From, State) ->
  #state{cur_conns = Cur, max_conns = Max, waiter = Waiter} = State,
  case Cur < Max of
    true -> start_callback_proc2(State, Args);
    false when Block =:= false ->
      ?ERRORLOG("cur conns out limit ~p/~p, ret error", [Cur, Max]),
      {reply, {error, "out conns count limit"}, State};
    false when Block =:= true ->
      ?ERRORLOG("cur conns out limti ~p/~p, blocking...", [Cur, Max]),
      {noreply, State#state{waiter = [{From, Args} | Waiter]}, infinity}
  end.
start_callback_proc2(State = #state{listener_sup = SupID, cur_conns = Cur}, Args) ->
  case supervisor:start_child(SupID, [Args]) of
    {ok, ChildPID} ->
      erlang:monitor(process, ChildPID),
      {reply, {ok, ChildPID}, State#state{cur_conns = Cur + 1}};
    {error, Reason} ->
      ?ERRORLOG("start ditch_listener_sup child failed, reason ~w", [Reason]),
      {reply, {error, Reason}, State}
  end.

%% Close all connectons within this connection sup.
% close_all_conns('$end_of_table') -> ok;
% close_all_conns(Pid) ->
%   case ets:lookup(ditch_sup_ets, Pid) of
%     [] -> ok;
%     [{Pid, Sock}] -> gen_udp:close(Sock)
%   end,
%   NextPid = ets:next(ditch_sup_ets, Pid),
%   close_all_conns(NextPid).
