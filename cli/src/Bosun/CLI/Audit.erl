%% Not ported. `bosun serve --audit` belongs with `serve`, which is not part
%% of the BEAM spike. Present so the package builds under purerl.
-module(bosun_cLI_audit@foreign).
-export([auditImpl/0]).
auditImpl() -> fun(_Routes) -> erlang:error(bosun_serve_audit_is_not_ported_to_the_beam) end.
