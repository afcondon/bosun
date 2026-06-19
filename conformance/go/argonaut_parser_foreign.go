// Hand-written Go foreign for Data.Argonaut.Parser (argonaut-core 7.0.0).
//
// LIBRARY-level (not Bosun-specific): any purescript-go program that parses a
// JSON *string* in memory needs it — the sibling argonaut_core_foreign.go gives
// the `Json` views, this gives the string→Json parse. Lives in the Bosun repo
// for now (same posture as the core shim), copied into the build dir by the
// scripts that need it; an upstream candidate for backend-go's runtime once
// stable.
//
// `jsonParser :: String -> Either String Json` is `runFn3 _jsonParser Left
// Right`, so the foreign is `_jsonParser :: Fn3 (String->a) (Json->a) String a`
// — a variadic `func(args ...any) any` (args collected by runFn3): args[0] =
// Left, args[1] = Right, args[2] = the string. `encoding/json` decodes into the
// exact interface{} shape argonaut expects (map[string]any / []any / float64 /
// string / bool / nil), so success is just `succeed(v)`.
//
// backend-go ABI: foreign `Data.Argonaut.Parser._jsonParser` →
// `Data_Argonaut_Parser__jsonParser` (module sep `_` + the name's own leading `_`).
package main

import "encoding/json"

var Data_Argonaut_Parser__jsonParser any = func(args ...any) any {
	fail := args[0].(func(any) any)
	succeed := args[1].(func(any) any)
	s := args[2].(string)
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		return fail(err.Error())
	}
	return succeed(v)
}
