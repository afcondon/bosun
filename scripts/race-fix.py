#!/usr/bin/env python3
"""The backend-go thunk thread-safety diff — now UPSTREAM, kept as documentation.

The fix for the Phase-7 thunk thread-safety roadblock: make `_force` thread-safe
(and double-eval-proof) via a per-thunk sync.Once. As of #20 this is committed in
backend-go/runtime.go, so this script no longer patches the source. It documents
the exact diff that was upstreamed, and supports `--revert` to apply the INVERSE
on a build-dir COPY — reverting to the old unsynchronized `done/forcing` thunk so
`scripts/go-race.sh --stock` can re-demonstrate the original data race / spurious
"cyclic strict initialization" panic on demand. The source stays fixed.

    race-fix.py <runtime.go>            # forward: old -> sync.Once (legacy; source is already fixed)
    race-fix.py --revert <runtime.go>   # inverse: sync.Once -> old (re-create the breakage on a copy)

Tradeoff of the upstreamed fix: sync.Once replaces the eager-cycle
`panic("cyclic strict initialization")` — a genuine self-referential strict cycle
deadlocks rather than panics. backend-go does not emit such cycles (cyclic
typeclass-dict clusters break their cycles with deferred lazy `\\_ -> dict` edges,
no synchronous re-force), and the resident-server hung-goroutine case is owned at
the serve layer via request/handler timeouts.
"""
import sys

# (old_unsynchronized, new_sync_once) pairs — forward applies old->new.
PAIRS = [
    # 1. the sync import
    ('import (\n\t"fmt"\n\t"math"\n\t"os"\n\t"strconv"\n\t"strings"\n)',
     'import (\n\t"fmt"\n\t"math"\n\t"os"\n\t"strconv"\n\t"strings"\n\t"sync"\n)'),
    # 2. thunk struct: forcing/done flags -> a sync.Once
    ('type _thunk struct {\n\tdone    bool\n\tforcing bool\n\tval     any\n\tfn      func() any\n}',
     'type _thunk struct {\n\tonce sync.Once\n\tval  any\n\tfn   func() any\n}'),
    # 3. _force: unsynchronized read/write -> once.Do (thread-safe, memoized)
    ('func _force(x any) any {\n\tt, ok := x.(*_thunk)\n\tif !ok {\n\t\treturn x\n\t}\n'
     '\tif t.done {\n\t\treturn t.val\n\t}\n\tif t.forcing {\n\t\tpanic("psgo: cyclic strict initialization")\n\t}\n'
     '\tt.forcing = true\n\tt.val = t.fn()\n\tt.done = true\n\tt.fn = nil\n\treturn t.val\n}',
     'func _force(x any) any {\n\tt, ok := x.(*_thunk)\n\tif !ok {\n\t\treturn x\n\t}\n'
     '\tt.once.Do(func() {\n\t\tt.val = t.fn()\n\t\tt.fn = nil\n\t})\n\treturn t.val\n}'),
]

args = sys.argv[1:]
revert = "--revert" in args
paths = [a for a in args if not a.startswith("--")]
if len(paths) != 1:
    sys.exit("usage: race-fix.py [--revert] <runtime.go>")
path = paths[0]

src = open(path).read()
for old, new in PAIRS:
    frm, to = (new, old) if revert else (old, new)
    if frm not in src:
        sys.exit(f"race-fix: pattern not found (runtime.go shape changed, or already in target state?):\n{frm[:80]}...")
    src = src.replace(frm, to, 1)

open(path, "w").write(src)
print(f"race-fix: {'reverted to old unsynchronized thunk' if revert else 'applied sync.Once fix'} on", path)
