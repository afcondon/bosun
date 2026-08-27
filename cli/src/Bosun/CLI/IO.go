// Bosun's hand-written Go twins of cli/src/Bosun/CLI/IO.js — the file/argv/URL
// I/O edge. Provides the REAL CLI foreign symbols `Bosun_CLI_IO_*`, so a
// backend-go build of the actual `Bosun.CLI.Main` (the `gnomon-bosun` binary,
// scripts/gnomon-bosun.sh) reads real compose.yml / registry.json off disk and
// runs the SAME pipeline the node CLI does. APP-SPECIFIC; backend-go stays
// dep-free — only THIS foreign imports yaml.v3 (the build adds a one-line go.mod,
// the go-apply-cli pattern).
//
// backend-go ABI: `EffectFn1 a b` → `func(args ...any) any` (runs + returns the
// value); a bare `Effect a` → `func() any` thunk. The returned Json must be the
// interface{} shape argonaut/foreign-object expect: map[string]any / []any /
// float64 (ALL numbers) / string / bool / nil.
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"

	"gopkg.in/yaml.v3"
)

// readJsonImpl :: EffectFn1 String Json — read a file and JSON-decode it.
var Bosun_CLI_IO_readJsonImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		panic("readJson: " + err.Error())
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		panic("readJson: " + path + ": " + err.Error())
	}
	return v
}

// readYamlImpl :: EffectFn1 String Json — read a file and YAML-decode it, then
// NORMALISE to the exact runtime shape argonaut/foreign-object expect (the same
// shape encoding/json and js-yaml produce). yaml.v3 into interface{} yields
// map[string]interface{} (or map[any]any) and `int` for whole numbers; we
// stringify keys and widen every int to float64 so the decode path is identical
// to the JSON column.
var Bosun_CLI_IO_readYamlImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		panic("readYaml: " + err.Error())
	}
	var v any
	if err := yaml.Unmarshal(data, &v); err != nil {
		panic("readYaml: " + path + ": " + err.Error())
	}
	return ioNormalizeYaml(v)
}

// readJsonUrlImpl :: EffectFn1 String Json — fetch a JSON URL via curl and parse
// (the no-Aff seam: straight-line, no callbacks). Used by `bosun serve` to read
// the live Marginalia registry; defined here so the symbol resolves even though
// the gnomon-bosun build stubs `serve` itself.
var Bosun_CLI_IO_readJsonUrlImpl any = func(args ...any) any {
	url := args[0].(string)
	out, err := exec.Command("curl", "-s", "--max-time", "10", url).Output()
	if err != nil {
		panic("readJsonUrl: " + url + ": " + err.Error())
	}
	var v any
	if err := json.Unmarshal(out, &v); err != nil {
		panic("readJsonUrl: " + url + ": " + err.Error())
	}
	return v
}

// argv :: Effect (Array String) — the args after the binary name (node's
// process.argv.slice(2) ≡ a native binary's os.Args[1:]).
var Bosun_CLI_IO_argv any = func() any {
	out := make([]any, 0, len(os.Args)-1)
	for _, a := range os.Args[1:] {
		out = append(out, a)
	}
	return out
}

func ioNormalizeYaml(v any) any {
	switch x := v.(type) {
	case map[string]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[k] = ioNormalizeYaml(val)
		}
		return r
	case map[any]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[ioYamlKey(k)] = ioNormalizeYaml(val)
		}
		return r
	case []any:
		r := make([]any, len(x))
		for i, val := range x {
			r[i] = ioNormalizeYaml(val)
		}
		return r
	case int:
		return float64(x)
	case int64:
		return float64(x)
	case uint64:
		return float64(x)
	default:
		return v
	}
}

// getJsonUrlImpl / postJsonUrlImpl :: EffectFn1 String HttpResult — talk to a
// LOCAL daemon's control surface without throwing. `readJsonUrlImpl` above is
// right for a source we REQUIRE (a failure there should abort); these are for a
// source we merely ask, where an unreachable router is an outcome `bosun reload`
// has to be able to report rather than die on. `{ ok, body, error }`, with
// `body` null whenever `ok` is false.
//
// No `-f`, deliberately, and for the same reason as the node twin: a non-2xx
// whose body is the daemon's own `{ok:false,error:…}` must reach the caller
// intact rather than be collapsed into a curl exit code that discards what the
// daemon actually said.
var Bosun_CLI_IO_getJsonUrlImpl any = func(args ...any) any {
	return ioJSONCurl(args[0].(string))
}

var Bosun_CLI_IO_postJsonUrlImpl any = func(args ...any) any {
	return ioJSONCurl(args[0].(string), "-X", "POST")
}

func ioJSONCurl(url string, extra ...string) map[string]any {
	flags := append([]string{"-sS", "--max-time", "8"}, extra...)
	cmd := exec.Command("curl", append(flags, url)...)
	// stderr is CAPTURED, not inherited: we report the failure, so curl must not
	// also print it (the node twin pipes it for the same reason).
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	out, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(errBuf.String())
		if detail == "" {
			detail = err.Error()
		}
		return map[string]any{"ok": false, "body": nil, "error": detail}
	}
	if strings.TrimSpace(string(out)) == "" {
		return map[string]any{"ok": true, "body": nil, "error": ""}
	}
	var v any
	if err := json.Unmarshal(out, &v); err != nil {
		return map[string]any{"ok": false, "body": nil, "error": err.Error()}
	}
	return map[string]any{"ok": true, "body": v, "error": ""}
}

func ioYamlKey(k any) string {
	if s, ok := k.(string); ok {
		return s
	}
	b, _ := json.Marshal(k)
	return string(b)
}
