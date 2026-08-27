// Envoy calls warn!(); output shows up in gateway pod logs.
use log::warn;
// Traits (HttpContext, RootContext) and types (Action, LogLevel) from the Proxy-Wasm SDK.
use proxy_wasm::traits::*;
use proxy_wasm::types::*;
// Build JSON logs without defining a Rust struct.
use serde_json::{json, Map, Value};

// Plugin entry point: runs once when Envoy loads the WASM module.
proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    // Root context: one instance per plugin VM (global setup; we don't use it for logging).
    proxy_wasm::set_root_context(|_| Box::new(Root));
    // HTTP context: one instance per incoming request — this is where we log.
    proxy_wasm::set_http_context(|_, _| Box::new(Logger { logged: false, headers: Vec::new() }));
}}

// Required by Proxy-Wasm; no per-request work here.
struct Root;
impl Context for Root {}
impl RootContext for Root {}

// Per-request state. Envoy creates a new Logger for each HTTP request.
struct Logger {
    logged: bool,
    // Headers captured during on_http_request_headers for use in the body callback.
    headers: Vec<(String, String)>,
}

impl Context for Logger {}

// Hooks Envoy invokes as the request flows through the filter.
impl HttpContext for Logger {
    fn on_http_request_headers(&mut self, _: usize, end_of_stream: bool) -> Action {
        // Capture headers now — they may not be accessible during the body callback.
        self.headers = self.get_http_request_headers();

        if end_of_stream {
            self.log(None);
        }
        Action::Continue
    }

    // Called when request body chunks arrive (POST, PUT, etc.).
    fn on_http_request_body(&mut self, body_size: usize, end_of_stream: bool) -> Action {
        // More body bytes may still be buffered — wait before reading.
        if !end_of_stream {
            return Action::Pause;
        }

        // Full body received; read it from Envoy's buffer (if any).
        let body = if body_size > 0 {
            self.get_http_request_body(0, body_size)
                .map(|b| String::from_utf8_lossy(&b).into_owned())
        } else {
            None
        };
        self.log(body);
        Action::Continue
    }
}

impl Logger {
    fn log(&mut self, body: Option<String>) {
        if self.logged {
            return;
        }
        self.logged = true;

        let mut headers = Map::new();
        let mut method = String::new();
        let mut path = String::new();
        let mut authority: Option<String> = None;
        let mut scheme: Option<String> = None;

        for (name, value) in &self.headers {
            match name.as_str() {
                ":method" => method = value.clone(),
                ":path" => path = value.clone(),
                ":authority" => authority = Some(value.clone()),
                ":scheme" => scheme = Some(value.clone()),
                _ => {}
            }
            headers.insert(name.clone(), Value::String(value.clone()));
        }

        let entry = json!({
            "method": method,
            "path": path,
            "authority": authority,
            "scheme": scheme,
            "headers": headers,
            "body": body,
        });

        warn!(
            "rust-request-logger:\n{}",
            serde_json::to_string_pretty(&entry).unwrap_or_else(|e| e.to_string())
        );
    }
}
