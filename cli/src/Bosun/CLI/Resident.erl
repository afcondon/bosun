%% The BEAM twin of Resident.js: the periodic tick and the /state + /control
%% HTTP surface. The decisions are made in PureScript; this fires the tick and
%% routes HTTP to the callbacks.
%%
%% node is single-threaded, so there a tick and an HTTP callback can never
%% interleave, and the PureScript behind them was written on that assumption.
%% Here ONE process (the owner) runs every tick and every callback, in turn,
%% and the connection handlers only ask it. That keeps the assumption true.
%%
%% The HTTP server is the BEAM's own socket layer with `{packet, http_bin}`;
%% no web server library is involved.
-module(bosun_cLI_resident@foreign).
-export([residentImpl/0, nowMs/0]).

nowMs() -> fun() -> float(erlang:system_time(millisecond)) end.

residentImpl() ->
    fun(Host, Admits, Cfg) ->
        #{statusPort := Port, intervalMs := IntervalMs} = Cfg,
        Owner = spawn(fun() ->
                          {ok, _} = timer:send_interval(IntervalMs, tick),
                          owner(Cfg)
                      end),
        {ok, Address} = inet:parse_address(binary_to_list(Host)),
        case gen_tcp:listen(Port, [binary, {packet, http_bin}, {active, false},
                                   {reuseaddr, true}, {ip, Address}]) of
            {ok, Listen} ->
                spawn(fun() -> accept(Listen, Owner, Admits) end),
                io:format("  resident: /state + /control on ~s:~b, tick ~bms.~n", [Host, Port, IntervalMs]);
            {error, Reason} ->
                io:format("  ✗ resident /state :~b (~p)~n", [Port, Reason])
        end,
        persistent_term:put(bosun_resident, true),
        unit
    end.

%% --- the owner: every tick and every callback, one at a time ---------------

owner(Cfg) ->
    receive
        tick ->
            flush_ticks(),
            try (maps:get(tick, Cfg))()
            catch Class:Reason -> io:format("  ✗ tick: ~p:~0p~n", [Class, Reason])
            end;
        {ask, From, Ref, Work} ->
            Reply = try {ok, Work(Cfg)} catch Class:Reason -> {error, {Class, Reason}} end,
            From ! {Ref, Reply}
    end,
    owner(Cfg).

%% A tick that overran its interval leaves ticks queued; run one, not a burst.
flush_ticks() -> receive tick -> flush_ticks() after 0 -> ok end.

ask(Owner, Work) ->
    Ref = make_ref(),
    Owner ! {ask, self(), Ref, Work},
    receive {Ref, Reply} -> Reply after 120000 -> {error, timeout} end.

%% --- HTTP -------------------------------------------------------------------

accept(Listen, Owner, Admits) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> receive go -> serve(Socket, Owner, Admits) end end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! go,
            accept(Listen, Owner, Admits);
        {error, closed} -> ok;
        {error, _} -> accept(Listen, Owner, Admits)
    end.

serve(Socket, Owner, Admits) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, Method, {abs_path, Target}, _}} ->
            Length = headers(Socket, 0),
            _ = body(Socket, Length),
            Peer = case inet:peername(Socket) of
                       {ok, {Ip, _}} -> list_to_binary(inet:ntoa(Ip));
                       _ -> <<>>
                   end,
            #{path := Path} = Parsed = uri_string:parse(Target),
            Query = case Parsed of
                        #{query := Q} -> uri_string:dissect_query(Q);
                        _ -> []
                    end,
            MethodName = if is_atom(Method) -> atom_to_binary(Method); true -> Method end,
            {Status, Type, Body} = route(MethodName, Path, Query, Peer, Owner, Admits),
            reply(Socket, Status, Type, Body);
        _ -> ok
    end,
    gen_tcp:close(Socket).

headers(Socket, Length) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_header, _, 'Content-Length', _, Value}} -> headers(Socket, binary_to_integer(Value));
        {ok, {http_header, _, _, _, _}} -> headers(Socket, Length);
        _ -> Length
    end.

body(_, 0) -> <<>>;
body(Socket, Length) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, Length, 10000) of {ok, B} -> B; _ -> <<>> end.

route(Method, Path, Query, Peer, Owner, Admits) ->
    case Admits(Peer, Method, Path) of
        false ->
            {403, <<"text/plain">>,
             <<"forbidden: /state is tailnet-readable at most; /control is local-only\n">>};
        true -> admitted(Method, Path, Query, Owner)
    end.

admitted(<<"OPTIONS">>, _, _, _) -> {204, none, <<>>};
admitted(<<"GET">>, Path, _, Owner) when Path =:= <<"/state">>; Path =:= <<"/">> ->
    case ask(Owner, fun(Cfg) -> (maps:get(stateBody, Cfg))() end) of
        {ok, Body} -> {200, <<"application/json">>, Body};
        {error, Reason} -> {500, <<"text/plain">>, iolist_to_binary(io_lib:format("~0p", [Reason]))}
    end;
admitted(<<"POST">>, <<"/control/", Verb/binary>>, Query, Owner) ->
    Arg = case {lists:keyfind(<<"service">>, 1, Query), lists:keyfind(<<"group">>, 1, Query)} of
              {{_, S}, _} when S =/= <<>>, S =/= true -> S;
              {_, {_, G}} when G =/= true -> G;
              _ -> <<>>
          end,
    case ask(Owner, fun(Cfg) -> (maps:get(control, Cfg))(Verb, Arg) end) of
        {ok, #{ok := Ok, message := Message}} ->
            {if Ok -> 200; true -> 400 end, <<"application/json">>, verdict(Ok, Message)};
        {error, Reason} ->
            {500, <<"application/json">>,
             verdict(false, iolist_to_binary(io_lib:format("~0p", [Reason])))}
    end;
admitted(_, _, _, _) -> {404, <<"text/plain">>, <<"not found\n">>}.

verdict(Ok, Message) ->
    data_argonaut_core@foreign:stringify([{<<"ok">>, Ok}, {<<"message">>, Message}]).

reply(Socket, Status, Type, Body) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    TypeLine = case Type of none -> []; _ -> ["content-type: ", Type, "\r\n"] end,
    gen_tcp:send(Socket,
                 ["HTTP/1.1 ", integer_to_binary(Status), " ", reason(Status), "\r\n",
                  TypeLine,
                  "access-control-allow-origin: *\r\n",
                  "access-control-allow-methods: GET,POST,OPTIONS\r\n",
                  "access-control-allow-headers: content-type\r\n",
                  "content-length: ", integer_to_binary(byte_size(Body)), "\r\n",
                  "connection: close\r\n\r\n",
                  Body]).

reason(200) -> "OK";
reason(204) -> "No Content";
reason(400) -> "Bad Request";
reason(403) -> "Forbidden";
reason(404) -> "Not Found";
reason(_) -> "Internal Server Error".
