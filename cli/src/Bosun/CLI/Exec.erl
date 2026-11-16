%% The BEAM twin of Exec.js (and Exec.go): run one shell line.
%%
%% The pure core writes the line; this only runs it. `run/2` is also the
%% primitive the other BEAM edges (Observe, IO) use for their shell probes.
%%
%% A line that ends in `&` is a launch: fire and forget. What makes Bosun's
%% launch lines work is that the launching shell has a process group of its
%% own, because the line records that group in a pidfile and later signals the
%% whole group. node gets this from `detached: true`. On the BEAM `open_port`
%% already starts every child as the leader of a new group (measured on macOS
%% and Linux, 2026-11-11), so no helper program is needed.
-module(bosun_cLI_exec@foreign).
-export([execLineImpl/0, run/2]).
-purs_ignore_exports([run/2]).

-define(LAUNCH_LOG, "/tmp/bosun-launch.log").

execLineImpl() -> fun(Line) -> exec_line(Line) end.

exec_line(Line) ->
    case re:run(Line, "&\\s*$", [{capture, none}]) of
        match -> launch(Line);
        nomatch ->
            case run(Line, 20000) of
                {0, Out, _} -> #{ok => true, code => 0, message => trim(Out)};
                {Code, _, Err} -> #{ok => false, code => Code, message => trim(Err)}
            end
    end.

%% The shell's own complaints (a bad cwd, a missing binary) go to the launch
%% log, as on node; the service's output goes wherever the line sends it.
launch(Line) ->
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", "{ eval \"$1\"; } >>\"$0\" 2>&1 </dev/null", ?LAUNCH_LOG, Line]},
                      exit_status, binary, hide]),
    _ = collect(Port, <<>>, deadline(20000)),
    #{ok => true, code => 0,
      message => <<"launched (backgrounded; output → /tmp/bosun-launch.log)"/utf8>>}.

%% Run a line to completion. {ExitCode, Stdout, Stderr}; a timeout kills the
%% line's whole process group and reads as exit 1.
run(Line, TimeoutMs) ->
    ErrFile = filename:join("/tmp", "bosun-beam-" ++ os:getpid() ++ "-" ++
                                    integer_to_list(erlang:unique_integer([positive])) ++ ".err"),
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", "exec 2>\"$0\" </dev/null; eval \"$1\"", ErrFile, Line]},
                      exit_status, binary, hide]),
    Result = collect(Port, <<>>, deadline(TimeoutMs)),
    Err = case file:read_file(ErrFile) of {ok, B} -> B; _ -> <<>> end,
    _ = file:delete(ErrFile),
    case Result of
        {exit, Code, Out} -> {Code, Out, Err};
        {timeout, Out} -> {1, Out, <<"timed out">>}
    end.

deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

collect(Port, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>, Deadline);
        {Port, {exit_status, Code}} -> {exit, Code, Acc}
    after Left ->
        case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} -> os:cmd("kill -KILL -- -" ++ integer_to_list(Pid) ++ " 2>/dev/null");
            _ -> ok
        end,
        catch port_close(Port),
        {timeout, Acc}
    end.

trim(B) -> unicode:characters_to_binary(string:trim(unicode:characters_to_list(B))).
