package main

import (
	"encoding/json"
	"strings"

	"github.com/proxy-wasm/proxy-wasm-go-sdk/proxywasm"
	"github.com/proxy-wasm/proxy-wasm-go-sdk/proxywasm/types"
)

func main() {}

func init() {
	proxywasm.SetVMContext(&vmContext{})
}

// --- VM context (one per WASM VM) ---

func (*vmContext) NewPluginContext(uint32) types.PluginContext {
	return &pluginContext{}
}

// --- Plugin context (one per filter config; owns the sensitive-headers list) ---

func (p *pluginContext) OnPluginStart(configSize int) types.OnPluginStartStatus {
	if configSize == 0 {
		proxywasm.LogInfof("go-request-logger: no plugin configuration — all headers logged in cleartext")
		return types.OnPluginStartStatusOK
	}

	data, err := proxywasm.GetPluginConfiguration()
	if err != nil {
		proxywasm.LogWarnf("go-request-logger: failed to read plugin config: %v", err)
		return types.OnPluginStartStatusOK
	}

	if err := json.Unmarshal(data, &p.config); err != nil {
		proxywasm.LogWarnf("go-request-logger: failed to parse plugin config: %v", err)
		return types.OnPluginStartStatusOK
	}

	// Normalize to lowercase so runtime comparison is case-insensitive.
	for i, h := range p.config.SensitiveHeaders {
		p.config.SensitiveHeaders[i] = strings.ToLower(h)
	}

	proxywasm.LogInfof("go-request-logger: sensitive headers configured: %v", p.config.SensitiveHeaders)
	return types.OnPluginStartStatusOK
}

func (p *pluginContext) NewHttpContext(contextID uint32) types.HttpContext {
	return &logger{config: &p.config}
}

// --- HTTP context (one per request) ---

func (l *logger) OnHttpRequestHeaders(_ int, endOfStream bool) types.Action {
	hs, err := proxywasm.GetHttpRequestHeaders()
	if err == nil {
		for _, h := range hs {
			l.headers = append(l.headers, [2]string{h[0], h[1]})
		}
	}

	if endOfStream {
		l.log(nil)
	}
	return types.ActionContinue
}

func (l *logger) OnHttpRequestBody(bodySize int, endOfStream bool) types.Action {
	if !endOfStream {
		return types.ActionPause
	}

	var body []byte
	if bodySize > 0 {
		var err error
		body, err = proxywasm.GetHttpRequestBody(0, bodySize)
		if err != nil {
			proxywasm.LogWarnf("go-request-logger: failed to read body: %v", err)
		}
	}
	l.log(body)
	return types.ActionContinue
}

func (l *logger) log(body []byte) {
	if l.logged {
		return
	}
	l.logged = true

	headers := make(map[string]string)
	for _, h := range l.headers {
		headers[h[0]] = h[1]
	}

	// Mask sensitive header values before logging.
	if l.config != nil {
		for _, sensitive := range l.config.SensitiveHeaders {
			for k := range headers {
				if strings.EqualFold(k, sensitive) {
					headers[k] = "***"
				}
			}
		}
	}

	entry := requestLog{
		Method:  headers[":method"],
		Path:    headers[":path"],
		Headers: headers,
	}
	if v, ok := headers[":authority"]; ok && strings.TrimSpace(v) != "" {
		entry.Authority = &v
	}
	if v, ok := headers[":scheme"]; ok && strings.TrimSpace(v) != "" {
		entry.Scheme = &v
	}
	if body != nil {
		s := string(body)
		entry.Body = &s
	}

	data, err := json.MarshalIndent(entry, "", "  ")
	if err != nil {
		proxywasm.LogWarnf("go-request-logger: failed to serialize request: %v", err)
		return
	}
	proxywasm.LogWarnf("go-request-logger:\n%s", string(data))
}
