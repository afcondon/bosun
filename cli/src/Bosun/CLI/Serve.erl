%% `bosun serve` on the BEAM: the lazy-spawn router.
%%
%% Not a translation of Serve.js. What the router must DO is written down as
%% docs/SERVE-BEHAVIOURS.md and held by scripts/serve-behaviours/run.mjs,
%% which runs against either router; this file is built to that list on what
%% the BEAM is good at. The decisions are still PureScript's (`Bosun.Serve`:
%% what is admitted, what a reload changes, what drifted, whether a brokered
%% service may be stopped, what its door is called), and `/state` and
%% `/where` are printed by PureScript through their descriptions.
%%
%% The processes:
%%
%%   router         one. Holds the tables, runs every PureScript callback
%%                  (reload, drift), answers /state. Restarts a keeper that
%%                  dies.
%%   route keeper   one per lazy-spawn route. Owns the listener on the public
%%                  port and the backend's lifetime: down, starting, up,
%%                  stopping. Every request asks it for the backend and it
%%                  answers when the backend listens, so many requests start
%%                  one process.
%%   broker keeper  one per brokered service. Owns the service's lifetime
%%                  and, when it has a registered port, the 307 door on it.
%%   connection     one per accepted connection, on every listener.
%%
%% A relayed connection is a tunnel. The request head is read, the backend is
%% ensured, the head is replayed, and from there bytes are carried both ways
%% until either side closes. A plain request is replayed with
%% `Connection: close`, so one connection carries one exchange; an Upgrade is
%% replayed as it came. Nothing between the head and the close is parsed,
%% which is why a body of any size or encoding, a streamed answer and a
%% WebSocket are the same code.
%%
%% A backend is idle when no connection is open through it, and is stopped
%% after the route's idle time in that condition. The keeper counts
%% connections by monitoring them, so a connection that crashes is counted
%% out like one that closes.
%%
%% A backend is launched by `open_port`, which makes it the leader of its own
%% process group (Exec.erl has the measurement). Stopping it signals the
%% group and waits for the GROUP to be gone, not for the launching shell.
-module(bosun_cLI_serve@foreign).
-export([serveImpl/0, resolveStatusPort/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).
-purs_ignore_exports([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-define(HOST, {127, 0, 0, 1}).
-define(WAIT_TIMEOUT_MS, 30000).  % how long a started backend has to listen
-define(WAIT_POLL_MS, 100).
-define(PROXY_TIMEOUT_MS, 8000).  % silence before the answer begins: 504
-define(PROBE_TIMEOUT_MS, 750).
-define(WATCH_MS, 5000).          % how often a claim about the world is re-checked
-define(STOP_GRACE_MS, 3000).     % SIGTERM, then SIGKILL after this
-define(STOP_GIVEUP_MS, 1500).    % and this long after SIGKILL, stop waiting
-define(DRIFT_TTL_MS, 5000).
-define(HEAD_LIMIT, 65536).
-define(HEAD_TIMEOUT_MS, 10000).

%% --- the two foreign imports ------------------------------------------------

resolveStatusPort() ->
    fun() ->
        case env_integer("BOSUN_SERVE_STATUS_PORT") of
            N when is_integer(N), N > 0, N < 65536 -> N;
            _ -> 3997
        end
    end.

serveImpl() ->
    fun(Config) ->
        Router = spawn(fun() -> router_init(Config) end),
        ok = signals(Router),
        persistent_term:put(bosun_resident, true),
        unit
    end.

env_integer(Name) ->
    case os:getenv(Name) of
        false -> none;
        Text -> case string:to_integer(Text) of {N, []} -> N; _ -> none end
    end.

%% --- signals ----------------------------------------------------------------
%%
%% The VM's own handler answers SIGTERM by stopping the VM, which closes every
%% port and signals nothing: the backends would be left running. This one asks
%% the router to stop them first. SIGHUP is a reload. (SIGINT cannot be
%% handled on the BEAM; a router stopped with Ctrl-C leaves its backends, and
%% the next router clears them before it binds.)

signals(Router) ->
    ok = os:set_signal(sighup, handle),
    ok = os:set_signal(sigterm, handle),
    _ = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    ok = gen_event:add_handler(erl_signal_server, ?MODULE, Router),
    ok.

init(Router) -> {ok, Router}.
handle_event(sighup, Router) -> Router ! reload_signal, {ok, Router};
handle_event(sigterm, Router) ->
    Router ! teardown,
    %% whatever state the router is in, the process ends
    spawn(fun() -> timer:sleep(2000), erlang:halt(0) end),
    {ok, Router};
handle_event(sigusr1, _) -> erlang:halt("Received SIGUSR1");
handle_event(sigquit, _) -> erlang:halt();
handle_event(_, Router) -> {ok, Router}.
handle_call(_, Router) -> {ok, ok, Router}.
handle_info(_, Router) -> {ok, Router}.
terminate(_, _) -> ok.
code_change(_, Router, _) -> {ok, Router}.

%% --- asking a process -------------------------------------------------------

call(Pid, Request) -> call(Pid, Request, 60000).
call(Pid, Request, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {call, {self(), Ref}, Request},
    receive
        {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, _, _, _} -> gone
    after Timeout -> erlang:demonitor(Ref, [flush]), timeout
    end.

reply(none, _) -> ok;
reply({Pid, Ref}, Reply) -> Pid ! {Ref, Reply}, ok.

%% Ask several processes the same thing at once and wait for them all.
call_all(Pids, Request, Timeout) ->
    Asked = [begin
                 Ref = erlang:monitor(process, Pid),
                 Pid ! {call, {self(), Ref}, Request},
                 Ref
             end || Pid <- Pids],
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    [receive
         {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
         {'DOWN', Ref, _, _, _} -> gone
     after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
         erlang:demonitor(Ref, [flush]), timeout
     end || Ref <- Asked].

%% =============================================================================
%% The router
%% =============================================================================

router_init(Config) ->
    Routes = array:to_list(maps:get(routes, Config)),
    try sweep_orphans(Routes)
    catch Class:Reason -> say("  x orphan sweep failed: ~0p:~0p; binding anyway", [Class, Reason])
    end,
    S0 = #{config => Config,
           routes => [],        % [{PublicPort, KeeperPid, Route}]
           brokers => [],       % [{ServiceId, KeeperPid, Broker}]
           redirects => [],     % [{PublicPort, ListenSocket | none, Redirect}]
           rejected => maps:get(rejected, Config),
           planned_at => now_iso(),
           drift => {unset, 0, array:new()},
           registry_error => null},
    S1 = lists:foldl(fun add_route/2, S0, Routes),
    S2 = lists:foldl(fun(B, S) -> open_door(B, add_broker(B, S)) end, S1,
                     array:to_list(maps:get(brokers, Config))),
    S3 = lists:foldl(fun add_redirect/2, S2, array:to_list(maps:get(redirects, Config))),
    control_listen(maps:get(statusPort, Config), Config),
    router(S3).

router(S) ->
    receive
        {call, From, state} ->
            {Text, Facts, S1} = state_now(S),
            reply(From, {ok, Text, Facts}),
            router(S1);
        {call, From, reload} ->
            try apply_reload(S) of
                {Summary, S1} -> reply(From, {ok, Summary}), router(S1)
            catch Class:Reason ->
                reply(From, {error, describe(Class, Reason)}),
                router(S)
            end;
        {call, From, {locate, Id, Port}} ->
            reply(From, locate(Id, Port, S)),
            router(S);
        reload_signal ->
            try apply_reload(S) of
                {_, S1} -> router(S1)
            catch Class:Reason ->
                say("  x reload failed: ~ts", [describe(Class, Reason)]),
                router(S)
            end;
        teardown ->
            _ = call_all([Pid || {_, Pid, _} <- maps:get(routes, S)], teardown, 1500),
            erlang:halt(0);
        {'DOWN', _, process, _, normal} ->
            router(S);
        {'DOWN', _, process, Pid, Reason} ->
            router(restart_keeper(Pid, Reason, S));
        _ ->
            router(S)
    end.

add_route(Route, S = #{routes := Routes}) ->
    {Pid, _} = spawn_monitor(fun() -> route_init(Route) end),
    S#{routes := Routes ++ [{maps:get(publicPort, Route), Pid, Route}]}.

%% A brokered service keeps its place in the list across a reload that did
%% not change it, and so keeps the process it started.
add_broker(B, S = #{brokers := Brokers}) ->
    Id = maps:get(serviceId, B),
    case lists:keyfind(Id, 1, Brokers) of
        {Id, Pid, Old} ->
            case same_broker(Old, B) of
                true ->
                    _ = call(Pid, {update, B}),
                    S#{brokers := lists:keyreplace(Id, 1, Brokers, {Id, Pid, B})};
                false ->
                    %% a different service under the same name. The old
                    %% keeper lets go of its process without stopping it:
                    %% forgetting a daemon is no reason to take its device.
                    _ = call(Pid, forget),
                    {New, _} = spawn_monitor(fun() -> broker_init(B) end),
                    S#{brokers := lists:keyreplace(Id, 1, Brokers, {Id, New, B})}
            end;
        false ->
            {New, _} = spawn_monitor(fun() -> broker_init(B) end),
            S#{brokers := Brokers ++ [{Id, New, B}]}
    end.

open_door(B, S = #{brokers := Brokers}) ->
    case lists:keyfind(maps:get(serviceId, B), 1, Brokers) of
        {_, Pid, _} -> _ = call(Pid, open_door), S;
        false -> S
    end.

add_redirect(Rd, S = #{redirects := Redirects}) ->
    #{publicPort := Port, serviceId := Id, host := Host, target := Target} = Rd,
    Listen = case listen(Port) of
                 {ok, L} ->
                     spawn(fun() -> accept(L, fun(Socket) -> redirect_connection(Socket, Rd) end) end),
                     say("  bound :~b -> 421 -> ~ts (~ts on ~ts)", [Port, Target, Id, Host]),
                     L;
                 {error, Reason} ->
                     say("  x cannot bind redirect :~b (~ts)", [Port, upper(Reason)]),
                     none
             end,
    S#{redirects := Redirects ++ [{Port, Listen, Rd}]}.

%% A keeper that died took its listener with it. Start another: a backend it
%% had started is still on the internal port, and the new keeper relays to
%% what it finds there.
restart_keeper(Pid, Reason, S = #{routes := Routes, brokers := Brokers}) ->
    case {lists:keyfind(Pid, 2, Routes), lists:keyfind(Pid, 2, Brokers)} of
        {{Port, Pid, Route}, _} ->
            say("  x the keeper of :~b (~ts) died: ~0p; starting another",
                [Port, maps:get(serviceId, Route), Reason]),
            {New, _} = spawn_monitor(fun() -> route_init(Route) end),
            S#{routes := lists:keyreplace(Pid, 2, Routes, {Port, New, Route})};
        {_, {Id, Pid, B}} ->
            say("  x the keeper of ~ts died: ~0p; starting another", [Id, Reason]),
            {New, _} = spawn_monitor(fun() -> broker_init(B) end),
            _ = call(New, open_door),
            S#{brokers := lists:keyreplace(Pid, 2, Brokers, {Id, New, B})};
        _ -> S
    end.

%% Who answers to this service name, or to this port? A brokered service
%% answers to its registered port and to the port it listens on.
locate(Id, Port, #{routes := Routes, brokers := Brokers, redirects := Redirects}) ->
    Broker = case Id of
                 <<>> -> [X || X = {_, _, B} <- Brokers,
                               maps:get(publicPort, B) =:= Port orelse maps:get(port, B) =:= Port];
                 _ -> [X || X = {BrokerId, _, _} <- Brokers, BrokerId =:= Id]
             end,
    Route = case Id of
                <<>> -> [X || X = {RoutePort, _, _} <- Routes, RoutePort =:= Port];
                _ -> [X || X = {_, _, R} <- Routes, maps:get(serviceId, R) =:= Id]
            end,
    Redirect = case Id of
                   <<>> -> [Rd || {RedirectPort, _, Rd} <- Redirects, RedirectPort =:= Port];
                   _ -> []
               end,
    case {Broker, Route, Redirect} of
        {[{_, Pid, B} | _], _, _} -> {broker, Pid, B};
        {_, [{_, Pid, R} | _], _} -> {route, Pid, R};
        {_, _, [Rd | _]} -> {redirect, maps:get(serviceId, Rd)};
        _ -> none
    end.

%% --- /state -----------------------------------------------------------------

state_now(S = #{config := Config, routes := Routes, brokers := Brokers, redirects := Redirects}) ->
    RouteFacts = snapshots([Pid || {_, Pid, _} <- Routes]),
    BrokerFacts = snapshots([Pid || {_, Pid, _} <- Brokers]),
    {Drift, S1} = drift_now(S),
    {_, ModifiedAt, _} = source_info(Config),
    Facts = #{routes => array:from_list(RouteFacts),
              brokered => array:from_list(BrokerFacts),
              redirects => array:from_list([Rd || {_, _, Rd} <- Redirects]),
              rejected => maps:get(rejected, S1),
              drift => Drift,
              registry => #{source => maps:get(source, Config),
                            plannedAt => maps:get(planned_at, S1),
                            modifiedAt => ModifiedAt,
                            error => maps:get(registry_error, S1)}},
    {(maps:get(stateText, Config))(Facts), Facts, S1}.

%% Each keeper re-checks its claims about the world, then says what it holds.
snapshots(Pids) ->
    _ = call_all(Pids, recheck, 5000),
    [Facts || Facts <- call_all(Pids, snapshot, 5000), is_map(Facts)].

%% The registry file's identity: modification time and size. {Stamp,
%% ModifiedAt, Error}; a URL source has no stamp.
source_info(Config) ->
    case maps:get(sourceFile, Config) of
        null -> {none, null, null};
        File ->
            case file:read_file_info(File, [{time, posix}]) of
                {ok, Info} ->
                    Modified = element(6, Info),
                    {{Modified, element(2, Info)}, iso(Modified * 1000), null};
                {error, Reason} ->
                    {none, null, iolist_to_binary(io_lib:format("cannot read ~ts: ~ts", [File, Reason]))}
            end
    end.

%% What the registry on disk says that the router has not admitted. A check
%% that could not be made is never kept as an answer: it is retried, and the
%% reason goes into /state.
drift_now(S = #{config := Config, drift := {Stamp, At, Entries}, registry_error := Was}) ->
    {Now, _, InfoError} = source_info(Config),
    Time = erlang:monotonic_time(millisecond),
    Fresh = Time - At < ?DRIFT_TTL_MS,
    Cached = if
                 Was =/= null -> Fresh;
                 Now =/= none -> Stamp =:= Now;
                 true -> Stamp =:= none andalso Fresh
             end,
    case Cached of
        true -> {Entries, S};
        false ->
            {Found, Error} =
                case InfoError of
                    null ->
                        try {(maps:get(drift, Config))(), null}
                        catch Class:Reason ->
                            {array:new(), iolist_to_binary(["drift check failed: ", describe(Class, Reason)])}
                        end;
                    _ -> {array:new(), InfoError}
                end,
            if Error =/= null, Error =/= Was -> say("  x ~ts", [Error]);
               Error =:= null, Was =/= null -> say("  registry readable again", []);
               true -> ok
            end,
            Kept = case Error of null -> Now; _ -> none end,
            {Found, S#{drift := {Kept, Time, Found}, registry_error := Error}}
    end.

%% --- reload -----------------------------------------------------------------
%%
%% PureScript re-reads and re-plans (`reload`) and answers with the
%% difference. Ports that went or changed are let go first, and their
%% backends are gone before anything is bound in their place.

apply_reload(S0 = #{config := Config}) ->
    Diff = (maps:get(reload, Config))(),
    Unbind = array:to_list(maps:get(unbind, Diff)),
    BindRoutes = array:to_list(maps:get(bindRoutes, Diff)),
    BindBrokers = array:to_list(maps:get(bindBrokers, Diff)),
    Fresh = array:to_list(maps:get(brokers, Diff)),
    BindRedirects = array:to_list(maps:get(bindRedirects, Diff)),
    S1 = unbind_ports(Unbind, S0),
    S2 = lists:foldl(fun add_route/2, S1, BindRoutes),
    S3 = forget_brokers([maps:get(serviceId, B) || B <- Fresh], S2),
    S4 = lists:foldl(fun add_broker/2, S3, Fresh),
    S5 = lists:foldl(fun open_door/2, S4, BindBrokers),
    S6 = lists:foldl(fun add_redirect/2, S5, BindRedirects),
    S7 = S6#{rejected := maps:get(rejected, Diff),
             planned_at := now_iso(),
             drift := {unset, 0, array:new()}},
    %% A reload compares configuration. The world can have moved with the
    %% configuration standing still, so the claims are re-checked as part of it.
    _ = call_all([Pid || {_, Pid, _} <- maps:get(routes, S7)] ++
                 [Pid || {_, Pid, _} <- maps:get(brokers, S7)], recheck, 5000),
    say("  reload applied: -~b unbound, +~b proxy, +~b redirect, ~b brokered, ~b refused",
        [length(Unbind), length(BindRoutes), length(BindRedirects), length(Fresh),
         array:size(maps:get(rejected, Diff))]),
    Summary = #{unbound => Unbind,
                boundRoutes => [maps:get(publicPort, R) || R <- BindRoutes],
                boundRedirects => [maps:get(publicPort, R) || R <- BindRedirects],
                brokers => [maps:get(serviceId, B) || B <- Fresh],
                boundBrokers => [maps:get(serviceId, B) || B <- BindBrokers]},
    {Summary, S7}.

unbind_ports(Ports, S = #{routes := Routes, brokers := Brokers, redirects := Redirects}) ->
    Going = [Pid || {Port, Pid, _} <- Routes, lists:member(Port, Ports)],
    _ = call_all(Going, unbind, 2 * (?STOP_GRACE_MS + ?STOP_GIVEUP_MS)),
    _ = [call(Pid, close_door) || {_, Pid, B} <- Brokers, lists:member(maps:get(publicPort, B), Ports)],
    _ = [gen_tcp:close(Listen) || {Port, Listen, _} <- Redirects, lists:member(Port, Ports), Listen =/= none],
    _ = [say("  unbound :~b", [Port]) || Port <- Ports],
    S#{routes := [X || X = {Port, _, _} <- Routes, not lists:member(Port, Ports)],
       redirects := [X || X = {Port, _, _} <- Redirects, not lists:member(Port, Ports)]}.

%% A brokered service the fresh plan no longer has is dropped WITHOUT being
%% stopped.
forget_brokers(Keep, S = #{brokers := Brokers}) ->
    {Kept, Dropped} = lists:partition(fun({Id, _, _}) -> lists:member(Id, Keep) end, Brokers),
    _ = [call(Pid, forget) || {_, Pid, _} <- Dropped],
    S#{brokers := Kept}.

same_broker(A, B) ->
    lists:all(fun(Key) -> maps:get(Key, A) =:= maps:get(Key, B) end,
              [launchCommand, cwd, transport, host, port, path, probe]).

%% =============================================================================
%% What a route keeper and a broker keeper share: one child process
%% =============================================================================
%%
%% Keys in the keeper's state:
%%   child     none | {Port, OsPid}      the process this keeper started
%%   phase     down | starting | up | stopping
%%   poller    none | {Pid, Ref}         the process waiting for readiness
%%   waiters   [From]                    callers waiting for `starting` to end
%%   stop      none | #{ref, pid, waiters}
%%   pending   [From]                    callers that asked during `stopping`

child_state() ->
    #{child => none, phase => down, poller => none, waiters => [], stop => none, pending => []}.

%% Start a command in its own process group, output appended to a log.
launch(ServiceId, Command, Cwd) ->
    Log = <<"/tmp/bosun-serve-", (sanitize(ServiceId))/binary, ".log">>,
    case os:find_executable("bash") of
        false -> {error, <<"no bash on PATH">>};
        Bash ->
            say("  spawn ~ts: ~ts  (cwd ~ts, log ~ts)", [ServiceId, Command, Cwd, Log]),
            try
                Port = open_port({spawn_executable, Bash},
                                 [{args, [<<"-c">>, <<"exec >>\"$0\" 2>&1 </dev/null; eval \"$1\"">>, Log, Command]},
                                  {cd, Cwd}, exit_status, binary, hide]),
                {os_pid, OsPid} = erlang:port_info(Port, os_pid),
                {ok, {Port, OsPid}}
            catch error:Reason ->
                {error, iolist_to_binary(io_lib:format("could not start it in ~ts: ~0p", [Cwd, Reason]))}
            end
    end.

signal_group(OsPid, Signal) ->
    _ = os:cmd("kill -" ++ Signal ++ " -- -" ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
    ok.

group_alive(OsPid) ->
    os:cmd("kill -0 -- -" ++ integer_to_list(OsPid) ++ " 2>/dev/null && echo y") =/= [].

%% Wait for `Check` to hold, off the keeper's own process so the keeper keeps
%% answering. The answer comes back as {polled, Ref, ok | timeout}.
start_poller(Check, S) ->
    Keeper = self(),
    Ref = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + ?WAIT_TIMEOUT_MS,
    Pid = spawn(fun() -> poll(Check, Deadline, Keeper, Ref) end),
    S#{poller := {Pid, Ref}}.

poll(Check, Deadline, Keeper, Ref) ->
    case Check() of
        true -> Keeper ! {polled, Ref, ok};
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> Keeper ! {polled, Ref, timeout};
                false -> timer:sleep(?WAIT_POLL_MS), poll(Check, Deadline, Keeper, Ref)
            end
    end.

cancel_poller(S = #{poller := {Pid, _}}) -> exit(Pid, kill), S#{poller := none};
cancel_poller(S) -> S.

%% SIGTERM the group and start watching for it to be gone. `From` is told
%% {Had, Exited} when it is, or when the wait is given up.
begin_stop(From, S = #{child := {_, OsPid}}) ->
    Ref = make_ref(),
    signal_group(OsPid, "TERM"),
    erlang:send_after(?WAIT_POLL_MS, self(), {stop_poll, Ref}),
    erlang:send_after(?STOP_GRACE_MS, self(), {stop_kill, Ref}),
    erlang:send_after(?STOP_GRACE_MS + ?STOP_GIVEUP_MS, self(), {stop_giveup, Ref}),
    Waiters = case From of none -> []; _ -> [{From, true}] end,
    (cancel_poller(S))#{child := none, phase := stopping,
                        stop := #{ref => Ref, pid => OsPid, waiters => Waiters}}.

%% The three messages of a stop in flight. `{done, Exited, S}` when it ended.
stop_message({stop_poll, Ref}, S = #{stop := #{ref := Ref, pid := OsPid}}) ->
    case group_alive(OsPid) of
        false -> {done, true, S};
        true -> erlang:send_after(?WAIT_POLL_MS, self(), {stop_poll, Ref}), {wait, S}
    end;
stop_message({stop_kill, Ref}, S = #{stop := #{ref := Ref, pid := OsPid}}) ->
    say("  ~ts ignored SIGTERM; SIGKILL", [label(S)]),
    signal_group(OsPid, "KILL"),
    {wait, S};
stop_message({stop_giveup, Ref}, S = #{stop := #{ref := Ref}}) ->
    {done, false, S};
stop_message(_, S) ->
    {wait, S}.

%% The launching shell has exited. If nothing is left in its process group
%% the service is gone. If something is (the command put itself in the
%% background), the service is still there and still ours: the keeper goes on
%% holding the group, and `watch` notices when the group empties, because no
%% exit will be reported for it.
shell_exited(S = #{child := {_, OsPid}}) ->
    case group_alive(OsPid) of
        true -> {detached, S#{child := {detached, OsPid}}};
        false -> {gone, S}
    end.

detached_gone(#{child := {detached, OsPid}}) -> not group_alive(OsPid);
detached_gone(_) -> false.

end_stop(Exited, S = #{stop := #{waiters := Waiters}}) ->
    _ = [reply(From, {Had, Exited}) || {From, Had} <- Waiters],
    S#{stop := none, phase := down}.

label(#{route := #{serviceId := Id}}) -> Id;
label(#{broker := #{serviceId := Id}}) -> Id.

%% =============================================================================
%% The route keeper
%% =============================================================================

route_init(Planned) ->
    Route = case env_integer("BOSUN_SERVE_IDLE_MS") of
                N when is_integer(N), N > 0 -> Planned#{idleTimeoutMs := N};
                _ -> Planned
            end,
    S = maps:merge(child_state(),
                   #{route => Route, listen => none, bound => false, bind_error => null,
                     external => false, external_at => null,
                     adopted => false, adopted_at => null,
                     connections => 0, idle => none, unbinding => none}),
    erlang:send_after(?WATCH_MS, self(), watch),
    route(route_bind(S)).

route(stop) -> ok;
route(S) ->
    receive Message -> route(route_message(Message, S)) end.

route_message({call, From, ensure}, S) -> route_ensure(From, S);
route_message({call, From, stop}, S) -> route_stop(From, S);
route_message({call, From, snapshot}, S) ->
    #{route := #{serviceId := Id, publicPort := Public, internalPort := Internal},
      child := Child, external := External, adopted := Adopted} = S,
    reply(From, #{serviceId => Id, publicPort => Public, internalPort => Internal,
                  up => External orelse Child =/= none orelse Adopted,
                  pid => case Child of {_, OsPid} -> OsPid; none -> null end,
                  external => External, externalCheckedAt => maps:get(external_at, S),
                  adoptedBackend => Adopted andalso Child =:= none,
                  adoptedBackendAt => maps:get(adopted_at, S),
                  bound => maps:get(bound, S), bindError => maps:get(bind_error, S)}),
    S;
route_message({call, From, recheck}, S) ->
    S1 = route_recheck(S),
    reply(From, ok),
    S1;
route_message({call, From, teardown}, S = #{child := Child, stop := Stop}) ->
    case {Child, Stop} of
        {{_, OsPid}, _} ->
            say("  ~ts: router exiting, SIGTERM", [label(S)]),
            signal_group(OsPid, "TERM");
        {none, #{pid := OsPid}} -> signal_group(OsPid, "KILL");
        _ -> ok
    end,
    reply(From, ok),
    S;
route_message({call, From, unbind}, S = #{listen := Listen, child := Child, phase := Phase}) ->
    _ = case Listen of none -> ok; _ -> gen_tcp:close(Listen) end,
    S1 = fail_waiters(<<"the route was taken down by a reload">>,
                      cancel_idle(S#{listen := none, bound := false, unbinding := From})),
    case {Phase, Child} of
        {stopping, _} -> S1;
        {_, {_, _}} -> begin_stop(none, S1);
        _ -> reply(From, ok), stop
    end;
route_message({connection, Pid}, S = #{connections := Count}) ->
    erlang:monitor(process, Pid),
    cancel_idle(S#{connections := Count + 1});
route_message({'DOWN', _, process, _, _}, S = #{connections := Count}) ->
    arm_idle(S#{connections := max(0, Count - 1)});
route_message(watch, S) ->
    erlang:send_after(?WATCH_MS, self(), watch),
    route_recheck(S);
route_message({polled, Ref, Result}, S = #{poller := {_, Ref}, phase := starting,
                                         route := #{serviceId := Id, internalPort := Internal}}) ->
    case Result of
        ok ->
            say("  ~ts listening on :~b", [Id, Internal]),
            _ = [reply(From, {ok, true}) || From <- maps:get(waiters, S)],
            arm_idle(S#{phase := up, poller := none, waiters := []});
        timeout ->
            %% it was given thirty seconds and is not listening. It is not
            %% left running: the next request starts a fresh one.
            Why = iolist_to_binary(io_lib:format("timeout waiting for :~b", [Internal])),
            begin_stop(none, fail_waiters(Why, S#{poller := none}))
    end;
route_message({Port, {exit_status, Code}}, S = #{child := {Port, _}, phase := Phase,
                                                 route := #{serviceId := Id, internalPort := Internal}}) ->
    case shell_exited(S) of
        {detached, S1} ->
            say("  ~ts: its shell exited (code ~b) and left it running", [Id, Code]),
            S1;
        {gone, _} ->
            say("  ~ts exited (code ~b)", [Id, Code]),
            Why = iolist_to_binary(io_lib:format(
                    "it exited (code ~b) before it listened on :~b; see /tmp/bosun-serve-~ts.log",
                    [Code, Internal, sanitize(Id)])),
            route_gone(Phase, Why, S)
    end;
route_message({idle, Ref}, S = #{idle := {_, Ref}, connections := 0, child := {_, _}, phase := up,
                                 route := #{serviceId := Id, idleTimeoutMs := Ms}}) ->
    say("  ~ts idle ~bs; SIGTERM", [Id, Ms div 1000]),
    begin_stop(none, S#{idle := none});
route_message(Message, S) when element(1, Message) =:= stop_poll;
                               element(1, Message) =:= stop_kill;
                               element(1, Message) =:= stop_giveup ->
    case stop_message(Message, S) of
        {wait, S1} -> S1;
        {done, Exited, S1} -> route_stopped(end_stop(Exited, S1))
    end;
route_message(_, S) -> S.

%% The backend went of its own accord.
route_gone(Phase, Why, S) ->
    S1 = cancel_idle(cancel_poller(S#{child := none, phase := down})),
    case Phase of
        starting -> fail_waiters(Why, S1);
        _ -> S1
    end.

%% The backend is gone. A route being taken down ends here; otherwise anyone
%% who asked for the backend while it was stopping is served now.
route_stopped(#{unbinding := From}) when From =/= none ->
    reply(From, ok),
    stop;
route_stopped(S = #{pending := Pending}) ->
    lists:foldl(fun route_ensure/2, S#{pending := []}, lists:reverse(Pending)).

fail_waiters(Why, S = #{waiters := Waiters, pending := Pending}) ->
    _ = [reply(From, {error, Why}) || From <- Waiters ++ Pending],
    S#{waiters := [], pending := []}.

%% Make sure a backend is listening. {ok, Started} or {error, Why}; the
%% answer waits for the backend, and every caller that arrives meanwhile
%% waits on the same one.
route_ensure(From, S = #{phase := up}) ->
    reply(From, {ok, false}),
    S;
route_ensure(From, S = #{phase := starting, waiters := Waiters}) ->
    S#{waiters := [From | Waiters]};
route_ensure(From, S = #{phase := stopping, pending := Pending}) ->
    S#{pending := [From | Pending]};
route_ensure(From, S = #{phase := down,
                         route := #{serviceId := Id, internalPort := Internal,
                                    launchCommand := Command, cwd := Cwd}}) ->
    case probe_port(Internal) of
        true ->
            %% something already listens there: relay to it, start nothing
            say("  :~b already listening; relaying ~ts to it (not started by this router)", [Internal, Id]),
            reply(From, {ok, false}),
            S#{phase := up, adopted := true, adopted_at := now_iso()};
        false ->
            case launch(Id, Command, Cwd) of
                {ok, Child} ->
                    start_poller(fun() -> probe_port(Internal, 300) end,
                                 S#{child := Child, phase := starting, adopted := false, waiters := [From]});
                {error, Why} ->
                    reply(From, {error, Why}),
                    S
            end
    end.

%% Stop the backend. {Had, Exited}, answered when it is gone.
route_stop(From, S = #{phase := stopping, stop := Stop = #{waiters := Waiters}}) ->
    S#{stop := Stop#{waiters := Waiters ++ [{From, false}]}};
route_stop(From, S = #{child := none}) ->
    %% nothing of ours is running. A backend we only relay to is not ours to
    %% signal; the claim is dropped so the next request looks again.
    reply(From, {false, true}),
    S#{adopted := false, phase := down};
route_stop(From, S) ->
    begin_stop(From, fail_waiters(<<"stopped">>, cancel_idle(S))).

%% The idle clock runs only while a backend of ours is up and no connection
%% is open through it.
arm_idle(S = #{connections := 0, phase := up, child := {_, _}, route := #{idleTimeoutMs := Ms}}) ->
    S1 = cancel_idle(S),
    Ref = make_ref(),
    S1#{idle := {erlang:send_after(Ms, self(), {idle, Ref}), Ref}};
arm_idle(S) -> S.

cancel_idle(S = #{idle := {Timer, _}}) -> _ = erlang:cancel_timer(Timer), S#{idle := none};
cancel_idle(S) -> S.

%% Take the public port, unless something already answers on it. The probe
%% comes first because a bind to 127.0.0.1 succeeds beside a holder bound to
%% every interface, and would shadow it.
route_bind(S = #{route := Route = #{publicPort := Port, serviceId := Id, idleTimeoutMs := Ms}}) ->
    Keeper = self(),
    case bind_unless_held(Port) of
        {ok, Listen} ->
            spawn(fun() -> accept(Listen, fun(Socket) -> proxy_connection(Socket, Keeper, Route) end) end),
            say("  bound :~b -> ~ts (idle ~bs)", [Port, Id, Ms div 1000]),
            S#{listen := Listen, bound := true, bind_error := null, external := false};
        held ->
            _ = case maps:get(external, S) of
                    true -> ok;
                    false -> say("  :~b already served by another process; ~ts adopted", [Port, Id])
                end,
            S#{listen := none, bound := false, bind_error := null, external := true, external_at := now_iso()};
        {error, Reason} ->
            say("  x cannot bind :~b (~ts); ~ts unserved", [Port, upper(Reason), Id]),
            S#{listen := none, bound := false, bind_error := upper(Reason)}
    end.

%% Put the claims about the world to the test: a port we stepped aside from,
%% and a backend we relay to without having started.
route_recheck(S = #{route := #{publicPort := Public, internalPort := Internal, serviceId := Id}}) ->
    S0 = case detached_gone(S) of
             true ->
                 say("  ~ts is gone", [Id]),
                 route_gone(maps:get(phase, S), <<"it exited before it listened">>, S);
             false -> S
         end,
    S1 = case maps:get(external, S0) of
             true ->
                 case probe_port(Public) of
                     true -> S0#{external_at := now_iso()};
                     false ->
                         say("  :~b holder is gone; taking the port for ~ts", [Public, Id]),
                         route_bind(S0#{external := false, external_at := now_iso()})
                 end;
             false -> S0
         end,
    case S1 of
        #{adopted := true, child := none, phase := up} ->
            case probe_port(Internal) of
                true -> S1;
                false ->
                    say("  :~b backend is gone; ~ts starts on the next request", [Internal, Id]),
                    S1#{adopted := false, phase := down}
            end;
        _ -> S1
    end.

%% =============================================================================
%% The broker keeper
%% =============================================================================
%%
%% The router makes sure a brokered service is running and says where it is;
%% it carries none of its traffic. If the service has a registered port the
%% keeper holds it and answers 307 there.

broker_init(B) ->
    S = maps:merge(child_state(),
                   #{broker => B, door => none, bound => false, bind_error => null,
                     aside => false, aside_at => null}),
    erlang:send_after(?WATCH_MS, self(), watch),
    broker(S).

broker(stop) -> ok;
broker(S) ->
    receive Message -> broker(broker_message(Message, S)) end.

broker_message({call, From, ensure}, S) -> broker_ensure(From, S);
broker_message({call, From, stop}, S) ->
    case S of
        #{phase := stopping, stop := Stop = #{waiters := Waiters}} ->
            S#{stop := Stop#{waiters := Waiters ++ [{From, false}]}};
        #{child := none} -> reply(From, {false, true}), S;
        _ -> begin_stop(From, broker_answer(#{ready => false, started => false,
                                              detail => <<"stopped while it was starting">>}, S))
    end;
broker_message({call, From, snapshot}, S = #{broker := B, child := Child}) ->
    reply(From, #{serviceId => maps:get(serviceId, B), publicPort => maps:get(publicPort, B),
                  transport => maps:get(transport, B), at => locator_label(B), url => maps:get(url, B),
                  probe => maps:get(probe, B),
                  pid => case Child of {_, OsPid} -> OsPid; none -> null end,
                  bound => maps:get(bound, S), bindError => maps:get(bind_error, S),
                  door => door_word(S), doorCheckedAt => maps:get(aside_at, S)}),
    S;
broker_message({call, From, recheck}, S) ->
    S1 = broker_recheck(S),
    reply(From, ok),
    S1;
broker_message({call, From, {update, B}}, S) ->
    reply(From, ok),
    S#{broker := B};
broker_message({call, From, open_door}, S) ->
    S1 = door_bind(door_close(S)),
    reply(From, ok),
    S1;
broker_message({call, From, close_door}, S) ->
    S1 = door_close(S),
    reply(From, ok),
    S1;
broker_message({call, From, forget}, S) ->
    %% the door goes; the process stays, on its own address
    _ = door_close(S),
    reply(From, ok),
    stop;
broker_message(watch, S) ->
    erlang:send_after(?WATCH_MS, self(), watch),
    broker_recheck(S);
broker_message({polled, Ref, Result}, S = #{poller := {_, Ref}, phase := starting, broker := B}) ->
    Sentence = probe_sentence(B),
    Detail = case Result of
                 ok -> say("  ~ts ready at ~ts", [maps:get(serviceId, B), locator_label(B)]),
                       [<<"started by bosun; ">>, Sentence, <<" passed">>];
                 timeout -> io_lib:format("started by bosun, but ~ts has not passed within ~bms",
                                          [Sentence, ?WAIT_TIMEOUT_MS])
             end,
    %% a slow daemon is left running: the next ask probes it again
    (broker_answer(#{ready => Result =:= ok, started => true, detail => iolist_to_binary(Detail)},
                   S#{poller := none}))#{phase := up};
broker_message({Port, {exit_status, Code}}, S = #{child := {Port, _}, phase := Phase, broker := B}) ->
    case shell_exited(S) of
        {detached, S1} ->
            say("  ~ts: its shell exited (code ~b) and left it running", [maps:get(serviceId, B), Code]),
            S1;
        {gone, _} ->
            say("  ~ts exited (code ~b)", [maps:get(serviceId, B), Code]),
            broker_gone(Phase, io_lib:format("it exited (code ~b)", [Code]), S)
    end;
broker_message(Message, S) when element(1, Message) =:= stop_poll;
                                element(1, Message) =:= stop_kill;
                                element(1, Message) =:= stop_giveup ->
    case stop_message(Message, S) of
        {wait, S1} -> S1;
        {done, Exited, S1} ->
            S2 = end_stop(Exited, S1),
            lists:foldl(fun broker_ensure/2, S2#{pending := []}, lists:reverse(maps:get(pending, S2)))
    end;
broker_message(_, S) -> S.

broker_gone(Phase, How, S = #{broker := B}) ->
    S1 = cancel_poller(S#{child := none, phase := down}),
    case Phase of
        starting ->
            Detail = io_lib:format("started by bosun, but ~ts before ~ts passed", [How, probe_sentence(B)]),
            broker_answer(#{ready => false, started => true, detail => iolist_to_binary(Detail)}, S1);
        _ -> S1
    end.

broker_answer(Answer, S = #{waiters := Waiters, broker := B}) ->
    _ = [reply(From, {ok, Answer#{probe => maps:get(probe, B)}}) || From <- Waiters],
    S#{waiters := []}.

%% ENSURE-AND-LOCATE. Is it already up? If not, start it, once. Did it become
%% ready? The answer is #{ready, started, probe, detail} and is sent after the
%% wait, so a caller that follows it finds a service that is up. A probe of
%% `none` means nothing was checked, never that a check failed.
broker_ensure(From, S = #{broker := B, phase := Phase, child := Child}) ->
    Probe = maps:get(probe, B),
    Sentence = probe_sentence(B),
    Answer = fun(Ready, Started, Detail) ->
                 reply(From, {ok, #{ready => Ready, started => Started, probe => Probe,
                                    detail => iolist_to_binary(Detail)}})
             end,
    case probe_broker(B) of
        true ->
            Answer(true, false, [<<"already running; ">>, Sentence, <<" passed">>]),
            S;
        false ->
            case {Phase, Child} of
                {stopping, _} -> S#{pending := [From | maps:get(pending, S)]};
                {starting, _} -> S#{waiters := [From | maps:get(waiters, S)]};
                {_, {_, OsPid}} when Probe =:= <<"none">> ->
                    Answer(false, false,
                           io_lib:format("started by bosun (pid ~b); this service publishes no readiness "
                                         "signal serve can check, so \"up\" is not a claim it can make", [OsPid])),
                    S;
                {_, {_, OsPid}} ->
                    Answer(false, false,
                           io_lib:format("bosun started it (pid ~b) and it is running, but ~ts does not pass",
                                         [OsPid, Sentence])),
                    S;
                {_, none} ->
                    case launch(maps:get(serviceId, B), maps:get(launchCommand, B), maps:get(cwd, B)) of
                        {ok, Started} when Probe =:= <<"none">> ->
                            Answer(false, true, <<"started by bosun; no readiness signal to check, "
                                                  "so nothing here says it is up">>),
                            S#{child := Started, phase := up};
                        {ok, Started} ->
                            start_poller(fun() -> probe_broker(B) end,
                                         S#{child := Started, phase := starting, waiters := [From]});
                        {error, Why} ->
                            reply(From, {error, Why}),
                            S
                    end
            end
    end.

door_word(S = #{broker := B}) ->
    (maps:get(door, B))(#{bound => maps:get(bound, S),
                          bindFailed => maps:get(bind_error, S) =/= null,
                          holderAnswers => maps:get(aside, S)}).

door_bind(S = #{broker := B}) ->
    case maps:get(publicPort, B) of
        null -> S;
        Port ->
            Keeper = self(),
            Id = maps:get(serviceId, B),
            case bind_unless_held(Port) of
                {ok, Listen} ->
                    spawn(fun() -> accept(Listen, fun(Socket) -> door_connection(Socket, Keeper, B) end) end),
                    say("  bound :~b -> 307 -> ~ts (~ts, brokered: no relay)", [Port, locator_label(B), Id]),
                    S#{door := Listen, bound := true, bind_error := null, aside := false};
                held ->
                    _ = case maps:get(aside, S) of
                            true -> ok;
                            false -> say("  :~b already held; ~ts is brokered, so serve steps aside", [Port, Id])
                        end,
                    S#{door := none, bound := false, bind_error := null, aside := true, aside_at := now_iso()};
                {error, Reason} ->
                    say("  x cannot bind :~b (~ts); ~ts 307 unavailable", [Port, upper(Reason), Id]),
                    S#{door := none, bound := false, bind_error := upper(Reason)}
            end
    end.

%% Letting go of the door says nothing about the service behind it.
door_close(S = #{door := Door}) ->
    _ = case Door of none -> ok; _ -> gen_tcp:close(Door) end,
    S#{door := none, bound := false, aside := false}.

%% Only the door is on a clock. Whether the service is ours to stop is asked
%% of the world at the moment it matters, so nothing about it can go stale.
broker_recheck(S) ->
    door_recheck(case detached_gone(S) of
                     true -> broker_gone(maps:get(phase, S), <<"it exited">>, S);
                     false -> S
                 end).

door_recheck(S = #{aside := true, broker := B}) ->
    Port = maps:get(publicPort, B),
    case probe_port(Port) of
        true -> S#{aside_at := now_iso()};
        false ->
            say("  :~b holder is gone; taking the 307 door for ~ts", [Port, maps:get(serviceId, B)]),
            door_bind(S#{aside := false, aside_at := now_iso()})
    end;
door_recheck(S) -> S.

probe_broker(#{probe := <<"tcp">>, probePort := Port}) when is_integer(Port) -> probe_port(Port);
probe_broker(#{probe := <<"socket">>, probePath := Path}) when is_binary(Path) ->
    case file:read_file_info(Path) of {ok, _} -> true; _ -> false end;
probe_broker(_) -> false.

probe_sentence(#{probe := <<"tcp">>, probePort := Port}) ->
    iolist_to_binary(io_lib:format("a TCP connect to :~b", [Port]));
probe_sentence(#{probe := <<"socket">>, probePath := Path}) -> <<"the socket ", Path/binary>>;
probe_sentence(_) -> <<"no check">>.

locator_label(#{transport := <<"unix">>, path := Path}) -> <<"unix ", Path/binary>>;
locator_label(#{transport := <<"none">>}) -> <<"(no dialable address)">>;
locator_label(#{url := Url}) when is_binary(Url) -> Url;
locator_label(#{transport := Transport, host := Host, port := Port}) ->
    iolist_to_binary(io_lib:format("~ts ~ts:~b", [Transport, Host, Port])).

%% =============================================================================
%% Sockets
%% =============================================================================

%% `exit_on_close` is off because the BEAM otherwise closes a socket for
%% writing too, the moment it reads that the peer has finished sending. A
%% client that sends its request, closes its sending side and waits (nc does;
%% so does any HTTP/1.0 client) would then never get its answer.
listen(Port) ->
    gen_tcp:listen(Port, [binary, {packet, raw}, {active, false}, {reuseaddr, true},
                          {ip, ?HOST}, {backlog, 128}, {nodelay, true}, {exit_on_close, false}]).

%% {ok, Listen} | held | {error, Reason}
bind_unless_held(Port) ->
    case probe_port(Port) of
        true -> held;
        false ->
            case listen(Port) of
                {ok, Listen} -> {ok, Listen};
                {error, eaddrinuse} -> held;
                {error, Reason} -> {error, Reason}
            end
    end.

%% Accept for as long as the listener is open; one process per connection.
accept(Listen, Handle) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> receive go -> Handle(Socket) end end),
            _ = gen_tcp:controlling_process(Socket, Handler),
            Handler ! go,
            accept(Listen, Handle);
        {error, closed} -> ok;
        {error, einval} -> ok;
        %% out of files, most likely: the connection waits in the backlog
        {error, _} -> timer:sleep(50), accept(Listen, Handle)
    end.

%% Is anything listening on this port? The evidence behind every "up" the
%% router reports about a process it did not start.
probe_port(Port) -> probe_port(Port, ?PROBE_TIMEOUT_MS).
probe_port(Port, Timeout) ->
    case gen_tcp:connect(?HOST, Port, [], Timeout) of
        {ok, Socket} -> gen_tcp:close(Socket), true;
        _ -> false
    end.

%% --- reading a request head --------------------------------------------------
%%
%% {ok, Request} | bad | closed. Read raw, so the head can be replayed byte
%% for byte: names keep their case and their order.

read_head(Socket) -> read_head(Socket, <<>>).
read_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {At, 4} ->
            parse_head(binary:part(Acc, 0, At), binary:part(Acc, At + 4, byte_size(Acc) - At - 4));
        nomatch when byte_size(Acc) > ?HEAD_LIMIT -> bad;
        nomatch ->
            case first_line_wrong(Acc) of
                true -> bad;
                false ->
                    case gen_tcp:recv(Socket, 0, ?HEAD_TIMEOUT_MS) of
                        {ok, More} -> read_head(Socket, <<Acc/binary, More/binary>>);
                        {error, _} when Acc =:= <<>> -> closed;
                        {error, _} -> bad
                    end
            end
    end.

first_line_wrong(Acc) ->
    case binary:split(Acc, <<"\r\n">>) of
        [Line, _] -> request_line(Line) =:= nomatch;
        _ -> false
    end.

request_line(Line) ->
    re:run(Line, "^([!#$%&'*+.^_`|~0-9A-Za-z-]+) (\\S+) HTTP/1\\.[01]$", [{capture, all_but_first, binary}]).

parse_head(Head, Rest) ->
    [Line | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    case request_line(Line) of
        {match, [Method, Target]} ->
            {ok, #{method => Method, target => Target, line => Line, rest => Rest,
                   headers => [header(L) || L <- Lines]}};
        nomatch -> bad
    end.

header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] -> {string:lowercase(string:trim(Name)), string:trim(Value), Line};
        _ -> {<<>>, <<>>, Line}
    end.

header_value(Name, #{headers := Headers}) ->
    case lists:keyfind(Name, 1, Headers) of {_, Value, _} -> Value; false -> none end.

is_upgrade(Request) -> header_value(<<"upgrade">>, Request) =/= none.

%% --- answering ---------------------------------------------------------------

respond(Socket, Status, Headers, Body) ->
    Bytes = iolist_to_binary(Body),
    _ = gen_tcp:send(Socket,
                     ["HTTP/1.1 ", integer_to_binary(Status), " ", reason(Status), "\r\n",
                      [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
                      "content-length: ", integer_to_binary(byte_size(Bytes)), "\r\n",
                      "connection: close\r\n\r\n", Bytes]),
    ok.

text(Socket, Status, Headers, Body) ->
    respond(Socket, Status, [{"content-type", "text/plain"} | Headers], Body).

%% Close without cutting the answer off. A socket closed with unread bytes
%% waiting (a request body nobody read) is reset, and the reset can reach the
%% client before the answer does. So: finish writing, read whatever is still
%% coming for a moment, then close.
finish(Socket) ->
    _ = gen_tcp:shutdown(Socket, write),
    drain(Socket, erlang:monotonic_time(millisecond) + 2000),
    gen_tcp:close(Socket).

drain(Socket, Deadline) ->
    case max(0, Deadline - erlang:monotonic_time(millisecond)) of
        0 -> ok;
        Left ->
            case gen_tcp:recv(Socket, 0, Left) of
                {ok, _} -> drain(Socket, Deadline);
                {error, _} -> ok
            end
    end.

reason(101) -> "Switching Protocols";
reason(200) -> "OK";
reason(204) -> "No Content";
reason(307) -> "Temporary Redirect";
reason(400) -> "Bad Request";
reason(404) -> "Not Found";
reason(409) -> "Conflict";
reason(421) -> "Misdirected Request";
reason(502) -> "Bad Gateway";
reason(503) -> "Service Unavailable";
reason(504) -> "Gateway Timeout";
reason(_) -> "Internal Server Error".

%% =============================================================================
%% Connections
%% =============================================================================

%% --- a relayed route ---------------------------------------------------------

proxy_connection(Client, Keeper, Route = #{serviceId := Id}) ->
    case read_head(Client) of
        {ok, Request} ->
            %% counted from here to the end of this process: the backend is
            %% not idle while this connection is open
            Keeper ! {connection, self()},
            case call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000) of
                {ok, _} -> relay(Client, Request, Route);
                {error, Why} ->
                    text(Client, 502, [], ["bosun serve: backend for ", Id, " did not come up\n", Why, "\n"]);
                _ ->
                    text(Client, 502, [], ["bosun serve: backend for ", Id, " did not come up\n"])
            end,
            finish(Client);
        bad ->
            respond(Client, 400, [], <<>>),
            finish(Client);
        closed ->
            gen_tcp:close(Client)
    end.

%% Connect to the backend. Out of files (launchd gives a service 256, and a
%% relayed connection takes two) is a reason to wait for one, not to fail:
%% other connections are about to end.
connect_backend(Internal, Deadline) ->
    case gen_tcp:connect(?HOST, Internal, [binary, {packet, raw}, {active, false}, {nodelay, true}], 3000) of
        {error, Reason} when Reason =:= emfile; Reason =:= enfile ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, Reason};
                false -> timer:sleep(?WAIT_POLL_MS), connect_backend(Internal, Deadline)
            end;
        Other -> Other
    end.

relay(Client, Request, #{serviceId := Id, internalPort := Internal}) ->
    case connect_backend(Internal, erlang:monotonic_time(millisecond) + ?WAIT_TIMEOUT_MS) of
        {ok, Backend} ->
            Upgrade = is_upgrade(Request),
            case gen_tcp:send(Backend, [replayed(Request, Upgrade), maps:get(rest, Request)]) of
                ok ->
                    Connection = self(),
                    Sent = counters:new(1, []),
                    Pump = spawn(fun() -> pump(Client, Backend, Connection, Sent) end),
                    _ = inet:setopts(Backend, [{active, once}]),
                    Flow = #{client => Client, backend => Backend, id => Id, upgrade => Upgrade,
                             answered => false, client_done => false, sent => Sent, seen => 0},
                    carry(Flow),
                    exit(Pump, kill);
                {error, Reason} ->
                    text(Client, 502, [], io_lib:format("bosun serve: proxy error for ~ts: ~ts\n", [Id, Reason]))
            end,
            gen_tcp:close(Backend);
        {error, Reason} ->
            text(Client, 502, [], io_lib:format("bosun serve: proxy error for ~ts: ~ts\n", [Id, Reason]))
    end.

%% The head as the backend gets it. An Upgrade goes as it came. Anything else
%% goes with `Connection: close`, so the backend ends the connection when it
%% has answered and the end of the answer needs no parsing here.
replayed(#{line := Line, headers := Headers}, true) ->
    [Line, "\r\n", [[Raw, "\r\n"] || {_, _, Raw} <- Headers], "\r\n"];
replayed(#{line := Line, headers := Headers}, false) ->
    Hop = [<<"connection">>, <<"keep-alive">>, <<"proxy-connection">>],
    [Line, "\r\n",
     [[Raw, "\r\n"] || {Name, _, Raw} <- Headers, not lists:member(Name, Hop)],
     "Connection: close\r\n\r\n"].

%% Client to backend. Counts what it carries, so a slow upload is not taken
%% for a backend that is not answering.
pump(Client, Backend, Connection, Sent) ->
    case gen_tcp:recv(Client, 0) of
        {ok, Bytes} ->
            counters:add(Sent, 1, 1),
            case gen_tcp:send(Backend, Bytes) of
                ok -> pump(Client, Backend, Connection, Sent);
                {error, _} -> Connection ! client_done
            end;
        {error, _} -> Connection ! client_done
    end.

%% Backend to client, and the decisions about when the tunnel ends.
%%
%%   an upgraded connection   ends when either side closes
%%   a plain exchange         ends when the backend closes. A client that
%%                            finishes sending first is normal (it is waiting
%%                            for the answer), so the answer still flows. The
%%                            backend is NOT told the client finished: a node
%%                            HTTP server drops the exchange when it sees
%%                            that. From then on the backend may be silent
%%                            for eight seconds at most, so that a client
%%                            that has gone away cannot hold a backend open
%%                            for ever.
%%   before any answer        eight seconds with no byte either way is a 504
carry(Flow = #{client := Client, backend := Backend, id := Id, upgrade := Upgrade,
               answered := Answered, client_done := ClientDone, sent := Sent, seen := Seen}) ->
    Limit = if Upgrade -> infinity;
               not Answered -> ?PROXY_TIMEOUT_MS;
               ClientDone -> ?PROXY_TIMEOUT_MS;
               true -> infinity
            end,
    receive
        {tcp, Backend, Bytes} ->
            case gen_tcp:send(Client, Bytes) of
                ok ->
                    _ = inet:setopts(Backend, [{active, once}]),
                    carry(Flow#{answered := true});
                {error, _} -> ok
            end;
        {tcp_closed, Backend} when Answered; Upgrade -> ok;
        {tcp_closed, Backend} ->
            text(Client, 502, [], io_lib:format(
                "bosun serve: proxy error for ~ts: the backend closed the connection without answering\n", [Id]));
        {tcp_error, Backend, _} when Answered; Upgrade -> ok;
        {tcp_error, Backend, Reason} ->
            text(Client, 502, [], io_lib:format("bosun serve: proxy error for ~ts: ~ts\n", [Id, Reason]));
        client_done when Upgrade -> ok;
        client_done ->
            carry(Flow#{client_done := true})
    after Limit ->
        Now = counters:get(Sent, 1),
        if
            Answered -> ok;
            Now =/= Seen -> carry(Flow#{seen := Now});
            true ->
                text(Client, 504, [], io_lib:format("bosun serve: ~ts timed out after ~bms\n",
                                                    [Id, ?PROXY_TIMEOUT_MS]))
        end
    end.

%% --- a redirect to another host ----------------------------------------------

redirect_connection(Socket, #{serviceId := Id, host := Host, target := Target}) ->
    case read_head(Socket) of
        {ok, #{target := Path}} ->
            text(Socket, 421, [{"location", [Target, Path]}],
                 ["bosun serve: ", Id, " runs on ", Host, ". Use ", Target, Path, "\n"]),
            finish(Socket);
        bad -> respond(Socket, 400, [], <<>>), finish(Socket);
        closed -> gen_tcp:close(Socket)
    end.

%% --- the 307 door of a brokered service --------------------------------------
%%
%% Ensure the service, then send the caller to it. 307 so the method and the
%% body survive. An Upgrade cannot follow a redirect, so it fails, but it
%% fails with the address it should have used.

door_connection(Socket, Keeper, B = #{serviceId := Id}) ->
    case read_head(Socket) of
        {ok, Request = #{target := Path}} ->
            case {call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000), is_upgrade(Request)} of
                {{ok, _}, true} ->
                    Target = case maps:get(url, B) of null -> locator_label(B); Url -> Url end,
                    text(Socket, 307, [{"location", Target}, {"x-bosun-mediation", "broker"}],
                         ["bosun serve: ", Id, " is brokered. Connect directly to ", Target, ".\n",
                          "Ask GET /where/", Id, " on the control port first; it starts the service if needed.\n"]);
                {{ok, #{ready := Ready, detail := Detail}}, false} ->
                    case B of
                        #{transport := <<"tcp">>, host := Host, port := Port} when is_integer(Port) ->
                            Target = [<<"http://">>, Host, ":", integer_to_binary(Port), Path],
                            text(Socket, 307,
                                 [{"location", Target}, {"x-bosun-mediation", "broker"},
                                  {"x-bosun-ready", atom_to_binary(Ready)}],
                                 ["bosun serve: ", Id, " is brokered: go direct to ", Target, "\n", Detail, "\n"]);
                        _ ->
                            text(Socket, 503, [],
                                 ["bosun serve: ", Id, " is brokered at ", locator_label(B),
                                  ", which is not an HTTP address.\nAsk GET /where/", Id,
                                  " on the control port for the real address.\n"])
                    end;
                {{error, Why}, _} ->
                    text(Socket, 502, [], ["bosun serve: could not ensure ", Id, ": ", Why, "\n"]);
                _ ->
                    text(Socket, 502, [], ["bosun serve: could not ensure ", Id, "\n"])
            end,
            finish(Socket);
        bad -> respond(Socket, 400, [], <<>>), finish(Socket);
        closed -> gen_tcp:close(Socket)
    end.

%% =============================================================================
%% The control surface: /state, /where, /control
%% =============================================================================

control_listen(Port, Config) ->
    Router = self(),
    case listen(Port) of
        {ok, Listen} ->
            spawn(fun() -> accept(Listen, fun(Socket) -> control_connection(Socket, Router, Config) end) end),
            say("  /state + /control on :~b", [Port]);
        {error, Reason} ->
            say("  x /state :~b (~ts)", [Port, upper(Reason)])
    end.

control_connection(Socket, Router, Config) ->
    case read_head(Socket) of
        {ok, Request = #{method := Method, target := Target}} ->
            {Path, Query} = split_target(Target),
            Answer = try control(Method, Path, Query, Router, Config)
                     catch Class:Reason -> {500, failure(describe(Class, Reason))}
                     end,
            _ = Request,
            case Answer of
                {204, none} -> respond(Socket, 204, cors(), <<>>);
                {Status, {text, Body}} ->
                    respond(Socket, Status, [{"content-type", "application/json"} | cors()], [Body, "\n"]);
                {Status, Json} ->
                    respond(Socket, Status, [{"content-type", "application/json"} | cors()],
                            [data_argonaut_core@foreign:stringify(Json), "\n"])
            end,
            finish(Socket);
        bad -> respond(Socket, 400, [], <<>>), finish(Socket);
        closed -> gen_tcp:close(Socket)
    end.

cors() ->
    [{"access-control-allow-origin", "*"},
     {"access-control-allow-methods", "GET,POST,OPTIONS"},
     {"access-control-allow-headers", "*"}].

split_target(Target) ->
    case uri_string:parse(Target) of
        Parsed = #{path := Path} ->
            Query = case Parsed of
                        #{query := Q} ->
                            case uri_string:dissect_query(Q) of
                                Pairs when is_list(Pairs) -> Pairs;
                                _ -> []
                            end;
                        _ -> []
                    end,
            {Path, Query};
        _ -> {Target, []}
    end.

query_text(Name, Query) ->
    case lists:keyfind(Name, 1, Query) of
        {_, Value} when is_binary(Value) -> Value;
        _ -> <<>>
    end.

query_port(Query) ->
    case string:to_integer(query_text(<<"port">>, Query)) of
        {N, <<>>} when is_integer(N) -> N;
        _ -> 0
    end.

failure(Why) -> [{<<"ok">>, false}, {<<"error">>, iolist_to_binary(Why)}].

control(<<"OPTIONS">>, _, _, _, _) -> {204, none};

control(<<"GET">>, Path, _, Router, _) when Path =:= <<"/state">>; Path =:= <<"/">> ->
    case call(Router, state) of
        {ok, Text, _} -> {200, {text, Text}};
        Other -> {500, failure(io_lib:format("the router did not answer: ~0p", [Other]))}
    end;

%% GET /where/<service>  and  GET /where?port=<n>. It answers for relayed
%% routes too: "where is it" has an answer either way, and `mediation` tells
%% the caller whether the router is in the path. 200 ready, 503 a check was
%% made and failed, 404 unknown. A probe of `none` is 200 with ready false:
%% not checked is not down.
control(<<"GET">>, Path, Query, Router, Config) when Path =:= <<"/where">>;
                                                     binary_part(Path, 0, min(7, byte_size(Path))) =:= <<"/where/">> ->
    Id = case Path of
             <<"/where/", Encoded/binary>> -> uri_string:percent_decode(Encoded);
             _ -> <<>>
         end,
    Port = query_port(Query),
    Where = fun(Fields) -> (maps:get(whereJson, Config))(Fields) end,
    case call(Router, {locate, Id, Port}) of
        {broker, Keeper, B} ->
            case call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000) of
                {ok, #{ready := Ready, started := Started, probe := Probe, detail := Detail}} ->
                    Status = case Ready orelse Probe =:= <<"none">> of true -> 200; false -> 503 end,
                    {Status, Where(#{service => maps:get(serviceId, B), mediation => <<"broker">>,
                                     ready => Ready, started => Started, probe => Probe, detail => Detail,
                                     transport => maps:get(transport, B), host => maps:get(host, B),
                                     port => maps:get(port, B), path => maps:get(path, B),
                                     url => maps:get(url, B)})};
                {error, Why} -> {502, failure(Why)};
                Other -> {502, failure(io_lib:format("~0p", [Other]))}
            end;
        {route, Keeper, #{serviceId := Service, publicPort := Public, internalPort := Internal}} ->
            Locate = fun(Ready, Started, Detail) ->
                         {case Ready of true -> 200; false -> 503 end,
                          Where(#{service => Service, mediation => <<"proxy">>, ready => Ready,
                                  started => Started, probe => <<"tcp">>,
                                  detail => iolist_to_binary(Detail), transport => <<"tcp">>,
                                  host => <<"127.0.0.1">>, port => Public, path => null,
                                  url => iolist_to_binary(io_lib:format("http://127.0.0.1:~b", [Public]))})}
                     end,
            case call(Keeper, snapshot) of
                #{external := true} ->
                    Locate(true, false, <<"held by a process bosun serve did not start; "
                                          "it answers on the public port directly">>);
                #{bound := false, bindError := BindError} ->
                    Locate(false, false,
                           io_lib:format("the router does not hold :~b (~ts), so nothing can reach it",
                                         [Public, case BindError of null -> <<"not bound">>; _ -> BindError end]));
                _ ->
                    case call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000) of
                        {ok, Started} ->
                            Locate(true, Started,
                                   [io_lib:format("bosun relays :~b to the backend on :~b", [Public, Internal]),
                                    case Started of true -> <<"; started by this call">>; false -> <<>> end]);
                        {error, Why} -> Locate(false, false, [<<"backend did not come up: ">>, Why]);
                        Other -> Locate(false, false, io_lib:format("backend did not come up: ~0p", [Other]))
                    end
            end;
        _ ->
            {404, failure(case Id of
                              <<>> -> io_lib:format("no service on :~b. /state lists what is.", [Port]);
                              _ -> io_lib:format("no service '~ts' is served here. /state lists what is.", [Id])
                          end)}
    end;

%% The caller needs to know what happened to a particular row, and "not among
%% the newly bound" is not "not routed": an unchanged row was already bound.
%% So the answer carries the state after the reload, not only the changes.
control(<<"POST">>, <<"/control/reload">>, _, Router, _) ->
    case call(Router, reload) of
        {ok, #{unbound := Unbound, boundRoutes := BoundRoutes, boundRedirects := BoundRedirects,
               brokers := Brokers, boundBrokers := BoundBrokers}} ->
            {ok, _, Facts} = call(Router, state),
            #{routes := Routes, redirects := Redirects, rejected := Rejected, drift := Drift,
              registry := Registry} = Facts,
            {200, [{<<"ok">>, true},
                   {<<"unbound">>, array:from_list(Unbound)},
                   {<<"boundRoutes">>, array:from_list(BoundRoutes)},
                   {<<"boundRedirects">>, array:from_list(BoundRedirects)},
                   {<<"brokers">>, array:from_list(Brokers)},
                   {<<"boundBrokers">>, array:from_list(BoundBrokers)},
                   {<<"routes">>, array:map(fun(_, R) -> maps:get(publicPort, R) end, Routes)},
                   {<<"redirects">>, array:map(fun(_, R) -> maps:get(publicPort, R) end, Redirects)},
                   {<<"rejected">>, array:map(fun(_, R) -> object(R, [serviceId, publicPort, reason]) end, Rejected)},
                   {<<"drift">>, array:map(fun(_, D) -> object(D, [serviceId, publicPort, kind, note]) end, Drift)},
                   {<<"registry">>, object(Registry, [source, plannedAt, modifiedAt, error])}]};
        {error, Why} -> {500, failure(Why)};
        Other -> {500, failure(io_lib:format("the router did not answer: ~0p", [Other]))}
    end;

%% Ports are how a service is named on this surface; `?service=` is taken
%% beside them because a brokered service may have no port to be named by.
control(<<"POST">>, Path, Query, Router, _) when Path =:= <<"/control/spawn">>; Path =:= <<"/control/stop">> ->
    Stopping = Path =:= <<"/control/stop">>,
    Verb = case Stopping of true -> <<"stop">>; false -> <<"spawn">> end,
    Id = query_text(<<"service">>, Query),
    Port = query_port(Query),
    case call(Router, {locate, Id, Port}) of
        {broker, Keeper, B} -> control_broker(Keeper, B, Stopping);
        {route, Keeper, Route} -> control_route(Keeper, Route, Stopping, Verb);
        {redirect, Service} ->
            {404, failure(io_lib:format(
                ":~b is a 421 redirect to ~ts on another host, so this router has no process here to ~ts. "
                "Ask the bosun on that host.", [Port, Service, Verb]))};
        _ ->
            Asked = case Id of
                        <<>> -> io_lib:format(":~b", [Port]);
                        _ -> io_lib:format("service '~ts'", [Id])
                    end,
            {404, failure(io_lib:format(
                "no proxy route, no broker and no redirect on this router answers to ~ts. "
                "GET /state lists everything it holds; if you expected one, the registry row may never "
                "have been admitted: see /state's \"rejected\" and \"drift\".", [Asked]))}
    end;

control(_, _, _, _, _) -> {404, failure("not found")}.

control_route(Keeper, #{serviceId := Id, publicPort := Public, internalPort := Internal}, Stopping, Verb) ->
    Snapshot = call(Keeper, snapshot),
    case Snapshot of
        %% An adopted route has no backend of ours to start or stop: the
        %% holder owns the public port itself. Saying `ok` would report a
        %% command that did nothing.
        #{external := true} ->
            {409, [{<<"ok">>, false}, {<<"serviceId">>, Id}, {<<"external">>, true},
                   {<<"error">>, iolist_to_binary(io_lib:format(
                       ":~b is held by a process bosun serve did not start, so it has no backend to ~ts. "
                       "Stop the external holder: the router re-probes and reclaims the port within ~bs.",
                       [Public, Verb, ?WATCH_MS div 1000]))}]};
        #{adoptedBackend := true} when Stopping ->
            {409, [{<<"ok">>, false}, {<<"serviceId">>, Id}, {<<"adoptedBackend">>, true},
                   {<<"error">>, iolist_to_binary(io_lib:format(
                       ":~b is served by a backend bosun serve did not start, so there is nothing here to stop. "
                       "Stop that process: the router re-probes and respawns on the next request.", [Internal]))}]};
        _ when Stopping ->
            %% answered when it is DOWN, not when the signal has been sent
            case call(Keeper, stop, 2 * (?STOP_GRACE_MS + ?STOP_GIVEUP_MS)) of
                {Had, Exited} ->
                    {200, [{<<"ok">>, Exited}, {<<"serviceId">>, Id}, {<<"up">>, not Exited},
                           {<<"wasRunning">>, Had}] ++
                          [{<<"error">>, <<"SIGTERM then SIGKILL sent; the backend has not exited">>} || not Exited]};
                Other -> {500, failure(io_lib:format("~0p", [Other]))}
            end;
        _ ->
            case call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000) of
                {ok, _} ->
                    %% up, but if the router does not hold the public port
                    %% nothing can reach it: the answer says which
                    #{bound := Bound, bindError := BindError} = call(Keeper, snapshot),
                    {200, [{<<"ok">>, true}, {<<"serviceId">>, Id}, {<<"up">>, true},
                           {<<"bound">>, Bound}, {<<"bindError">>, BindError}]};
                {error, Why} ->
                    {502, [{<<"ok">>, false}, {<<"serviceId">>, Id}, {<<"error">>, Why}]};
                Other ->
                    {502, [{<<"ok">>, false}, {<<"serviceId">>, Id},
                           {<<"error">>, iolist_to_binary(io_lib:format("~0p", [Other]))}]}
            end
    end.

%% Spawn is ensure-and-locate under another name: something already running
%% is reported `started: false`, not given a second copy. Stop asks the world
%% whether the service is ours to stop at the moment it is asked;
%% `Bosun.Serve.brokerStopVerdict` weighs the answer.
control_broker(Keeper, B = #{serviceId := Id}, false) ->
    Base = [{<<"serviceId">>, Id}, {<<"mediation">>, <<"broker">>}],
    case call(Keeper, ensure, ?WAIT_TIMEOUT_MS + 10000) of
        {ok, #{ready := Ready, started := Started, probe := Probe, detail := Detail}} ->
            Answered = Ready orelse Probe =:= <<"none">>,
            #{pid := Pid, bound := Bound, bindError := BindError, door := Door} = call(Keeper, snapshot),
            {case Answered of true -> 200; false -> 503 end,
             [{<<"ok">>, Answered} | Base] ++
             [{<<"up">>, Ready orelse Pid =/= null}, {<<"started">>, Started}, {<<"probe">>, Probe},
              {<<"detail">>, Detail}, {<<"at">>, locator_label(B)}, {<<"bound">>, Bound},
              {<<"bindError">>, BindError}, {<<"door">>, Door}]};
        {error, Why} -> {502, [{<<"ok">>, false} | Base] ++ [{<<"error">>, Why}]};
        Other -> {502, [{<<"ok">>, false} | Base] ++ [{<<"error">>, iolist_to_binary(io_lib:format("~0p", [Other]))}]}
    end;
control_broker(Keeper, B = #{serviceId := Id}, true) ->
    Base = [{<<"serviceId">>, Id}, {<<"mediation">>, <<"broker">>}],
    Alive = probe_broker(B),
    #{pid := Pid} = call(Keeper, snapshot),
    case (maps:get(stopVerdict, B))(Pid =/= null, Alive) of
        <<"adopted">> ->
            {409, [{<<"ok">>, false} | Base] ++
                  [{<<"adopted">>, true},
                   {<<"error">>, iolist_to_binary(io_lib:format(
                       "~ts is running at ~ts, but bosun serve did not start it, so there is no child here "
                       "to signal, and killing a daemon it does not own is not this router's to do. "
                       "Stop that process; the next /where finds it gone and starts a fresh one.",
                       [Id, locator_label(B)]))}]};
        <<"unknown">> ->
            {409, [{<<"ok">>, false} | Base] ++
                  [{<<"adopted">>, null},
                   {<<"error">>, iolist_to_binary(io_lib:format(
                       "bosun serve holds no child for ~ts, and this service publishes no readiness signal "
                       "it can check (~ts), so it can neither stop it nor claim it is already stopped. "
                       "Whether something is running there is not a question this router can answer.",
                       [Id, locator_label(B)]))}]};
        _ ->
            case call(Keeper, stop, 2 * (?STOP_GRACE_MS + ?STOP_GIVEUP_MS)) of
                {Had, Exited} ->
                    {200, [{<<"ok">>, Exited} | Base] ++
                          [{<<"up">>, not Exited}, {<<"wasRunning">>, Had}] ++
                          [{<<"note">>, <<"brokered: /where will start it again on the next ask; "
                                          "/state observes without starting">>} || Had] ++
                          [{<<"error">>, <<"SIGTERM then SIGKILL sent; the daemon has not exited">>} || not Exited]};
                Other -> {500, failure(io_lib:format("~0p", [Other]))}
            end
    end.

object(Map, Keys) -> [{atom_to_binary(Key), maps:get(Key, Map)} || Key <- Keys].

%% =============================================================================
%% Backends that outlived a previous router
%% =============================================================================
%%
%% A router that is killed cannot stop its backends. The next one does,
%% before it binds: an internal port is the router's by construction (the
%% public port plus an offset the planner chose), so anything listening on
%% one at startup is a backend of a previous router.

sweep_orphans(Routes) ->
    Listeners = tcp_listeners(),
    Self = list_to_integer(os:getpid()),
    Victims = [{Pid, Internal, Id}
               || #{internalPort := Internal, serviceId := Id} <- Routes,
                  Pid <- maps:get(Internal, Listeners, []), Pid =/= Self],
    case Victims of
        [] -> ok;
        _ ->
            Groups = process_groups([Pid || {Pid, _, _} <- Victims]),
            Sweep = fun(Signal) ->
                        [signal_group(maps:get(Pid, Groups, Pid), Signal) || {Pid, _, _} <- Victims]
                    end,
            _ = [say("  :~b held by pid ~b, a ~ts backend left by a previous router: SIGTERM", [Port, Pid, Id])
                 || {Pid, Port, Id} <- Victims],
            Sweep("TERM"),
            case wait_ports_free(lists:usort([Port || {_, Port, _} <- Victims]), ?STOP_GRACE_MS) of
                [] -> ok;
                Held ->
                    say("  still held after SIGTERM: ~w; SIGKILL", [Held]),
                    Sweep("KILL"),
                    [say("  x :~b is STILL held after SIGKILL; the next start on it will fail", [Port])
                     || Port <- wait_ports_free(Held, ?STOP_GIVEUP_MS)],
                    ok
            end
    end.

%% #{Port => [Pid]} for everything listening on TCP now. One lsof.
tcp_listeners() ->
    {_, Out, _} = bosun_cLI_exec@foreign:run(<<"lsof -nP -iTCP -sTCP:LISTEN -Fpn">>, 15000),
    {_, ByPort} =
        lists:foldl(
          fun(<<"p", Pid/binary>>, {_, Acc}) -> {binary_to_integer(Pid), Acc};
             (<<"n", Name/binary>>, {Pid, Acc}) when is_integer(Pid) ->
                  case re:run(Name, ":(\\d+)$", [{capture, all_but_first, binary}]) of
                      {match, [Port]} ->
                          Key = binary_to_integer(Port),
                          {Pid, Acc#{Key => lists:usort([Pid | maps:get(Key, Acc, [])])}};
                      nomatch -> {Pid, Acc}
                  end;
             (_, State) -> State
          end, {none, #{}}, binary:split(Out, <<"\n">>, [global])),
    ByPort.

%% #{Pid => ProcessGroup}: a listener is often not its group's leader.
process_groups(Pids) ->
    List = lists:join(",", [integer_to_list(Pid) || Pid <- Pids]),
    {_, Out, _} = bosun_cLI_exec@foreign:run(iolist_to_binary(["ps -o pid=,pgid= -p ", List]), 5000),
    maps:from_list(
      [{binary_to_integer(Pid), binary_to_integer(Group)}
       || Line <- binary:split(Out, <<"\n">>, [global]),
          {match, [Pid, Group]} <- [re:run(Line, "^\\s*(\\d+)\\s+(\\d+)\\s*$", [{capture, all_but_first, binary}])]]).

wait_ports_free(Ports, Timeout) ->
    wait_ports_free_until(Ports, erlang:monotonic_time(millisecond) + Timeout).
wait_ports_free_until(Ports, Deadline) ->
    case [Port || Port <- Ports, probe_port(Port, 300)] of
        [] -> [];
        Held ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> Held;
                false -> timer:sleep(?WAIT_POLL_MS), wait_ports_free_until(Held, Deadline)
            end
    end.

%% =============================================================================
%% Small things
%% =============================================================================

say(Format, Args) -> io:format(Format ++ "~n", Args).

describe(error, {badmatch, Value}) -> iolist_to_binary(io_lib:format("unexpected ~0p", [Value]));
describe(_, Reason) when is_binary(Reason) -> Reason;
describe(Class, Reason) -> iolist_to_binary(io_lib:format("~p: ~0p", [Class, Reason])).

now_iso() -> iso(erlang:system_time(millisecond)).
iso(Milliseconds) ->
    list_to_binary(calendar:system_time_to_rfc3339(Milliseconds, [{unit, millisecond}, {offset, "Z"}])).

upper(Reason) when is_atom(Reason) -> string:uppercase(atom_to_binary(Reason));
upper(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).

sanitize(ServiceId) -> binary:replace(ServiceId, [<<":">>, <<"/">>], <<"-">>, [global]).
