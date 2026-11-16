%% Not ported, on purpose. `serve` is a reverse proxy: a systems program that
%% lives almost wholly in foreign code (Serve.js is 1,500 lines). The BEAM
%% spike covers `supervise` only. Present so the package builds under purerl.
-module(bosun_cLI_serve@foreign).
-export([serveImpl/0, resolveStatusPort/0]).
serveImpl() -> fun(_Config) -> erlang:error(bosun_serve_is_not_ported_to_the_beam) end.
resolveStatusPort() -> fun() -> erlang:error(bosun_serve_is_not_ported_to_the_beam) end.
