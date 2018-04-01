-module(kcp_erlang_util).
-author('labihbc@gmail.com').

%% API
-export([
  timestamp/0,
  timestamp_ms/0,
  binary_join/1,
  binary_split/2]).

timestamp() ->
  erlang:system_time(seconds).

timestamp_ms() ->
  erlang:system_time(milli_seconds).

-spec binary_join([binary()]) -> binary().
binary_join([]) ->
  <<>>;
binary_join([Part]) ->
  Part;
binary_join(List) ->
  lists:foldr(fun (A, B) ->
    if
      bit_size(B) > 0 -> <<A/binary, B/binary>>;
      true -> A
    end
  end, <<>>, List).

binary_split(Data, Len) ->
  binary_split2(Len, Data, []).
binary_split2(_, <<>>, Rslt) -> lists:reverse(Rslt);
binary_split2(Len, Data, Rslt) ->
  case Data of
    <<Head:Len/bytes, Left/bitstring>> -> binary_split2(Len, Left, [Head | Rslt]);
    _ -> binary_split2(Len, <<>>, [Data | Rslt])
  end.
