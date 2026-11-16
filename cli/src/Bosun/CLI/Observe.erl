%% The BEAM twin of Observe.js: the five probes. Each answers and never
%% throws. TCP uses the BEAM's own sockets; the rest are the same shell lines
%% node runs, through Exec's `run/2`.
-module(bosun_cLI_observe@foreign).
-export([probeHttpImpl/0, probeTcpImpl/0, probePgidAliveImpl/0, probeSocketImpl/0, probeExecImpl/0]).

run(Line, Ms) -> bosun_cLI_exec@foreign:run(Line, Ms).

%% (host, port, path) -> the HTTP status as a string; "000" on any failure.
probeHttpImpl() ->
    fun(Host, Port, Path) ->
        Url = <<"http://", Host/binary, ":", (integer_to_binary(Port))/binary, Path/binary>>,
        case run(<<"curl -s -o /dev/null -w '%{http_code}' --max-time 3 ", Url/binary>>, 5000) of
            {0, Out, _} -> string:trim(Out);
            _ -> <<"000">>
        end
    end.

%% (host, port) -> does a TCP connect succeed within three seconds?
probeTcpImpl() ->
    fun(Host, Port) ->
        case gen_tcp:connect(binary_to_list(Host), Port, [], 3000) of
            {ok, Socket} -> gen_tcp:close(Socket), true;
            _ -> false
        end
    end.

%% (pidfile) -> is any process in the recorded process GROUP alive?
probePgidAliveImpl() ->
    fun(PidFile) ->
        case file:read_file(PidFile) of
            {ok, Text} ->
                case string:to_integer(string:trim(Text)) of
                    {Pgid, _} when is_integer(Pgid), Pgid > 1 ->
                        {Code, _, _} = run(<<"kill -0 -- -", (integer_to_binary(Pgid))/binary>>, 5000),
                        Code =:= 0;
                    _ -> false
                end;
            _ -> false
        end
    end.

%% (socket path) -> does the socket file exist?
probeSocketImpl() ->
    fun(Path) ->
        case file:read_file_info(Path) of {ok, _} -> true; _ -> false end
    end.

%% (command line) -> did it exit 0 within five seconds?
probeExecImpl() ->
    fun(Line) -> {Code, _, _} = run(Line, 5000), Code =:= 0 end.
