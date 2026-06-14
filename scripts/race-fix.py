#!/usr/bin/env python3
"""Patch a COPY of backend-go's runtime.go with the sync.Once thunk fix.

The proposed fix for the Phase-7 thunk thread-safety roadblock: make `_force`
thread-safe (and double-eval-proof) via a per-thunk sync.Once. Applied only to
the build-dir copy by go-race.sh --fixed; the source runtime.go is untouched.

Tradeoff: sync.Once replaces the eager-cycle `panic("cyclic strict
initialization")` — a genuine self-referential strict cycle would deadlock
rather than panic. backend-go's legit cyclic typeclass-dict clusters break their
cycles with deferred lazy `\\_ -> dict` edges (no synchronous re-force), so they
are unaffected; the lost diagnostic only matters for a real eager value cycle.
"""
import sys

path = sys.argv[1]
src = open(path).read()

repls = [
    # 1. add the sync import
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

for old, new in repls:
    if old not in src:
        sys.exit(f"race-fix: pattern not found (runtime.go shape changed?):\n{old[:80]}...")
    src = src.replace(old, new, 1)

open(path, "w").write(src)
print("race-fix: applied sync.Once thunk fix to", path)
