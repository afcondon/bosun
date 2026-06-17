// Bosun's hand-written Go foreigns for the file-driven apply-cli harness
// (Bosun.Conformance.ApplyCliMain) — APP-SPECIFIC, so they live in the Bosun
// repo (like the os-exec shim). `scripts/go-apply-cli.sh` copies this file into
// the backend-go build dir alongside the generated sources.
//
// These give the GO BINARY real file/argv I/O so it runs the SAME `runApply`
// pipeline as the node CLI against real files on disk, exercising the
// argonaut-core + foreign-object decode path (see the sibling shims).
//
// backend-go ABI: `EffectFn1 a b` foreign → uncurried `func(args ...any) any`
// returning the value (the effect runs when called); a bare `Effect a` →
// `func() any` thunk.
package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"

	"gopkg.in/yaml.v3"
)

// readJsonImpl :: EffectFn1 String Json
// Read a file and JSON-decode it into the interface{} shape argonaut expects
// (map[string]any / []any / float64 / string / bool / nil).
var Bosun_Conformance_ApplyCliMain_readJsonImpl any = func(args ...any) any {
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

// readYamlImpl :: EffectFn1 String Json
// Read a file and YAML-decode it, then NORMALISE to the exact runtime shape
// argonaut/foreign-object expect — the same shape `encoding/json` and js-yaml
// produce: map[string]any / []any / float64 (all numbers) / string / bool / nil.
// yaml.v3 into interface{} yields map[string]interface{} for mappings and int
// for whole numbers; `normalizeYaml` rewrites map keys to strings and widens
// every int to float64 so the decode path is identical to the JSON column.
var Bosun_Conformance_ApplyCliMain_readYamlImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		panic("readYaml: " + err.Error())
	}
	var v any
	if err := yaml.Unmarshal(data, &v); err != nil {
		panic("readYaml: " + path + ": " + err.Error())
	}
	return normalizeYaml(v)
}

// normalizeYaml maps a yaml.v3 decode onto the JSON/argonaut runtime shape.
func normalizeYaml(v any) any {
	switch x := v.(type) {
	case map[string]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[k] = normalizeYaml(val)
		}
		return r
	case map[any]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[toStr(k)] = normalizeYaml(val)
		}
		return r
	case []any:
		r := make([]any, len(x))
		for i, val := range x {
			r[i] = normalizeYaml(val)
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

func toStr(k any) string {
	if s, ok := k.(string); ok {
		return s
	}
	b, _ := json.Marshal(k)
	return string(b)
}

// argv :: Effect (Array String) — the args after the binary name.
var Bosun_Conformance_ApplyCliMain_argv any = func() any {
	out := make([]any, 0, len(os.Args)-1)
	for _, a := range os.Args[1:] {
		out = append(out, a)
	}
	return out
}

// execLineImpl :: EffectFn1 String { ok, code, message } — identical contract to
// the ApplyMain exec shim (a `… &` launch is detached fire-and-forget; else
// synchronous with captured output + a real exit code).
var Bosun_Conformance_ApplyCliMain_execLineImpl any = func(args ...any) any {
	line := args[0].(string)
	if strings.HasSuffix(strings.TrimSpace(line), "&") {
		if err := exec.Command("/bin/sh", "-c", line).Start(); err != nil {
			return map[string]any{"ok": false, "code": 1, "message": err.Error()}
		}
		return map[string]any{"ok": true, "code": 0, "message": "launched (backgrounded)"}
	}
	out, err := exec.Command("/bin/sh", "-c", line).CombinedOutput()
	if err != nil {
		code := 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
		return map[string]any{"ok": false, "code": code, "message": strings.TrimSpace(string(out))}
	}
	return map[string]any{"ok": true, "code": 0, "message": strings.TrimSpace(string(out))}
}
