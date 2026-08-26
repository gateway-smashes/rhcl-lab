package main

import "github.com/proxy-wasm/proxy-wasm-go-sdk/proxywasm/types"

// pluginConfig holds the optional configuration parsed from the EnvoyFilter.
// When empty or absent, the plugin logs all header values in cleartext.
type pluginConfig struct {
	SensitiveHeaders []string `json:"sensitive_headers"`
}

// vmContext is the top-level Proxy-Wasm context (one per WASM VM).
type vmContext struct {
	types.DefaultVMContext
}

// pluginContext is created once per plugin instance; it owns the parsed config
// and spawns per-request HTTP contexts.
type pluginContext struct {
	types.DefaultPluginContext
	config pluginConfig
}

// Per-request state. Envoy creates a new logger for each HTTP request.
type logger struct {
	types.DefaultHttpContext
	logged  bool
	headers [][2]string
	config  *pluginConfig
}

// JSON shape emitted to Envoy logs. Pointer fields serialize as null when absent.
type requestLog struct {
	Method    string            `json:"method"`
	Path      string            `json:"path"`
	Authority *string           `json:"authority"`
	Scheme    *string           `json:"scheme"`
	Headers   map[string]string `json:"headers"`
	Body      *string           `json:"body"`
}
