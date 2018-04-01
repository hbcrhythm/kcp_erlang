-module(kcp_erlang_queue).
-author('labihbc@gmail.com').

%% API
-export([new/0,
  len/1,
  drop/1,
  get/1,
  in/2,
  is_empty/1]).

-record(kcp_erlang_queue, {queue = queue:new(), len = 0}).

new() ->
  #kcp_erlang_queue{}.

len(Queue) ->
  Queue#kcp_erlang_queue.len.

drop(Queue) ->
  #kcp_erlang_queue{queue = Q, len = Len} = Queue,
  Q2 = queue:drop(Q),
  Queue#kcp_erlang_queue{queue = Q2, len = Len - 1}.

is_empty(#kcp_erlang_queue{len = Len}) when Len =:= 0 -> true;
is_empty(_) -> false.

get(#kcp_erlang_queue{queue = Q}) ->
  queue:get(Q).

in(Val, Queue) ->
  #kcp_erlang_queue{queue = Q, len = Len} = Queue,
  Q2 = queue:in(Val, Q),
  Queue#kcp_erlang_queue{queue = Q2, len = Len + 1}.
