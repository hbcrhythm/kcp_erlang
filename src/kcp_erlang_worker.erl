-module(kcp_erlang_worker).
-author('labihbc@gmail.com').

-behaviour(gen_server).
-include("kcp_erlang.hrl").

-include_lib("kernel/src/inet_int.hrl").

%% API
-export([start_link/4,
  send_data/2,
  send_datalist/2,
  dump_kcp/1,
  name/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {sock :: inet:socket(),
  callback :: any(),
  cb_opts :: list(),
  cb_args :: list()}).

%%%===================================================================
%%% API
%%%===================================================================
name() ->
  kcp_erlang_worker.

send_data(#kcp_ref{pid = PID, key = Key}, Data) ->
  PID ! {kcp_send, Key, Data}.

send_datalist(#kcp_ref{pid = PID, key = Key}, Datalist) ->
  PID ! {kcp_send_datalist, Key, Datalist}.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(Opts :: any(), Callback :: module(), Callback :: any(), CallbackArgs::any()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Opts, Callback, CallbackOpts, CallbackArgs) ->
  io:format("Opts, Callback, CallbackOpts, CallbackArgs ~w ~w ~w ~w",[Opts, Callback, CallbackOpts, CallbackArgs]),
  gen_server:start_link(?MODULE, [Opts, Callback, CallbackOpts, CallbackArgs], []).

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
init([Opts, Callback, CallbackOpts, CallbackArgs]) ->
  UDPOpts = proplists:get_value(udp_opts, Opts, ?UDP_SOCK_OPTS),
  erlang:process_flag(trap_exit, true),
  case gen_udp:open(0, UDPOpts) of
    {error, Reason} ->
      ?ERRORLOG("open kcp listener failed, reason ~p", [Reason]),
      {stop, Reason};
    {ok, Socket} ->
      {ok, Port} = inet:port(Socket),
      ?DEBUGLOG("init udp sock with port ~p", [Port]),
      timer:send_after(?KCP_UPDATE_INTERVAL, self(), kcp_update),
      {ok, #state{sock = Socket, callback = Callback, cb_opts = CallbackOpts, cb_args = CallbackArgs}}
  end.

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
%% stop when proc process terminate
handle_info({'EXIT', _From, Reason}, State) ->
  ?ERRORLOG("callback module exit with reason ~p", [Reason]),
  {noreply, State};

%% change into active when no more active for stream change
handle_info({udp_passive, Socket}, State = #state{sock = Socket}) ->
  inet:setopts(Socket, [{active, 10}]),
  {noreply, State};

%% New Data arrived
handle_info({udp, Socket, IP, InPortNo, Packet}, State = #state{sock = Socket}) ->
  case try_handle_pkg(IP, InPortNo, Packet, State) of
    {ok, State2} ->
      {noreply, State2};
    {stop, Reason, State2} ->
      ?ERRORLOG("stoping kcp handler, reason ~p", [Reason]),
      {stop, Reason, State2};
    {error, Reason, State2} ->
      ?ERRORLOG("handle kcp pkg failed, reason ~p", [Reason]),
      {noreply, State2}
  end;

%% Flush all datas
handle_info(kcp_update, State) ->
  Keys = erlang:get(),
  Now = kcp_erlang_util:timestamp_ms(),
  [begin
     KCP2 = kcp_update(Now, State#state.sock, KCP),
     put(Key, KCP2)
   end || {Key, KCP} <- Keys, is_record(KCP, kcp_pcb)],
  timer:send_after(?KCP_UPDATE_INTERVAL, self(), kcp_update),
  {noreply, State};

handle_info({kcp_send, Key, Data}, State) when is_binary(Data) ->
  case get(Key) of
    undefined -> {noreply, State};
    KCP = #kcp_pcb{mss = Mss} ->
      DataList = kcp_erlang_util:binary_split(Data, Mss),
      KCP2 = kcp_send(KCP, DataList, length(DataList)),
      put(Key, KCP2),
      {noreply, State}
  end;

handle_info({kcp_send_datalist, Key, Datalist}, State) when is_list(Datalist) ->
  case get(Key) of
    undefined -> {noreply, State};
    KCP = #kcp_pcb{mss = Mss} ->
      SndFun = fun(Data, PCB) ->
        DL = kcp_erlang_util:binary_split(Data, Mss),
        kcp_send(PCB, DL, length(DL))
      end,
      KCP2 = lists:foldl(SndFun, KCP, Datalist),
      put(Key, KCP2),
      {noreply, State}
  end;

handle_info(Info, State) ->
  ?ERRORLOG("receiving unknown info[~p]", [Info]),
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


%%--------------------------------------------------------------------
%% @private
%% @doc
%% KCP related logic
%%--------------------------------------------------------------------
try_handle_pkg(IP, Port, Data, State) ->
  try
    handle_recv_pkg(IP, Port, Data, State)
  catch
    Error: Reason ->
      Stack = erlang:get_stacktrace(),
      ?ERRORLOG("Error occurs while processing udp package ~p", [Stack]),
      {error, {Error, Reason}, State}
  end.

handle_recv_pkg(IP, Port, Data, State) ->
  Args = {undefined, undefined},
  OldKCP = get({IP, Port}),
  case handle_recv_pkg2(OldKCP, IP, Port, State, Args, Data) of
    {ok, State2} ->
      KCP = get({IP, Port}),
      KCP2 = check_data_rcv(OldKCP, KCP),
      put({IP, Port}, KCP2),
      {ok, State2};
    {error, Reason, State2} ->
      ?ERRORLOG("proc kcp packag failed, reason [~p]", [Reason]),
      {error, Reason, State2};
    {stop, Reason, State2} -> {stop, Reason, State2}
  end.

%% No more data need to be processed.
handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, Una}, <<>>) ->
  case KCP of
    undefined ->
      {error, empty_data, State};
    #kcp_pcb{} ->
      KCP2 = kcp_rcv_finish(KCP, MaxAck, Una),
      put({IP, Port}, KCP2),
      {ok, State}
  end;

%% Sync message recved
handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _}, ?KCP_SEG(Conv, ?KCP_CMD_PUSH, Frg, Wnd, Ts, Sn, Una, Len, Data, Left)) ->
  case KCP of
    undefined when Conv =:= 0 ->
      {error, "first kcp package conv is zero", State};
    #kcp_pcb{conv = KConv} when Conv =/= KConv ->
      ?ERRORLOG("conv id not match ~p/~p", [KConv, Conv]),
      {error, "conv id not match"};
    _ ->
      {KCP2, State2} = case KCP of
        undefined ->
          Key = {IP, Port},
          #state{sock = Socket, callback = Callback, cb_opts = CallbackOpts, cb_args = CallbackArgs} = State,
          {ok, RecvPID} = Callback:start_link(CallbackOpts, CallbackArgs),
          PCB = #kcp_pcb{conv = Conv, key = Key, state = ?KCP_STATE_ACTIVE,
            rmt_wnd = Wnd, probe = ?KCP_SYNC_ACK_SEND, pid = RecvPID},
          put(Key, PCB),
          RecvPID ! {shoot, Socket, Conv, #kcp_ref{pid = self(), key = Key}},
          {PCB, State};
        PCB -> {PCB, State}
      end,
      KCP3 = kcp_parse_una(KCP2#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP4 = kcp_shrink_buf(KCP3),
      case Sn < (KCP4#kcp_pcb.rcv_nxt + KCP4#kcp_pcb.rcv_wnd) of
        false -> handle_recv_pkg2(KCP4, IP, Port, State2, {MaxAck, Una}, Left);
        true  ->
          KCP5 = kcp_ack_push(KCP4, Sn, Ts),
          KCP6 = case Sn >= KCP5#kcp_pcb.rcv_nxt of
            false -> KCP5;
            true  ->
              Seg = #kcp_seg{conv = Conv, cmd = ?KCP_CMD_PUSH, wnd = Wnd, frg = Frg, ts = Ts, sn = Sn, una = Una, len = Len, data = Data},
              kcp_parse_data(KCP5, Seg)
          end,
          handle_recv_pkg2(KCP6, IP, Port, State2, {MaxAck, Una}, Left)
      end
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _}, ?KCP_SEG(Conv, ?KCP_CMD_ACK, 0, Wnd, Ts, Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      ?ERRORLOG("recv unconnected ack seg from ~p", [{IP, Port}]),
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when Conv =/= KConv ->
      ?ERRORLOG("conv id not match ~p/~p", [KConv, Conv]),
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      KCP4 = kcp_update_ack(KCP3, KCP3#kcp_pcb.current - Ts),
      KCP5 = kcp_parse_ack(KCP4, Sn),
      KCP6 = kcp_shrink_buf(KCP5),
      MaxAck2 = case MaxAck of
        undefined -> Sn;
        MaxAck when Sn > MaxAck -> Sn;
        MaxAck -> MaxAck
      end,
      handle_recv_pkg2(KCP6, IP, Port, State, {MaxAck2, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _}, ?KCP_SEG(Conv, ?KCP_CMD_WASK, 0, Wnd, _Ts, _Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when KConv =/= Conv ->
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      KCP4 = KCP3#kcp_pcb{probe = KCP3#kcp_pcb.probe bor ?KCP_ASK_TELL},
      handle_recv_pkg2(KCP4, IP, Port, State, {MaxAck, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, State, {MaxAck, _}, ?KCP_SEG(Conv, ?KCP_CMD_WINS, 0, Wnd, _Ts, _Sn, Una, 0, _Data, Left)) ->
  case KCP of
    undefined ->
      {error, "cound not find kcp"};
    #kcp_pcb{conv = KConv} when KConv =/= Conv ->
      {error, "conv id not match"};
    #kcp_pcb{} ->
      KCP2 = kcp_parse_una(KCP#kcp_pcb{rmt_wnd = Wnd}, Una),
      KCP3 = kcp_shrink_buf(KCP2),
      handle_recv_pkg2(KCP3, IP, Port, State, {MaxAck, Una}, Left)
  end;

handle_recv_pkg2(KCP, IP, Port, _State, _MaxAck, _Data) ->
  ?ERRORLOG("recv unknown data ~p segment from ~p for pcb", [_Data, {IP, Port}, KCP]),
  {error, "unknown pkg format"}.


%% Increase FaskAck count for each segment
kcp_parse_fastack(KCP = #kcp_pcb{snd_una = SndUna, snd_nxt = SndNxt}, Sn)
    when SndUna > Sn; Sn >= SndNxt -> KCP;
kcp_parse_fastack(KCP, Sn) ->
  FirstIdx = kcp_erlang_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_fastack2(KCP#kcp_pcb.snd_buf, FirstIdx, Sn),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_fastack2(SndBuf, ?LAST_INDEX, _) -> SndBuf;
kcp_parse_fastack2(SndBuf, Idx, Sn) ->
  case kcp_erlang_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = kcp_erlang_buffer:next(SndBuf, Idx),
      kcp_parse_fastack2(SndBuf, Next, Sn);
    Seg when Seg#kcp_seg.sn > Sn ->
      kcp_parse_fastack2(SndBuf, ?LAST_INDEX, Sn);
    Seg = #kcp_seg{fastack = FastAck} ->
      Seg2 = Seg#kcp_seg{fastack = FastAck + 1},
      SndBuf2 = kcp_erlang_buffer:set_data(Idx, Seg2, SndBuf),
      Next = kcp_erlang_buffer:next(SndBuf2, Idx),
      kcp_parse_fastack2(SndBuf2, Next, Sn)
  end.

%% update kcp rx_rttval, rx_srtt and rx_rto
kcp_update_ack(KCP, RTT) when RTT < 0 -> KCP;
kcp_update_ack(KCP, RTT) ->
  KCP2 = case KCP#kcp_pcb.rx_srtt =:= 0 of
    true ->
      KCP#kcp_pcb{rx_srtt = RTT, rx_rttval = RTT div 2};
    false ->
      Delta = RTT - KCP#kcp_pcb.rx_srtt,
      Delta2 = ?IF(Delta < 0, -Delta, Delta),
      RxRttVal = (3 * KCP#kcp_pcb.rx_rttval + Delta2) div 4,
      RxSRttVal = (7 * KCP#kcp_pcb.rx_srtt + RTT) div 8,
      RxSRttVal2 = ?IF(RxSRttVal < 1, 1, RxSRttVal),
      KCP#kcp_pcb{rx_srtt = RxSRttVal2, rx_rttval = RxRttVal}
  end,
  Rto = KCP2#kcp_pcb.rx_srtt + lists:max([1, 4 * KCP2#kcp_pcb.rx_rttval]),
  Rto2 = ?IBOUND(KCP2#kcp_pcb.rx_minrto, Rto, ?KCP_RTO_MAX),
  KCP2#kcp_pcb{rx_rto = Rto2}.

%% recalculate the snd_una
kcp_shrink_buf(KCP) ->
  #kcp_pcb{snd_buf = SndBuf, snd_nxt = SndNxt} = KCP,
  case kcp_erlang_buffer:first(SndBuf) of
    ?LAST_INDEX -> KCP#kcp_pcb{snd_una = SndNxt};
    Idx ->
      Seg = kcp_erlang_buffer:get_data(Idx, SndBuf),
      KCP#kcp_pcb{snd_una = Seg#kcp_seg.sn}
  end.

%% Erase acked seg from snd_buf
kcp_parse_ack(KCP = #kcp_pcb{snd_una = SndUna, snd_nxt = SndNxt}, Sn)
    when SndUna > Sn; SndNxt =< Sn ->
  KCP;
kcp_parse_ack(KCP, Sn) ->
  First = kcp_erlang_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_ack2(KCP#kcp_pcb.snd_buf, First, ?LAST_INDEX, Sn),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_ack2(SndBuf, ?LAST_INDEX, _, _) -> SndBuf;
kcp_parse_ack2(SndBuf, Idx, Prev, Sn) ->
  {Next2, SndBuf2} = case kcp_erlang_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = kcp_erlang_buffer:next(Idx, SndBuf),
      {Next, SndBuf};
    Seg when Seg#kcp_seg.sn =:= Sn ->
      Buf2 = kcp_erlang_buffer:delete(Idx, Prev, SndBuf),
      {?LAST_INDEX, Buf2};
    Seg when Seg#kcp_seg.sn > Sn ->
      {?LAST_INDEX, SndBuf};
    Seg when Seg#kcp_seg.sn < Sn ->
      Next = kcp_erlang_buffer:next(Idx, SndBuf),
      {Next, SndBuf}
  end,
  kcp_parse_ack2(SndBuf2, Next2, Idx, Sn).

%% Erase all recved seg from snd_buf
kcp_parse_una(KCP, Una) ->
  First = kcp_erlang_buffer:first(KCP#kcp_pcb.snd_buf),
  SndBuf2 = kcp_parse_una2(KCP#kcp_pcb.snd_buf, First, ?LAST_INDEX, Una),
  KCP#kcp_pcb{snd_buf = SndBuf2}.

kcp_parse_una2(SndBuf, ?LAST_INDEX, _, _) -> SndBuf;
kcp_parse_una2(SndBuf, Idx, Prev, Una) ->
  {Next2, SndBuf2} = case kcp_erlang_buffer:get_data(Idx, SndBuf) of
    undefined ->
      Next = kcp_erlang_buffer:next(Idx, SndBuf),
      {Next, SndBuf};
    Seg when Seg#kcp_seg.sn >= Una ->
      {?LAST_INDEX, SndBuf};
    _ ->
      Next = kcp_erlang_buffer:next(Idx, SndBuf),
      Buf2 = kcp_erlang_buffer:delete(Idx, Prev, SndBuf),
      {Next, Buf2}
  end,
  kcp_parse_una2(SndBuf2, Next2, Idx, Una).

kcp_rcv_finish(KCP, MaxAck, Una) ->
  KCP2 = ?IF(MaxAck =:= undefined, KCP, kcp_parse_fastack(KCP, MaxAck)),
  kcp_rcv_finish2(KCP2, Una).

kcp_rcv_finish2(KCP = #kcp_pcb{snd_una = SndUna, cwnd = Cwnd, rmt_wnd = Rwnd}, Una)
  when SndUna =< Una; Cwnd >= Rwnd -> KCP;
kcp_rcv_finish2(KCP, _Una) ->
  #kcp_pcb{mss = Mss, cwnd = Cwnd, incr = Incr, ssthresh = Ssth, rmt_wnd = Rwnd} = KCP,
  {Cwnd2, Incr2} = case Cwnd < Ssth of
    true ->
      {Cwnd + 1, Incr + Mss};
    false ->
      In2 = ?MAX(Incr, Mss),
      In3 = In2 + (Mss * Mss) div In2 + (Mss div 16),
      C2 = ?IF((Cwnd + 1) * Mss =< In3, Cwnd + 1, Cwnd),
      {C2, In3}
  end,
  case Cwnd2 > Rwnd of
    false ->
      KCP#kcp_pcb{cwnd = Cwnd2, incr = Incr2};
    true  -> 
      KCP#kcp_pcb{cwnd = Rwnd, incr = Rwnd * Mss}
  end.

kcp_ack_push(KCP = #kcp_pcb{acklist = AckList}, Sn, Ts) ->
  KCP#kcp_pcb{acklist = [{Sn, Ts} | AckList]}.

kcp_parse_data(KCP = #kcp_pcb{rcv_nxt = RcvNxt, rcv_wnd = Rwnd}, #kcp_seg{sn = Sn})
    when Sn >= RcvNxt + Rwnd; Sn < RcvNxt -> KCP;
kcp_parse_data(KCP, Seg) ->
  #kcp_pcb{rcv_buf = RcvBuf, rcv_queue = RcvQue, rcv_nxt = RcvNxt} = KCP,
  First = kcp_erlang_buffer:first(RcvBuf),
  RcvBuf2 = kcp_parse_data2(RcvBuf, First, ?LAST_INDEX, Seg),
  {RcvNxt2, RcvBuf3, RcvQue2} = check_and_move(RcvNxt, RcvBuf2, RcvQue),
  KCP#kcp_pcb{rcv_buf = RcvBuf3, rcv_queue = RcvQue2, rcv_nxt = RcvNxt2}.

kcp_parse_data2(RcvBuf, ?LAST_INDEX, Prev, Seg) ->
  kcp_erlang_buffer:append(Prev, Seg, RcvBuf);
kcp_parse_data2(RcvBuf, Idx, Prev, Seg) ->
  Next = kcp_erlang_buffer:next(Idx, RcvBuf),
  case kcp_erlang_buffer:get_data(Idx, RcvBuf) of
    undefined ->
      RcvBuf;
    #kcp_seg{sn = Sn} when Sn =:= Seg#kcp_seg.sn -> RcvBuf;
    #kcp_seg{sn = Sn} when Sn < Seg#kcp_seg.sn ->
      kcp_parse_data2(RcvBuf, Next, Idx, Seg);
    #kcp_seg{sn = Sn} when Sn > Seg#kcp_seg.sn ->
      kcp_erlang_buffer:append(Prev, Seg, RcvBuf)
  end.

check_and_move(RcvNxt, RcvBuf, RcvQueue) ->
  First = kcp_erlang_buffer:first(RcvBuf),
  check_and_move2(RcvNxt, ?LAST_INDEX, First, RcvBuf, RcvQueue).

check_and_move2(RcvNxt, _, ?LAST_INDEX, RcvBuf, RcvQueue) ->
  {RcvNxt, RcvBuf, RcvQueue};
check_and_move2(RcvNxt, Prev, Idx, RcvBuf, RcvQueue) ->
  case kcp_erlang_buffer:get_data(Idx, RcvBuf) of
    undefined -> {RcvNxt, RcvBuf, RcvQueue};
    Seg = #kcp_seg{sn = Sn} when Sn =:= RcvNxt ->
      Next = kcp_erlang_buffer:next(Idx, RcvBuf),
      RcvBuf2 = kcp_erlang_buffer:delete(Idx, Prev, RcvBuf),
      RcvQueue2 = kcp_erlang_queue:in(Seg, RcvQueue),
      Prev2 = ?IF(kcp_erlang_buffer:first(RcvBuf2) =:= Next, ?LAST_INDEX, Idx),
      check_and_move2(RcvNxt + 1, Prev2, Next, RcvBuf2, RcvQueue2);
    _ -> {RcvNxt, RcvBuf, RcvQueue}
  end.

check_data_rcv(OldKCP, KCP) ->
  OldLen = ?IF(OldKCP =:= undefined, 0, kcp_erlang_queue:len(OldKCP#kcp_pcb.rcv_queue)),
  #kcp_pcb{rcv_queue = RcvQue, probe = Probe, rcv_nxt = RcvNxt, rcv_buf = RcvBuf,
    rcv_wnd = RcvWnd, pid = RecvPID} = KCP,
  Recover = kcp_erlang_queue:len(RcvQue) >= RcvWnd,
  case OldLen =:= kcp_erlang_queue:len(RcvQue) of
    true  -> KCP;
    false ->
      {RcvQue2, DataList} = check_data_rcv2(RcvQue, [], []),
      {RcvNxt2, RcvBuf2, RcvQue3} = check_and_move(RcvNxt, RcvBuf, RcvQue2),
      ?IF(DataList =:= [], ignore, RecvPID ! {kcp_data, KCP#kcp_pcb.conv, DataList}),
      Probe2 = ?IF(Recover and (kcp_erlang_queue:len(RcvQue3) < RcvWnd), Probe bor ?KCP_ASK_TELL, Probe),
      KCP#kcp_pcb{rcv_nxt = RcvNxt2, rcv_queue = RcvQue3, rcv_buf = RcvBuf2, probe = Probe2}
  end.

check_data_rcv2(RcvQue, PartList, DataList) ->
  case kcp_erlang_queue:is_empty(RcvQue) of
    true  -> {RcvQue, DataList};
    false ->
      case kcp_erlang_queue:get(RcvQue) of
        #kcp_seg{frg = Frg, data = Data} when Frg =:= 0 ->
          Data2 = kcp_erlang_util:binary_join(lists:reverse([Data | PartList])),
          RcvQue2 = kcp_erlang_queue:drop(RcvQue),
          check_data_rcv2(RcvQue2, [], [Data2 | DataList]);
        #kcp_seg{frg = Frg, data = Data} ->
          case kcp_erlang_queue:len(RcvQue) of
            QueSize when QueSize >= (Frg + 1) ->
              RcvQue2 = kcp_erlang_queue:drop(RcvQue),
              check_data_rcv2(RcvQue2, [Data | PartList], DataList);
            _ ->
              {RcvQue, DataList}
          end
      end
  end.

%% Flush all sndbuf data out
kcp_update(Now, Socket, KCP) ->
  #kcp_pcb{updated = Updated, ts_flush = TsFlush, interval = Interval} = KCP,
  {Updated2, TsFlush2} = ?IF(Updated =:= false, {true, Now}, {Updated, TsFlush}),
  Slap = Now - TsFlush2,
  {Slap2, TsFlush3} = case (Slap >= 10000) or (Slap < -10000) of
    true -> {0, Now};
    false -> {Slap, TsFlush2}
  end,
  case Slap2 >= 0 of
    false ->
      KCP#kcp_pcb{current = Now, ts_flush = TsFlush3, updated = Updated2};
    true  ->
      TsFlush4 = TsFlush3 + Interval,
      TsFlush5 = ?IF(Now > TsFlush4, Now + Interval, TsFlush4),
      kcp_flush(Socket, KCP#kcp_pcb{current = Now, ts_flush = TsFlush5, updated = Updated2})
  end.

%% Flush all data into the internet
kcp_flush(_Socket, KCP = #kcp_pcb{updated = false}) -> KCP;
kcp_flush(Socket, KCP) ->
  #kcp_pcb{conv = Conv, rcv_nxt = RcvNxt, rcv_queue = RcvQue, rcv_wnd = RWnd} = KCP,
  Wnd = ?IF(kcp_erlang_queue:len(RcvQue) < RWnd, RWnd - kcp_erlang_queue:len(RcvQue), 0),
  Seg = #kcp_seg{conv = Conv, cmd = ?KCP_CMD_ACK, frg = 0, wnd = Wnd, una = RcvNxt,
    ts = 0, sn = 0, len = 0},
  {KCP2, Buf2} = kcp_flush_ack(Socket, KCP, Seg),
  {KCP3, Buf3} = kcp_probe_wnd(Socket, KCP2, Seg, Buf2),
  {KCP4, Buf4} = kcp_flush_wnd(Socket, KCP3, Seg, Buf3),
%%  {KCP5, Buf4} = kcp_flush_sync(Socket, KCP4, Seg, Buf3),
%%  {KCP6, Buf5} = kcp_flush_syncack(Socket, KCP5, Seg, Buf4),
  {KCP5, {Buf5, _Size5}} = kcp_flush_data(Socket, KCP4#kcp_pcb{probe = 0}, Seg, Buf4),
  kcp_output2(Socket, KCP5#kcp_pcb.key, kcp_erlang_util:binary_join(Buf5)),
  KCP5.

kcp_flush_ack(Socket, KCP = #kcp_pcb{key = Key, acklist = AckList, mtu = Mtu}, Seg) ->
  Buf = kcp_flush_ack2(Socket, Key, Seg, AckList, {[], 0}, Mtu),
  {KCP#kcp_pcb{acklist = []}, Buf}.
kcp_flush_ack2(_Socket, _Key, _Seg, [], Buf, _Limit) -> Buf;
kcp_flush_ack2(Socket, Key, Seg, [{Sn, Ts} | Left], Buf, Limit) ->
  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
  Bin = ?KCP_SEG(Conv, ?KCP_CMD_ACK, 0, Wnd, Ts, Sn, Una, 0, <<>>, <<>>),
  Buf2 = kcp_output(Socket, Key, Bin, Buf, Limit),
  kcp_flush_ack2(Socket, Key, Seg, Left, Buf2, Limit).

%% Do not implement wnd probe right now
kcp_probe_wnd(Socket, KCP, Seg, Buf) ->
  KCP2 = kcp_update_probe(KCP),
  #kcp_pcb{key = Key, probe = Probe, mtu = Mtu} = KCP2,
  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
  case (Probe band ?KCP_ASK_SEND) =/= 0 of
    false -> {KCP2, Buf};
    true  ->
      Bin = ?KCP_SEG(Conv, ?KCP_CMD_WASK, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
      Buf2 = kcp_output(Socket, Key, Bin, Buf, Mtu),
      {KCP2, Buf2}
  end.
kcp_update_probe(KCP = #kcp_pcb{rmt_wnd = Rwnd}) when Rwnd =/= 0 ->
  KCP#kcp_pcb{ts_probe = 0, probe_wait = 0};
kcp_update_probe(KCP) ->
  #kcp_pcb{current = Current, ts_probe = TsProbe, probe_wait = PWait, probe = Probe} = KCP,
  case KCP#kcp_pcb.probe_wait =:= 0 of
    true ->
      KCP#kcp_pcb{probe_wait = ?KCP_PROBE_INIT, ts_probe = Current + ?KCP_PROBE_INIT};
    false when Current >= TsProbe ->
      PWait2 = ?IF(PWait < ?KCP_PROBE_INIT, ?KCP_PROBE_INIT, PWait),
      PWait3 = PWait2 + PWait2 div 2,
      PWait4 = ?IF(PWait3 > ?KCP_PROBE_LIMIT, ?KCP_PROBE_LIMIT, PWait3),
      TsProbe2 = Current + PWait4,
      Probe2 = Probe bor ?KCP_ASK_SEND,
      KCP#kcp_pcb{probe_wait = PWait4, ts_probe = TsProbe2, probe = Probe2};
    false ->
      KCP
  end.
kcp_flush_wnd(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
    when Probe band ?KCP_ASK_TELL =:= 0 -> {KCP, Buf};
kcp_flush_wnd(Socket, KCP, Seg, Buf) ->
  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
  Bin = ?KCP_SEG(Conv, ?KCP_CMD_WINS, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
  Buf2 = kcp_output(Socket, Key, Bin, Buf, Mtu),
  {KCP, Buf2}.


kcp_flush_data(Socket, KCP, Seg, Buf) ->
  #kcp_pcb{snd_wnd = SWnd, rmt_wnd = RWnd, nocwnd = NoCwnd, cwnd = CWnd,
    fastresend = FastResend, nodelay = NoDelay, rx_rto = RxRto, current = Current} = KCP,
  CalWnd = ?MIN(SWnd, RWnd),
  CalWnd2 = ?IF(NoCwnd =:= 0, ?MIN(CWnd, CalWnd), CalWnd),
  KCP2 = sndque_to_sndbuf(KCP, Seg#kcp_seg{ts = Current, resendts = Current, rto = RxRto}, CalWnd2),
  Resent = ?IF(FastResend > 0, FastResend, 16#FFFFFFFF),
  RtoMin = ?IF(NoDelay == 0, RxRto bsr 3, 0),
  Invariant = {Socket, Resent, RtoMin, KCP2, CalWnd2, Seg#kcp_seg.wnd},
  {KCP3, Buf2} = kcp_flush_data2(Invariant, Buf),
  {KCP3, Buf2}.

kcp_flush_data2(Invariant, Buf) ->
  {_, _, _, #kcp_pcb{snd_buf = SndBuf}, _, _} = Invariant,
  {KCP2, Buf2} = kcp_flush_data3(Invariant, SndBuf, kcp_erlang_buffer:first(SndBuf), Buf, false, false),
  {KCP2, Buf2}.

kcp_flush_data3(Invariant, SndBuf, ?LAST_INDEX, Buf, Change, Lost) ->
  {_, FastResent, _, KCP, CalcWnd, _} = Invariant,
  KCP2 = case Change of
    false -> KCP#kcp_pcb{snd_buf = SndBuf};
    true  ->
      #kcp_pcb{snd_nxt = SndNxt, snd_una = SndUna, mss = Mss} = KCP,
      Thresh2 = case (SndNxt - SndUna) div 2 of
        V when V < ?KCP_THRESH_MIN -> ?KCP_THRESH_MIN;
        V -> V
      end,
      CWnd2 = Thresh2 + FastResent,
      KCP#kcp_pcb{snd_buf = SndBuf, cwnd = CWnd2, incr = CWnd2 * Mss, ssthresh = Thresh2}
  end,
  KCP3 = case Lost of
    true ->
      Thresh3 = ?MAX(?KCP_THRESH_MIN, CalcWnd div 2),
      KCP2#kcp_pcb{ssthresh = Thresh3, cwnd = 1, incr = KCP2#kcp_pcb.mss};
    false -> KCP2
  end,
  KCP4 = case KCP3#kcp_pcb.cwnd < 1 of
    true -> KCP3#kcp_pcb{cwnd = 1, incr = KCP3#kcp_pcb.mss};
    false -> KCP3
  end,
  {KCP4, Buf};
kcp_flush_data3(Invariant, SndBuf, Idx, Buf, Change, Lost) ->
  {Socket, FastResent, RtoMin, KCP, _, SWnd} = Invariant,
  #kcp_pcb{current = Current, rx_rto = Rto, nodelay = NoDelay, mtu = Mtu, key = Key, rcv_nxt = RcvNxt} = KCP,
  Next = kcp_erlang_buffer:next(Idx, SndBuf),
  case kcp_erlang_buffer:get_data(Idx, SndBuf) of
    undefined ->
      kcp_flush_data3(Invariant, SndBuf, Next, Buf, Change, Lost);
    Seg = #kcp_seg{xmit = Xmit, resendts = ResentTs, fastack = FastAck, rto = SRto} ->
      {Send, Lost2, Change2, Seg2} = if
        Xmit =:= 0 ->
          S2 = Seg#kcp_seg{xmit = Xmit + 1, rto = Rto, resendts = Current + Rto + RtoMin},
          {true, Lost, Change, S2};
        Current >= ResentTs ->
          SRto2 = ?IF(NoDelay =:= 0, SRto + Rto, SRto + Rto div 2),
          S2 = Seg#kcp_seg{xmit = Xmit + 1, rto = SRto2, resendts = Current + SRto2},
          {true, true, Change, S2};
        FastAck >= FastResent ->
          S2 = Seg#kcp_seg{xmit = Xmit + 1, fastack = 0, resendts = Current + Rto},
          {true, Lost, true, S2};
        true -> {false, Lost, Change, Seg}
      end,

      SndBuf2 = case Send of
        true  -> kcp_erlang_buffer:set_data(Idx, Seg2, SndBuf);
        false -> SndBuf
      end,
      case Send =:= true of
        true ->
          Seg3 = Seg2#kcp_seg{ts = Current, wnd = SWnd, una = RcvNxt},
          #kcp_seg{conv = Conv, frg = Frg, wnd = Wnd, ts = Ts, sn = Sn, una = Una, len = Len, data = Data} = Seg3,
          Bin = ?KCP_SEG(Conv, ?KCP_CMD_PUSH, Frg, Wnd, Ts, Sn, Una, Len, Data, <<>>),
          Buf2 = kcp_output(Socket, Key, Bin, Buf, Mtu),
          ?DEBUGLOG("flush data3 for ~p ~p ~p", [Conv, Frg, Len]),
          SndBuf3 = kcp_erlang_buffer:set_data(Idx, Seg3, SndBuf2),
          kcp_flush_data3(Invariant, SndBuf3, Next, Buf2, Change2, Lost2);
        false ->
          kcp_flush_data3(Invariant, SndBuf2, Next, Buf, Change2, Lost2)
      end
  end.

sndque_to_sndbuf(KCP, Seg, CWnd) ->
  #kcp_pcb{snd_queue = SndQue, snd_buf = SndBuf, snd_nxt = SndNxt, snd_una = SndUna} = KCP,
  case kcp_erlang_queue:len(SndQue) =:= 0 of
    true -> KCP;
    false ->
      {SndNxt2, SndQue2, SndBuf2} = sndque_to_sndbuf2(SndNxt, SndUna + CWnd, Seg, SndQue, SndBuf),
      KCP#kcp_pcb{snd_nxt = SndNxt2, snd_queue = SndQue2, snd_buf = SndBuf2}
  end.
sndque_to_sndbuf2(SndNxt, Limit, _Seg, SndQue, SndBuf) when SndNxt >= Limit ->
  {SndNxt, SndQue, SndBuf};
sndque_to_sndbuf2(SndNxt, Limit, Seg, SndQue, SndBuf) ->
  #kcp_seg{frg = Frg, len = Len, data = Data} = kcp_erlang_queue:get(SndQue),
  SndQue2 = kcp_erlang_queue:drop(SndQue),
  NSeg = Seg#kcp_seg{cmd = ?KCP_CMD_PUSH, sn = SndNxt, frg = Frg, len = Len, data = Data},
  SndBuf2 = kcp_erlang_buffer:append_tail(NSeg, SndBuf),
  sndque_to_sndbuf2(SndNxt + 1, Limit, Seg, SndQue2, SndBuf2).

kcp_send(KCP, [], 0) -> KCP;
kcp_send(KCP = #kcp_pcb{snd_queue = SndQue}, [Data | Left], Frg) ->
  Seg = #kcp_seg{len = byte_size(Data), frg = Frg - 1, data = Data},
  SndQue2 = kcp_erlang_queue:in(Seg, SndQue),
  KCP2 = KCP#kcp_pcb{snd_queue = SndQue2},
  kcp_send(KCP2, Left, Frg - 1).

kcp_output(Socket, Key, Bin, {Buf, Size}, Limit) ->
  {Buf2, Size2} = case Size + ?KCP_OVERHEAD > Limit of
    true ->
      Data = kcp_erlang_util:binary_join(Buf),
      kcp_output2(Socket, Key, Data),
      {[], 0};
    false ->
      {Buf, Size}
  end,
  Size3 = Size2 + byte_size(Bin),
  Buf3 = [Bin | Buf2],
  {Buf3, Size3}.

kcp_output2(_Socket, _Key, <<>>) -> ok;
kcp_output2(Socket, {IP, Port}, Data) ->
  ?ERRORLOG("send udp data to ~p ~p",[{IP, Port}, Data]),
  case gen_udp:send(Socket, IP, Port, Data) of
    ok -> 
      ?ERRORLOG("send udp data ok ~n",[]),
      ok;
    {error, Reason} ->
      ?ERRORLOG("send udp data to ~p failed with reason ~p ~p", [{IP, Port}, Reason, size(Data)]),
      {error, Reason}
  end.

%%kcp_flush_syncack(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
%%    when Probe band ?KCP_SYNC_ACK_SEND =:= 0 -> {KCP, Buf};
%%kcp_flush_syncack(Socket, KCP, Seg, {Buf, Size}) ->
%%  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
%%  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
%%  Bin = ?KCP_SEG(Conv, ?KCP_CMD_SYNC_ACK, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
%%  Buf2 = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
%%  {KCP, Buf2}.
%%
%%kcp_flush_sync(_Socket, KCP = #kcp_pcb{probe = Probe}, _Seg, Buf)
%%    when Probe band ?KCP_SYNC_SEND =:= 0 -> {KCP, Buf};
%%kcp_flush_sync(Socket, KCP, Seg, {Buf, Size}) ->
%%  #kcp_pcb{key = Key, mtu = Mtu} = KCP,
%%  #kcp_seg{conv = Conv, wnd = Wnd, una = Una} = Seg,
%%  Bin = ?KCP_SEG(Conv, ?KCP_CMD_SYNC, 0, Wnd, 0, 0, Una, 0, <<>>, <<>>),
%%  Buf2 = kcp_output(Socket, Key, Bin, Buf, Size, Mtu),
%%  {KCP, Buf2}.

dump_kcp(#kcp_pcb{snd_buf = SndBuf, rcv_buf = RcvBuf}) ->
  NSndBuf = kcp_erlang_buffer:unused(SndBuf),
  NRcvBuf = kcp_erlang_buffer:unused(RcvBuf),
  ?DEBUGLOG("kcp state ~p", [{NSndBuf, NRcvBuf}]).
