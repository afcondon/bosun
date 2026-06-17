// Hand-written Go foreigns for Data.Argonaut.Core (argonaut-core 7.0.0).
//
// These are LIBRARY-level foreigns, not Bosun-specific — any purescript-go
// program that decodes JSON needs them — so they are upstream candidates for
// backend-go's runtime.go. They live in the Bosun repo for now (same posture
// as the os-exec shim: versioned with the app, can't be clobbered by backend-go,
// copied into the build dir by the apply-cli script). Once stable, offer them
// to backend-go.
//
// Representation: argonaut's opaque `Json` is, at runtime, exactly the decoded
// value — `map[string]any` (object) / `[]any` (array) / `float64` (number) /
// `string` / `bool` / `nil` (null) — which is precisely what `encoding/json`
// produces into an `interface{}`. So the `from*` coercions are identities and
// `_caseJson` is a type switch.
//
// backend-go ABI: foreign `Data.Argonaut.Core.name` → `var Data_Argonaut_Core_name`;
// a leading-underscore name (`_caseJson`) → `Data_Argonaut_Core__caseJson`
// (module sep `_` + the name's own `_`). An uncurried `FnN` foreign is a
// variadic `func(args ...any) any` (args collected by runFnN).
package main

// from* :: x -> Json — a typed view of the same runtime value (JS: `id`).
var Data_Argonaut_Core_fromBoolean any = func(x any) any { return x }
var Data_Argonaut_Core_fromNumber any = func(x any) any { return x }
var Data_Argonaut_Core_fromString any = func(x any) any { return x }
var Data_Argonaut_Core_fromArray any = func(x any) any { return x }
var Data_Argonaut_Core_fromObject any = func(x any) any { return x }

// jsonNull :: Json
var Data_Argonaut_Core_jsonNull any = nil

// _caseJson :: Fn7 (Unit->a) (Boolean->a) (Number->a) (String->a)
//                  (Array Json->a) (Object Json->a) Json a
// Every branch is a unary `func(any) any` (the null branch's argument is unit /
// ignored, mirroring the JS `isNull()` const-style call). Numbers are float64
// (encoding/json's interface{} number), but an int is tolerated and widened.
var Data_Argonaut_Core__caseJson any = func(args ...any) any {
	isNull := args[0].(func(any) any)
	isBool := args[1].(func(any) any)
	isNum := args[2].(func(any) any)
	isStr := args[3].(func(any) any)
	isArr := args[4].(func(any) any)
	isObj := args[5].(func(any) any)
	switch v := args[6].(type) {
	case nil:
		return isNull(nil)
	case bool:
		return isBool(v)
	case float64:
		return isNum(v)
	case int:
		return isNum(float64(v))
	case string:
		return isStr(v)
	case []any:
		return isArr(v)
	case map[string]any:
		return isObj(v)
	default:
		return isObj(args[6])
	}
}
