// Spike foreign (BUILD-PLAN Phase 7): force a shared PureScript CAF from many
// goroutines at once, to probe backend-go thunk thread-safety. Owned by Bosun
// (like the apply foreign), copied into the build by scripts/go-race.sh.
package main

import "sync"

// forceConcurrentlyImpl :: EffectFn2 Int (Unit -> Int) (Array Int)
// Spawn n goroutines, each invoking the PureScript thunk-fn (which forces the
// shared CAF). Distinct result slots, so the only shared mutation is inside the
// CAF's `_force` — exactly what we're testing.
var Bosun_Conformance_RaceSpike_forceConcurrentlyImpl any = func(args ...any) any {
	n := args[0].(int)
	f := args[1].(func(any) any)
	results := make([]any, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = f(nil)
		}(i)
	}
	wg.Wait()
	return results
}
