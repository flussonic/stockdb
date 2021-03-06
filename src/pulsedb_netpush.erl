-module(pulsedb_netpush).
-author('Max Lapshin <max@maxidoors.ru>').

-export([open/2, append/2, read/3, sync/1, close/1]).



-record(netpush, {
  storage = ?MODULE,
  url,
  transport,
  socket,
  metrics = [],
  ping = 0,
  utc
}).

open(URL, Options) ->
  try open0(URL, Options)
  catch
    throw:R -> R
  end.

open0(URL, Options) ->
  {Transport, Socket} = case http_uri:parse(binary_to_list(URL)) of
    {ok, {pulse, _, Host, Port, _, _}} ->
      {ok, Sock} = case gen_tcp:connect(Host, Port, [binary,{active,false},{packet,http},{send_timeout,5000}], 5000) of
        {ok, S} -> {ok, S};
        {error, E} -> throw({error, E})
      end,
      {ranch_tcp, Sock};
    {ok, {pulses, _, Host, Port, _, _}} ->
      {ok, Sock} = case ssl:connect(Host, Port, [binary,{active,false},{packet,http},{send_timeout,5000}], 5000) of
        {ok, S} -> {ok, S};
        {error, E} -> throw({error, E})
      end,
      {ranch_ssl, Sock}
  end,

  Path = "/api/v1/pulse_push",


  ApiKey = case proplists:get_value(api_key, Options) of
    undefined -> [];
    K -> ["Pulsedb-Api-Key: ", K, "\r\n"]
  end,

  ConnectCmd = ["CONNECT ", Path, " HTTP/1.1\r\n",
    "Host: ", Host, "\r\n",
    ApiKey,
    "Connection: Upgrade\r\n"
    "Upgrade: application/timeseries-text\r\n"
    "\r\n"
  ],

  lager:debug("Connecting to pulsedb server:\n~s", [ConnectCmd]),

  case Transport:send(Socket, ConnectCmd) of
    ok -> ok;
    {error, E2} -> Transport:close(Socket), throw({error, E2})
  end,
  case Transport:recv(Socket, 0, 5000) of
    {ok, {http_response, _, 101, _}} -> ok;
    {ok, {http_response, _, 403, _}} -> Transport:close(Sock), throw({error, denied});
    {ok, {http_response, _, Code, _}} -> Transport:close(Sock), throw({error, {failure,Code}});
    {error, _} -> Transport:close(Sock), throw({error, closed})
  end,
  fetch_headers(Transport, Socket),
  Transport:setopts(Socket, [{packet,line}]),
  {ok, #netpush{url = URL, transport = Transport, socket = Socket}}.



append([], #netpush{} = DB) ->
  {ok, DB};

append([Tick|Ticks], #netpush{} = DB) ->
  case append(Tick, DB) of
    {ok, DB1} -> append(Ticks, DB1);
    {error, Error} -> {error, Error}
  end;

append({_,_,_,_} = Tick, #netpush{} = DB) ->
  try append0(Tick, DB)
  catch
    throw:R -> R
  end.


append0({Name, UTC, Value, Tags}, #netpush{metrics = Metrics, transport = T, socket = Socket, utc = UTC0} = DB) ->
  {Metrics1, Id} = case lists:keyfind({Name,Tags}, 1, Metrics) of
    false ->
      Metric = pulsedb_disk:metric_name(Name, Tags),
      I = integer_to_binary(length(Metrics)),
      case T:send(Socket, ["metric ", I," ", Metric, "\n"]) of
        ok -> ok;
        {error, E} -> throw({error, E})
      end,
      {[{{Name,Tags}, I}|Metrics], I};
    {_,I} ->
      {Metrics, I}
  end,
  UTCDelta = case UTC0 of
    undefined ->
      case T:send(Socket, ["utc ", integer_to_binary(UTC),"\n"]) of
        ok -> ok;
        {error, E2} -> throw({error, E2})
      end,
      <<"0">>;
    _ ->
      integer_to_binary(UTC - UTC0)
  end,
  case T:send(Socket, [Id, " ", UTCDelta, " ", shift_value(Value), "\n"]) of
    ok ->
      {ok, DB#netpush{metrics = Metrics1, utc = UTC}};
    {error, E3} ->
      {error, E3}
  end.


sync(#netpush{transport = T, socket = Socket, ping = I} = DB) ->
  case T:send(Socket, ["ping ", integer_to_list(I), "\n"]) of
    ok ->
      Pong = iolist_to_binary(["pong ", integer_to_list(I), "\n"]),
      case T:recv(Socket, 0, 5000) of
        {ok, Pong} ->
          {ok, DB#netpush{ping = I + 1}};
        {error, E1} ->
          {error, E1}
      end;
    {error, E2} ->
      {error, E2}
  end.



read(_Name, _Query, #netpush{} = DB) ->
  {ok, [], DB}.


close(#netpush{socket = Socket} = DB) ->
  gen_tcp:close(Socket),
  {ok, DB}.





shift_value(Value) when Value >= 0 andalso Value < 16#4000 -> integer_to_list(Value);
shift_value(Value) when Value >= 16#1000 andalso Value < 16#4000000 -> integer_to_list(Value bsr 10)++"K";
shift_value(Value) when Value >= 16#1000000 andalso Value < 16#400000000 -> integer_to_list(Value bsr 20)++"M";
shift_value(Value) when Value >= 16#1000000000 andalso Value < 16#200000000000 -> integer_to_list(Value bsr 30)++"G";
shift_value(Value) when Value >= 16#1000000000000 andalso Value < 16#200000000000000 -> integer_to_list(Value bsr 40)++"T".


fetch_headers(Transport, Sock) ->
  case Transport:recv(Sock, 0, 5000) of
    {ok, http_eoh} -> ok;
    {ok, {http_header, _, _, _, _}} -> fetch_headers(Transport, Sock)
  end.

