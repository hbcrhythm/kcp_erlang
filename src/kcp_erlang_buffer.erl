-module(kcp_erlang_buffer).
-author('labihbc@Gmail.com').

-include("kcp_erlang.hrl").

%% API
-export([new/2, first/1, next/2, get_data/2,
    set_data/3, delete/3, append/3, append_tail/2,
    unused/1, size/1, dump/1]).

%% Create a new Buffer, the size must greater than 1
new(Size, Default) when is_integer(Size), Size >= 1 ->
  Data = array:new(Size, {default, Default}),
  Idx  = array:new(Size, {default, 0}),
  init(#kcp_buf{data = Data, index = Idx, size = Size, unused = Size});
new(_Size, _Default) ->
  {error, "size not integer or size less than 1"}.

init(Buf = #kcp_buf{index = Index}) ->
  Index2 = init_proc(Index, 0, array:size(Index) - 1),
  Buf#kcp_buf{index = Index2}.

init_proc(Index, Last, Last) ->
  array:set(Last, ?LAST_INDEX, Index);
init_proc(Index, Cur, Last) ->
  Index2 = array:set(Cur, Cur + 1, Index),
  init_proc(Index2, Cur + 1, Last).

%% Total size of the buffer
size(#kcp_buf{size = Size}) ->
  Size.

%% Left space of the buffer
unused(#kcp_buf{unused = Unused}) ->
  Unused.

%% Append a new value into Buf
append(Prev, Val, Buf) ->
  case alloc(Buf) of
    {_, ?LAST_INDEX} ->
      {error, "reach buffer limit"};
    {Buf2, Pos} when Prev =:= ?LAST_INDEX ->
      #kcp_buf{data = Data, index = Index, used = Used, tail = Tail} = Buf2,
      Index2 = array:set(Pos, Used, Index),
      Data2 = array:set(Pos, Val, Data),
      Tail2 = if
        Tail =:= ?LAST_INDEX -> Pos;
        true -> Tail
      end,
      Buf2#kcp_buf{data = Data2, index = Index2, used = Pos, tail = Tail2};
    {Buf2, Pos} ->
      #kcp_buf{data = Data, index = Index, tail = Tail} = Buf2,
      Next = array:get(Prev, Index),
      Index2 = array:set(Pos, Next, Index),
      Index3 = array:set(Prev, Pos, Index2),
      Data2 = array:set(Pos, Val, Data),
      Tail2 = if
        Tail =:= Prev -> Pos;
        true -> Tail
      end,
      Buf2#kcp_buf{data = Data2, index = Index3, tail = Tail2}
  end.

append_tail(Val, Buf) ->
  append(Buf#kcp_buf.tail, Val, Buf).


first(#kcp_buf{used = Used}) ->
  Used.

next(Prev, #kcp_buf{index = Index}) ->
  array:get(Prev, Index).

get_data(Pos, #kcp_buf{data = Data}) ->
  array:get(Pos, Data).

set_data(Pos, Val, Buf = #kcp_buf{data = Data}) ->
  Data2 = array:set(Pos, Val, Data),
  Buf#kcp_buf{data = Data2}.

%% Get a new free idx for use
alloc(Buf = #kcp_buf{free = ?LAST_INDEX}) -> {Buf, ?LAST_INDEX};
alloc(Buf) ->
  #kcp_buf{free = Free, index = Index, unused = Unused} = Buf,
  Pos = array:get(Free, Index),
  Buf2 = Buf#kcp_buf{free = Pos, index = Index, unused = Unused - 1},
  {Buf2, Free}.


delete(Pos, ?LAST_INDEX, Buf = #kcp_buf{used = Used}) when Used =/= Pos ->
  Buf;
delete(Pos, ?LAST_INDEX, Buf) ->
  #kcp_buf{index = Index, free = Free, data = Data, unused = Unused, tail = Tail} = Buf,
  Data2 = array:set(Pos, undefined, Data),
  Next = array:get(Pos, Index),
  Index2 = array:set(Pos, Free, Index),
  Tail2 = if
    Tail =:= Pos -> ?LAST_INDEX;
    true -> Tail
  end,
  Buf#kcp_buf{data = Data2, index = Index2, used = Next, free = Pos, unused = Unused + 1, tail = Tail2};
delete(Pos, Prev, Buf) ->
  #kcp_buf{index = Index, free = Free, data = Data, unused = Unused, tail = Tail} = Buf,
  Data2 = array:set(Pos, undefined, Data),
  Next = array:get(Pos, Index),
  Index2 = array:set(Prev, Next, Index),
  Index3 = array:set(Pos, Free, Index2),
  Tail2 = if
    Tail =:= Pos -> Prev;
    true -> Tail
  end,
  Buf#kcp_buf{data = Data2, index = Index3, free = Pos, unused = Unused + 1, tail = Tail2}.

dump(#kcp_buf{index = Index, free = Free, used = Used}) ->
  {Free, Used, Index}.
