-define(APPLICATION, kcp_erlang).

-define(PACKET_TIMEOUT, 2 * 120 * 1000).
-define(FLUSH_INTERVAL, 20).
-define(UDP_SOCK_OPTS, [{port, 12346}, {active, 10}, {header, 0}, binary]).
-define(MAX_CONNECT, 10000).


-define(ERRORLOG(F, A), error_logger:error_msg(F, A)).
-define(DEBUGLOG(F, A), error_logger:info_msg(F, A)).
-define(IBOUND(L, V, M), if V < L -> L; V > M -> M; true -> V end).
-define(MIN(F, S), case F < S of true -> F; false -> S end).
-define(MAX(F, S), case F < S of true -> S; false -> F end).
-define(IF(C, T, F), case C of true -> T; false -> F end).

-define(CONV_START_LIMIT, 500).

-define(KCP_RTO_NDL, 30).
-define(KCP_RTO_MIN, 100).
-define(KCP_RTO_DEF, 200).
-define(KCP_RTO_MAX, 60000).

-define(KCP_CMD_PUSH, 81).
-define(KCP_CMD_ACK, 82).
-define(KCP_CMD_WASK, 83).
-define(KCP_CMD_WINS, 84).

-define(KCP_ASK_SEND, 1).        %% need to send KCP_CMD_WASK
-define(KCP_ASK_TELL, 2).        %% need to send KCP_CMD_WINS
-define(KCP_SYNC_SEND, 4).       %% need to send KCP_CMD_SYNC
-define(KCP_SYNC_ACK_SEND, 8).   %% need to send KCP_CMD_SYNC_ACK

-define(KCP_WND_SND, 128).
-define(KCP_WND_RCV, 128).
-define(KCP_MTU_DEF, 1400).
-define(KCP_ACK_FAST, 3).
-define(KCP_INTERVAL, 100).
-define(KCP_OVERHEAD, 24).
-define(KCP_DEADLINK, 20).
-define(KCP_THRESH_INIT, 2).
-define(KCP_THRESH_MIN, 2).
-define(KCP_PROBE_INIT, 7000).    %% 7 secs to probe window size
-define(KCP_PROBE_LIMIT, 120000). %% up to 120 secs to probe window

-define(KCP_UPDATE_INTERVAL, 50).

-define(KCP_STATE_ACTIVE, 1).
-define(KCP_STATE_DEAD, 0).

-define(LAST_INDEX, -1).
-record(kcp_buf, {data, index, used = ?LAST_INDEX, free = 0,
  size = 0, unused = 0, tail = ?LAST_INDEX}).

-record(kcp_seg, {conv = 0, cmd = 0, frg = 0, wnd = 0, ts = 0, sn = 0,
  una = 0, len = 0, resendts = 0, rto = 0, fastack = 0, xmit = 0, data = <<>>}).

-record(kcp_ref, {pid, key}).

-record(kcp_pcb, {
  conv = 0,
  mtu = ?KCP_MTU_DEF,
  mss = ?KCP_MTU_DEF - ?KCP_OVERHEAD,
  state = 0,
  snd_una = 0,
  snd_nxt = 0,
  rcv_nxt = 0,
  ts_recent = 0,
  ts_laskack = 0,
  ssthresh = ?KCP_THRESH_INIT,
  rx_rttval = 0,
  rx_srtt = 0,
  rx_rto = ?KCP_RTO_DEF,
  rx_minrto = ?KCP_RTO_MIN,
  snd_wnd = ?KCP_WND_SND,
  rcv_wnd = ?KCP_WND_RCV,
  rmt_wnd = ?KCP_WND_RCV,
  cwnd = 0,
  probe = 0,
  current = 0,
  interval = ?KCP_INTERVAL,
  ts_flush = ?KCP_INTERVAL,
  xmit = 0,
  nodelay = 0,
  updated = false,
  ts_probe = 0,
  probe_wait = 0,
  dead_link = ?KCP_DEADLINK,
  incr = 0,
  snd_queue = kcp_erlang_queue:new(),
  rcv_queue = kcp_erlang_queue:new(),
  snd_buf = kcp_erlang_buffer:new(?KCP_WND_SND, undefined),
  rcv_buf = kcp_erlang_buffer:new(?KCP_WND_RCV, undefined),
  acklist = [],
  datalist = [],
  ackcount = 0,
  ackblock = 0,
  fastresend = 0,
  nocwnd = 0,
  key,
  pid = undefined}).

-define(KCP_SEG(Conv, Cmd, Frg, Wnd, Ts, Sn, Una, Len, Data, Left),
  <<Conv:32/little, Cmd:8/little, Frg:8/little, Wnd:16/little, Ts:32/little, Sn:32/little, Una:32/little, Len:32/little, Data:Len/binary, Left/binary>>).

