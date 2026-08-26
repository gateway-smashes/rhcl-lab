"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

function parseBool(v, defaultValue = false) {
  if (v === undefined || v === "") return defaultValue;
  const s = String(v).toLowerCase();
  return s === "1" || s === "true" || s === "yes";
}

function parseHeadersJson(raw) {
  if (!raw || !String(raw).trim()) return {};
  try {
    const o = JSON.parse(raw);
    if (o && typeof o === "object" && !Array.isArray(o)) return o;
  } catch (_) {
    /* ignore */
  }
  return {};
}

function loadBodyFromEnv() {
  const file = process.env.RESPONSE_BODY_FILE;
  if (file) {
    const resolved = path.resolve(file);
    return fs.readFileSync(resolved);
  }
  const body = process.env.RESPONSE_BODY;
  if (body === undefined) return Buffer.from("");
  return Buffer.from(body, "utf8");
}

function buildConfig() {
  const port = parseInt(process.env.PORT || "8080", 10);
  const httpStatus = parseInt(process.env.HTTP_STATUS || "200", 10);
  const delayMs = Math.max(0, parseInt(process.env.DELAY_MS || "0", 10) || 0);
  const contentType = process.env.CONTENT_TYPE || "text/plain; charset=utf-8";
  const logLevel = (process.env.LOG_LEVEL || "info").toLowerCase();

  const corsEnabled = parseBool(process.env.CORS_ENABLED, false);
  const corsOrigin = process.env.ACCESS_CONTROL_ALLOW_ORIGIN || "*";
  const corsMethods =
    process.env.ACCESS_CONTROL_ALLOW_METHODS || "GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS";
  const corsHeaders =
    process.env.ACCESS_CONTROL_ALLOW_HEADERS || "Content-Type,Authorization";
  const corsCredentials = parseBool(process.env.ACCESS_CONTROL_ALLOW_CREDENTIALS, false);

  const extraHeaders = parseHeadersJson(process.env.RESPONSE_HEADERS);
  const responseBody = loadBodyFromEnv();

  return {
    port: Number.isFinite(port) ? port : 8080,
    httpStatus: Number.isFinite(httpStatus) ? httpStatus : 200,
    delayMs,
    contentType,
    logLevel,
    corsEnabled,
    corsOrigin,
    corsMethods,
    corsHeaders,
    corsCredentials,
    extraHeaders,
    responseBody,
  };
}

const config = buildConfig();

function log(msg) {
  if (config.logLevel === "silent") return;
  console.log(`[mock-api] ${msg}`);
}

function setCorsHeaders(res) {
  res.setHeader("Access-Control-Allow-Origin", config.corsOrigin);
  res.setHeader("Access-Control-Allow-Methods", config.corsMethods);
  res.setHeader("Access-Control-Allow-Headers", config.corsHeaders);
  if (config.corsCredentials) {
    res.setHeader("Access-Control-Allow-Credentials", "true");
  }
}

function applyExtraHeaders(res) {
  for (const [k, v] of Object.entries(config.extraHeaders)) {
    if (v !== undefined && v !== null) res.setHeader(k, String(v));
  }
}

function sendMockResponse(res) {
  if (config.corsEnabled) setCorsHeaders(res);
  res.setHeader("Content-Type", config.contentType);
  applyExtraHeaders(res);
  res.writeHead(config.httpStatus);
  res.end(config.responseBody);
}

const server = http.createServer((req, res) => {
  const url = req.url || "/";
  const method = (req.method || "GET").toUpperCase();

  if (method === "GET" && (url === "/health" || url.startsWith("/health?"))) {
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.writeHead(200);
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (method === "OPTIONS" && config.corsEnabled) {
    setCorsHeaders(res);
    res.setHeader("Access-Control-Max-Age", "86400");
    applyExtraHeaders(res);
    res.writeHead(204);
    res.end();
    return;
  }

  if (config.logLevel !== "silent" && !(method === "GET" && url.startsWith("/health"))) {
    log(`${method} ${url}`);
  }

  const run = () => {
    sendMockResponse(res);
  };

  if (config.delayMs > 0) {
    setTimeout(run, config.delayMs);
  } else {
    run();
  }
});

server.listen(config.port, () => {
  log(`listening on port ${config.port} (delay ${config.delayMs}ms, status ${config.httpStatus})`);
});

server.on("error", (err) => {
  console.error("[mock-api]", err);
  process.exit(1);
});
