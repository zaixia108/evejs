const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const net = require("net");
const tls = require("tls");
const http2 = require("http2");
const crypto = require("crypto");

const config = require("../../config");
const log = require("../../utils/logger");
const {
  ensureLocalLeafCertificate,
} = require("./localTlsCertificate");

let gatewayStreamHandler = null;
let mapTagsCdnAssetResolver = null;
// Shared HTTPS/h2 responder on loopback :httpPort+1 (self-test / legacy).
let localSecureResponderServer = null;
// Dedicated HTTP/1.1 HTTPS MITM for CONNECT intercept. Classic TCP tunnel to a
// clean listening socket — more reliable than wrapping the http.Server CONNECT
// socket in TLSSocket (that path ECONNRESETs under FRP for many clients).
let connectMitmHttpsServer = null;
let connectMitmPort = null;
/** @type {Promise<number>|null} */
let connectMitmListenPromise = null;

function getGatewayStreamHandler() {
  if (!gatewayStreamHandler) {
    ({ handleGatewayStream: gatewayStreamHandler } = require("./publicGatewayLocal"));
  }
  return gatewayStreamHandler;
}

function getMapTagsCdnAsset(routePath) {
  if (!mapTagsCdnAssetResolver) {
    ({ getMapTagsCdnAsset: mapTagsCdnAssetResolver } =
      require("./gatewayServices/mapTagsGatewayService"));
  }
  return mapTagsCdnAssetResolver(routePath);
}

function getGatewayBinaryAsset(routePath) {
  return getMapTagsCdnAsset(routePath) || null;
}

function shouldEnableLocalInterceptByDefault() {
  // Always intercept CCP public-gateway / LaunchDarkly by default.
  //
  // Older logic only enabled intercept when microservicesRedirectUrl was
  // loopback. Multiplayer/DDNS/FRP sets that URL to the public hostname, which
  // silently disabled intercept — CONNECT then dialed real CCP hosts and the
  // TLS handshake was reset (Diagnose: CONNECT 200, then "connection closed").
  //
  // Override with EVEJS_PROXY_LOCAL_INTERCEPT=0 if you intentionally want
  // transparent forward of those hosts.
  return true;
}

function parseBooleanEnv(value, fallback = false) {
  if (typeof value !== "string") {
    return fallback;
  }

  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }

  return fallback;
}

function parseOptionalUrl(value) {
  const normalized = String(value || "").trim();
  if (!normalized) {
    return null;
  }
  try {
    return new URL(normalized);
  } catch {
    return null;
  }
}

function parseNonNegativeIntegerEnv(value, fallback) {
  const parsed = Number.parseInt(String(value || "").trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return fallback;
  }
  return parsed;
}

function parseHostPatternList(value) {
  if (typeof value !== "string") {
    return [];
  }

  return value
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
}

function normalizeHostname(hostname) {
  const normalized = String(hostname || "").trim().toLowerCase();
  if (!normalized) {
    return "";
  }

  const bracketedIpv6 = normalized.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (bracketedIpv6) {
    return bracketedIpv6[1];
  }

  const colonIndex = normalized.lastIndexOf(":");
  if (
    colonIndex > -1 &&
    normalized.indexOf(":") === colonIndex &&
    /^\d+$/.test(normalized.slice(colonIndex + 1))
  ) {
    return normalized.slice(0, colonIndex);
  }

  return normalized;
}

function hostMatchesPattern(hostname, pattern) {
  const normalizedHost = normalizeHostname(hostname);
  const normalizedPattern = String(pattern || "").trim().toLowerCase();

  if (!normalizedHost || !normalizedPattern) {
    return false;
  }

  if (normalizedPattern.startsWith("*.")) {
    const suffix = normalizedPattern.slice(1);
    return (
      normalizedHost === normalizedPattern.slice(2) ||
      normalizedHost.endsWith(suffix)
    );
  }

  if (normalizedPattern.startsWith(".")) {
    return (
      normalizedHost === normalizedPattern.slice(1) ||
      normalizedHost.endsWith(normalizedPattern)
    );
  }

  return normalizedHost === normalizedPattern;
}

function hostMatchesAnyPattern(hostname, patterns) {
  if (!Array.isArray(patterns) || patterns.length === 0) {
    return false;
  }

  return patterns.some((pattern) => hostMatchesPattern(hostname, pattern));
}

function hostExistsInCollection(hostname, collection) {
  const normalizedHost = normalizeHostname(hostname);
  if (!normalizedHost) {
    return false;
  }

  if (collection instanceof Set) {
    return collection.has(normalizedHost);
  }

  if (Array.isArray(collection)) {
    return collection.some(
      (entry) => String(entry || "").trim().toLowerCase() === normalizedHost,
    );
  }

  return false;
}

function shouldInterceptHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (!normalized) {
    return false;
  }

  return LOCAL_INTERCEPT_HOSTS.has(normalized);
}

function shouldBlockHost(hostname) {
  if (shouldInterceptHost(hostname)) {
    return false;
  }
  return BLOCKED_PROXY_HOSTS.some((pattern) =>
    hostMatchesPattern(hostname, pattern),
  );
}

function shouldHandleLaunchDarklyHost(hostname) {
  const normalized = normalizeHostname(hostname);
  return LAUNCHDARKLY_INTERCEPT_HOSTS.has(normalized);
}

function shouldAllowListedHost(hostname, allowedHosts) {
  return hostMatchesAnyPattern(hostname, allowedHosts);
}

function normalizeUnhandledProxyHostPolicy(policy) {
  return String(policy || "block").trim().toLowerCase() === "forward"
    ? "forward"
    : "block";
}

function shouldDenyUnhandledProxyHost(hostname, options = {}) {
  const normalizedHost = normalizeHostname(hostname);
  if (!normalizedHost) {
    return true;
  }

  const interceptHosts = options.interceptHosts || LOCAL_INTERCEPT_HOSTS;
  const allowedHosts = Array.isArray(options.allowedHosts)
    ? options.allowedHosts
    : ALLOWED_PROXY_HOSTS;
  const policy = normalizeUnhandledProxyHostPolicy(options.policy);

  if (hostExistsInCollection(normalizedHost, interceptHosts)) {
    return false;
  }

  if (shouldAllowListedHost(normalizedHost, allowedHosts)) {
    return false;
  }

  return policy !== "forward";
}

function makeResponsePayload(req) {
  return {
    status: "ok",
    message: "microservice placeholder response",
    method: req.method,
    path: req.originalUrl || req.url,
    host: req.headers.host || null,
    timestamp: new Date().toISOString(),
  };
}

function makeHttp2Payload(headers) {
  return {
    status: "ok",
    message: "microservice placeholder response",
    method: headers[":method"] || null,
    path: headers[":path"] || null,
    host: headers[":authority"] || headers.host || null,
    timestamp: new Date().toISOString(),
  };
}

function makeHttp1Payload(req) {
  return {
    status: "ok",
    message: "microservice placeholder response",
    method: req.method || null,
    path: req.url || null,
    host: req.headers.host || null,
    timestamp: new Date().toISOString(),
  };
}

function getLocalChatAuthorityFlagValue() {
  return config.localChatAuthorityEnabled !== false;
}

function buildLaunchDarklyFlagValues() {
  return {
    "eve-local-chat-authority": getLocalChatAuthorityFlagValue(),
  };
}

function buildLaunchDarklyEvaluationPayload() {
  const payload = {
    $valid: true,
    $flagsState: {},
  };

  for (const [key, value] of Object.entries(buildLaunchDarklyFlagValues())) {
    const variation = value === true ? 0 : 1;
    payload[key] = {
      value,
      variation,
      version: 1,
      flagVersion: 1,
      trackEvents: false,
      debugEventsUntilDate: null,
      reason: { kind: "OFF" },
    };
    payload.$flagsState[key] = {
      variation,
      version: 1,
    };
  }

  return payload;
}

function shouldReturnLaunchDarklyEventStream(routePath, headers = {}) {
  const method = String(headers[":method"] || headers.method || "").toUpperCase();
  if (method !== "GET" && method !== "REPORT") {
    return false;
  }

  const normalizedPath = String(routePath || "/").toLowerCase();
  const accept = String(headers.accept || "").toLowerCase();
  const authority = String(headers[":authority"] || headers.host || "").toLowerCase();

  return (
    accept.includes("text/event-stream") ||
    authority === "clientstream.launchdarkly.com" ||
    authority === "stream.launchdarkly.com" ||
    normalizedPath.startsWith("/eval/") ||
    normalizedPath === "/eval" ||
    normalizedPath.startsWith("/meval") ||
    normalizedPath.startsWith("/ping/") ||
    normalizedPath === "/ping" ||
    normalizedPath.startsWith("/mping") ||
    normalizedPath === "/all" ||
    normalizedPath === "/flags"
  );
}

function isLaunchDarklyEventsRequest(routePath, headers = {}) {
  const authority = String(headers[":authority"] || headers.host || "").toLowerCase();
  const normalizedPath = String(routePath || "/").toLowerCase();

  return (
    authority === "events.launchdarkly.com" ||
    normalizedPath.includes("/events") ||
    normalizedPath.includes("/diagnostic") ||
    normalizedPath.includes("/bulk") ||
    normalizedPath.includes(".gif")
  );
}

function launchDarklyJsonResponseBody() {
  return JSON.stringify(buildLaunchDarklyEvaluationPayload());
}

function launchDarklyEventStreamBody() {
  return `event: put\ndata: ${launchDarklyJsonResponseBody()}\n\n`;
}

function handleLaunchDarklyHttp2Stream(stream, headers) {
  const authority = String(headers[":authority"] || headers.host || "");
  if (!shouldHandleLaunchDarklyHost(authority)) {
    return false;
  }

  const method = String(headers[":method"] || "").toUpperCase();
  const routePath = String(headers[":path"] || "/");

  log.proxy(`LaunchDarkly local ${method || "?"} ${routePath}`);

  if (method === "OPTIONS") {
    stream.respond({
      ":status": 204,
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization,content-type",
      "access-control-allow-methods": "GET,POST,REPORT,OPTIONS",
      "cache-control": "no-store",
    });
    stream.end();
    return true;
  }

  if (isLaunchDarklyEventsRequest(routePath, headers)) {
    stream.respond({
      ":status": 202,
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    stream.end("{}");
    return true;
  }

  if (shouldReturnLaunchDarklyEventStream(routePath, headers)) {
    stream.respond({
      ":status": 200,
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    });
    stream.end(launchDarklyEventStreamBody());
    return true;
  }

  stream.respond({
    ":status": 200,
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  stream.end(launchDarklyJsonResponseBody());
  return true;
}

function handleLaunchDarklyHttpRequest(req, res) {
  if (!shouldHandleLaunchDarklyHost(req.headers.host)) {
    return false;
  }

  const method = String(req.method || "").toUpperCase();
  const routePath = String(req.url || "/");
  log.proxy(`LaunchDarkly local ${method || "?"} ${routePath}`);

  if (method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization,content-type",
      "access-control-allow-methods": "GET,POST,REPORT,OPTIONS",
      "cache-control": "no-store",
    });
    res.end();
    return true;
  }

  if (isLaunchDarklyEventsRequest(routePath, req.headers)) {
    res.writeHead(202, {
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    res.end("{}");
    return true;
  }

  if (shouldReturnLaunchDarklyEventStream(routePath, {
    ...req.headers,
    method,
  })) {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    });
    res.end(launchDarklyEventStreamBody());
    return true;
  }

  res.writeHead(200, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(launchDarklyJsonResponseBody());
  return true;
}

function buildBinaryAssetHeaders(asset) {
  return {
    "content-type": asset.contentType || "application/octet-stream",
    "content-length": String(asset.buffer.length),
    "cache-control": "no-store",
  };
}

function parseConnectTarget(connectUrl) {
  const raw = String(connectUrl || "").trim();
  if (!raw) {
    return { host: null, port: null };
  }

  const idx = raw.lastIndexOf(":");
  if (idx === -1) {
    return { host: raw.toLowerCase(), port: 443 };
  }

  const host = raw.slice(0, idx).toLowerCase();
  const parsedPort = Number.parseInt(raw.slice(idx + 1), 10);
  return {
    host,
    port: Number.isFinite(parsedPort) ? parsedPort : 443,
  };
}

function parseHttpProxyTarget(req) {
  const rawUrl = String(req.url || "");
  if (/^https?:\/\//i.test(rawUrl)) {
    try {
      return new URL(rawUrl);
    } catch {
      return null;
    }
  }
  return null;
}

function isLoopbackHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

function getUrlPort(targetUrl) {
  const parsedPort = Number.parseInt(targetUrl.port || "", 10);
  if (Number.isFinite(parsedPort) && parsedPort > 0) {
    return parsedPort;
  }
  return targetUrl.protocol === "https:" ? 443 : 80;
}

function pipeHttpRequest(req, res, targetUrl) {
  const requestImpl = targetUrl.protocol === "https:" ? https : http;
  const targetHost = targetUrl.hostname;
  const targetPort = getUrlPort(targetUrl);

  const headers = { ...req.headers };
  headers.host = targetUrl.host;
  delete headers["proxy-connection"];

  log.proxy(`${req.method} ${targetUrl.href} -> ${targetHost}:${targetPort}`);

  const upstreamReq = requestImpl.request(
    {
      host: targetHost,
      port: targetPort,
      method: req.method,
      path: `${targetUrl.pathname}${targetUrl.search}`,
      headers,
    },
    (upstreamRes) => {
      res.statusCode = upstreamRes.statusCode || 502;
      for (const [k, v] of Object.entries(upstreamRes.headers)) {
        if (typeof v !== "undefined") {
          res.setHeader(k, v);
        }
      }
      upstreamRes.pipe(res);
    },
  );

  upstreamReq.on("error", (err) => {
    log.proxyErr(`forward failed ${targetUrl.href} ${err.message}`);
    if (!res.headersSent) {
      res.statusCode = 502;
      res.setHeader("content-type", "text/plain");
    }
    res.end("Bad Gateway");
  });

  req.pipe(upstreamReq);
}

function blockHttpProxyRequest(req, res, targetUrl) {
  log.proxy(`block ${req.method} ${targetUrl.href} -> local deny`);
  res.statusCode = 204;
  res.setHeader("x-evejs-proxy-blocked", "true");
  res.end();
}

function extractFirstPemCertificate(pemBundle) {
  const match = String(pemBundle || "").match(
    /-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/,
  );
  return match ? `${match[0].trim()}\n` : String(pemBundle || "");
}

function loadLocalTlsOptions() {
  const certDir = path.join(__dirname, "./certs");
  const certificateResult = ensureLocalLeafCertificate({ certDir });
  const gatewayLeafCertPath = path.join(certDir, "gateway-dev-cert.pem");
  const gatewayLeafKeyPath = path.join(certDir, "gateway-dev-key.pem");
  const pfxPath = path.join(certDir, "gateway-dev.pfx");
  const passphrasePath = path.join(certDir, "gateway-dev-passphrase.txt");
  const certPath = path.join(certDir, "gateway-dev-cert.pem");

  if (certificateResult.rebuilt) {
    log.success(
      "[Proxy] rebuilt local public-gateway TLS certificate (SChannel-friendly generation)",
    );
  }

  if (fs.existsSync(gatewayLeafCertPath) && fs.existsSync(gatewayLeafKeyPath)) {
    // Present LEAF only. Files often append the EveJS CA for distribution;
    // some TLS clients (SChannel / Diagnose) abort mid-handshake when that
    // self-signed CA is also sent as an intermediate over CONNECT/FRP.
    const fullPem = fs.readFileSync(gatewayLeafCertPath, "utf8");
    const leafPem = extractFirstPemCertificate(fullPem);
    return {
      tlsOptions: {
        key: fs.readFileSync(gatewayLeafKeyPath),
        cert: leafPem,
        allowHTTP1: true,
        ALPNProtocols: ["h2", "http/1.1"],
      },
      certPem: leafPem,
    };
  }

  if (fs.existsSync(pfxPath)) {
    return {
      tlsOptions: {
        pfx: fs.readFileSync(pfxPath),
        passphrase: fs.existsSync(passphrasePath)
          ? fs.readFileSync(passphrasePath, "utf8").trim()
          : "",
        allowHTTP1: true,
        ALPNProtocols: ["h2", "http/1.1"],
      },
      certPem: fs.existsSync(certPath) ? fs.readFileSync(certPath) : null,
    };
  }

  const legacyCertPath = path.join(certDir, "cert.pem");
  const legacyKeyPath = path.join(certDir, "key.pem");
  return {
    tlsOptions: {
      key: fs.readFileSync(legacyKeyPath),
      cert: fs.readFileSync(legacyCertPath),
      allowHTTP1: true,
      ALPNProtocols: ["h2", "http/1.1"],
    },
    certPem: fs.readFileSync(legacyCertPath),
  };
}

function createLoopbackCdnRequestHandler() {
  return (req, res) => {
    const routePath = String(req.url || "/");
    const binaryAsset =
      String(req.method || "").toUpperCase() === "GET"
        ? getGatewayBinaryAsset(routePath)
        : null;
    if (binaryAsset) {
      res.writeHead(200, buildBinaryAssetHeaders(binaryAsset));
      res.end(binaryAsset.buffer);
      return;
    }

    res.writeHead(404, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end("Not Found");
  };
}

function createLoopbackCdnResponder(
  activeHttpsPort,
  listenPort = 443,
  bindHost = "127.0.0.1",
) {
  if (activeHttpsPort === listenPort) {
    return null;
  }

  const { tlsOptions } = loadLocalTlsOptions();
  const server = https.createServer(
    tlsOptions,
    createLoopbackCdnRequestHandler(),
  );

  server.on("error", (err) => {
    log.http2Err(
      `loopback CDN responder failed on ${bindHost}:${listenPort}: ${err.message}`,
    );
  });
  server.listen(listenPort, bindHost, () => {
    log.debug(
      `loopback CDN responder listening on ${bindHost}:${listenPort}`,
    );
  });
  return server;
}

function createLocalSecureResponder(httpsPort, bindHost) {
  const { tlsOptions, certPem } = loadLocalTlsOptions();

  try {
    if (certPem) {
      const x509 = new crypto.X509Certificate(certPem);
      log.debug(
        `[local https cert] subject=${x509.subject} issuer=${x509.issuer} validTo=${x509.validTo}`,
      );
    }
  } catch (err) {
    log.http2Err(`cert parse error: ${err.message}`);
  }

  // allowHTTP1 is set in tlsOptions so non-h2 clients (Diagnose SslStream, etc.)
  // can complete the handshake; EVE still negotiates h2 via ALPN when available.
  const secureServer = http2.createSecureServer({
    ...tlsOptions,
    allowHTTP1: true,
    // Slightly more tolerant of high-latency paths (FRP / WAN).
    handshakeTimeout: 30_000,
  });

  secureServer.on("connection", (socket) => {
    try {
      socket.setNoDelay(true);
    } catch {
      // ignore
    }
    log.http2Log(`tcp connect ${socket.remoteAddress}:${socket.remotePort}`);
  });

  secureServer.on("secureConnection", (tlsSocket) => {
    log.http2Log(
      `tls established ${tlsSocket.remoteAddress} ALPN=${tlsSocket.alpnProtocol || "none"}`,
    );
  });

  secureServer.on("stream", (stream, headers) => {
    const method = headers[":method"] || "";
    const routePath = headers[":path"] || "";
    const authority = headers[":authority"] || headers.host || "";
    const contentType = String(headers["content-type"] || "");

    log.http2Log(
      `${method} ${routePath} host=${authority} type=${contentType || "none"}`,
    );

    stream.on("error", (err) => {
      log.http2Err(`stream error: ${err.message}`);
    });

    if (handleLaunchDarklyHttp2Stream(stream, headers)) {
      return;
    }

    const binaryAsset =
      method === "GET" ? getGatewayBinaryAsset(routePath) : null;
    if (binaryAsset) {
      stream.respond({
        ":status": 200,
        ...buildBinaryAssetHeaders(binaryAsset),
      });
      stream.end(binaryAsset.buffer);
      return;
    }

    if (
      contentType.includes("application/grpc") &&
      getGatewayStreamHandler()(stream, headers)
    ) {
      return;
    }

    let bodyLength = 0;
    stream.on("data", (chunk) => {
      bodyLength += chunk.length;
    });

    stream.on("end", () => {
      log.http2Log(`body ${bodyLength} bytes`);
    });

    if (contentType.includes("application/grpc")) {
      stream.respond(
        {
          ":status": 200,
          "content-type": "application/grpc+proto",
          "grpc-encoding": "identity",
          "grpc-accept-encoding": "identity",
        },
        { waitForTrailers: true },
      );
      stream.on("wantTrailers", () => {
        try {
          stream.sendTrailers({
            "grpc-status": "12",
            "grpc-message": encodeURIComponent(
              `EveJS Elysian local gateway has no handler for ${routePath}`,
            ),
          });
        } catch (err) {
          log.http2Err(`trailer error: ${err.message}`);
        }
      });
      stream.end();
      return;
    }

    stream.respond({
      ":status": 200,
      "content-type": "application/json",
    });
    stream.end(JSON.stringify(makeHttp2Payload(headers)));
  });

  secureServer.on("request", (req, res) => {
    if (Number(req.httpVersionMajor || 0) >= 2) {
      return;
    }

    if (handleLaunchDarklyHttpRequest(req, res)) {
      return;
    }

    res.writeHead(200, {
      "content-type": "application/json",
    });
    res.end(JSON.stringify(makeHttp1Payload(req)));
  });

  secureServer.on("sessionError", (err) => {
    log.http2Err(`session error: ${err.message}`);
  });

  secureServer.on("tlsClientError", (err, tlsSocket) => {
    log.http2Err(
      `tls client error: ${err.message} code=${err.code || "n/a"} ` +
        `reason=${err.reason || "n/a"} remote=${
          tlsSocket && tlsSocket.remoteAddress
            ? `${tlsSocket.remoteAddress}:${tlsSocket.remotePort || "?"}`
            : "n/a"
        }`,
    );
  });

  secureServer.on("error", (err) => {
    log.http2Err(`server error: ${err.message}`);
  });

  localSecureResponderServer = secureServer;
  secureServer.listen(httpsPort, bindHost, () => {
    log.success(
      `[Proxy] local public-gateway h2 responder on ${bindHost}:${httpsPort} ` +
        `(self-test/legacy; CONNECT uses LOCAL-MITM-HTTPS, intercept=${shouldHandleInterceptLocally()})`,
    );
    // Pure TLS self-test (no HTTP/2 preface). If this fails, certs/keys are bad.
    try {
      const probe = tls.connect(
        {
          host: localInterceptConnectHostForProbe(bindHost),
          port: httpsPort,
          servername: "dev-public-gateway.evetech.net",
          rejectUnauthorized: false,
          ALPNProtocols: ["http/1.1", "h2"],
        },
        () => {
          log.success(
            `[Proxy] self-test TLS handshake OK ALPN=${probe.alpnProtocol || "none"}`,
          );
          probe.end();
        },
      );
      probe.setTimeout(5000, () => {
        log.http2Err("[Proxy] self-test TLS timeout");
        probe.destroy();
      });
      probe.on("error", (err) => {
        log.http2Err(`[Proxy] self-test TLS FAIL: ${err.message}`);
      });
    } catch (err) {
      log.http2Err(`[Proxy] self-test TLS setup FAIL: ${err.message}`);
    }
  });
}

function localInterceptConnectHostForProbe(bindHost) {
  return resolveLocalInterceptConnectHost(bindHost);
}

function handleConnectMitmHttpRequest(req, res) {
  if (handleLaunchDarklyHttpRequest(req, res)) {
    return;
  }
  const routePath = String((req.url || "").split("?")[0] || "/");
  const binaryAsset =
    String(req.method || "").toUpperCase() === "GET"
      ? getGatewayBinaryAsset(routePath)
      : null;
  if (binaryAsset) {
    res.writeHead(200, buildBinaryAssetHeaders(binaryAsset));
    res.end(binaryAsset.buffer);
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(makeHttp1Payload(req)));
}

/**
 * Dedicated HTTP/1.1 HTTPS server for CONNECT intercept.
 * Classic pattern: client CONNECT -> 200 -> TCP pipe -> this server's TLS.
 * Avoids wrapping the http.Server CONNECT socket in TLSSocket (ECONNRESET under
 * FRP) and avoids HTTP/2 preface requirements that break Diagnose/SslStream.
 */
function ensureConnectMitmHttpsServer() {
  if (connectMitmHttpsServer) {
    return connectMitmHttpsServer;
  }
  const { tlsOptions } = loadLocalTlsOptions();
  connectMitmHttpsServer = https.createServer(
    {
      key: tlsOptions.key,
      cert: tlsOptions.cert,
      minVersion: "TLSv1.2",
      maxVersion: "TLSv1.2",
    },
    handleConnectMitmHttpRequest,
  );
  connectMitmHttpsServer.on("secureConnection", (tlsSocket) => {
    log.success(
      `[Proxy] CONNECT TLS-OK ALPN=${tlsSocket.alpnProtocol || "none"} ` +
        `proto=${tlsSocket.getProtocol && tlsSocket.getProtocol()} ` +
        `(LOCAL-MITM-HTTPS)`,
    );
    try {
      tlsSocket.__evejsMitmHandshakeOk = true;
    } catch {
      // ignore
    }
    tlsSocket.on("error", (err) => {
      if (
        tlsSocket.__evejsMitmHandshakeOk &&
        /hang up|ECONNRESET|ECONNABORTED|EPIPE/i.test(String(err && err.message))
      ) {
        log.debug(
          `connect-mitm post-handshake close: ${err.message} code=${err.code || "n/a"}`,
        );
        return;
      }
      log.http2Err(
        `connect-mitm socket error: ${err.message} code=${err.code || "n/a"}`,
      );
    });
  });
  connectMitmHttpsServer.on("tlsClientError", (err, tlsSocket) => {
    const msg = String((err && err.message) || err || "");
    const code = err && err.code;
    const reason = err && err.reason;
    const handshakeOk = tlsSocket && tlsSocket.__evejsMitmHandshakeOk;
    // Always surface pre-handshake failures (unknown ca, bad cert, protocol).
    // Only quiet post-success hang-ups from Diagnose dispose.
    if (
      handshakeOk &&
      (code === "ECONNRESET" || /hang up|ECONNRESET|ECONNABORTED/i.test(msg))
    ) {
      log.debug(
        `connect-mitm tls client close after TLS-OK: ${msg} code=${code || "n/a"}`,
      );
      return;
    }
    log.http2Err(
      `connect-mitm tls client error: ${msg} code=${code || "n/a"}` +
        ` reason=${reason || "n/a"} library=${(err && err.library) || "n/a"}`,
    );
  });
  connectMitmHttpsServer.on("error", (err) => {
    log.http2Err(`connect-mitm server error: ${err.message}`);
  });
  return connectMitmHttpsServer;
}

function ensureConnectMitmHttpsServerAsync() {
  if (connectMitmPort) {
    return Promise.resolve(connectMitmPort);
  }
  if (connectMitmListenPromise) {
    return connectMitmListenPromise;
  }

  connectMitmListenPromise = new Promise((resolve, reject) => {
    try {
      const server = ensureConnectMitmHttpsServer();
      if (connectMitmPort) {
        resolve(connectMitmPort);
        return;
      }
      server.once("error", (err) => {
        connectMitmListenPromise = null;
        reject(err);
      });
      server.listen(0, "127.0.0.1", () => {
        connectMitmPort = server.address().port;
        log.success(
          `[Proxy] CONNECT MITM HTTPS ready on 127.0.0.1:${connectMitmPort} ` +
            `(HTTP/1.1, path=LOCAL-MITM-HTTPS)`,
        );
        // Pure loopback TLS self-test (no proxy hop).
        try {
          const probe = tls.connect(
            {
              host: "127.0.0.1",
              port: connectMitmPort,
              servername: "dev-public-gateway.evetech.net",
              rejectUnauthorized: false,
              minVersion: "TLSv1.2",
              maxVersion: "TLSv1.2",
            },
            () => {
              log.success(
                `[Proxy] MITM self-test TLS OK ALPN=${probe.alpnProtocol || "none"} ` +
                  `proto=${probe.getProtocol && probe.getProtocol()}`,
              );
              probe.end();
            },
          );
          probe.setTimeout(5000, () => {
            log.http2Err("[Proxy] MITM self-test TLS timeout");
            probe.destroy();
          });
          probe.on("error", (err) => {
            log.http2Err(`[Proxy] MITM self-test TLS FAIL: ${err.message}`);
          });
        } catch (err) {
          log.http2Err(`[Proxy] MITM self-test setup FAIL: ${err.message}`);
        }
        resolve(connectMitmPort);
      });
    } catch (err) {
      connectMitmListenPromise = null;
      reject(err);
    }
  });
  return connectMitmListenPromise;
}

/**
 * Terminate TLS directly on the CONNECT socket (no second TCP hop).
 * Handshake completion is enough for Diagnose; HTTP/1.1 is handed to the
 * MITM https.Server request pipeline when the client sends application data.
 */
/** Non-listening HTTP server used only to parse HTTP/1.1 after WRAP TLS. */
let connectWrapHttpServer = null;

function getConnectWrapHttpServer() {
  if (!connectWrapHttpServer) {
    // Plain http.Server: we feed it already-decrypted TLS sockets via 'connection'.
    connectWrapHttpServer = http.createServer(handleConnectMitmHttpRequest);
    connectWrapHttpServer.on("error", (err) => {
      log.http2Err(`connect-wrap http server error: ${err.message}`);
    });
  }
  return connectWrapHttpServer;
}

function attachConnectTlsWrap(clientSocket, head, label) {
  const { tlsOptions } = loadLocalTlsOptions();

  try {
    clientSocket.setTimeout(0);
    clientSocket.setNoDelay(true);
    clientSocket.setKeepAlive(true, 15_000);
  } catch {
    // ignore
  }

  // Minimal CONNECT response (no extra headers — FRP-friendly).
  const established = "HTTP/1.1 200 Connection Established\r\n\r\n";

  clientSocket.write(established, (writeErr) => {
    if (writeErr) {
      log.proxyErr(`CONNECT 200 write failed ${label}: ${writeErr.message}`);
      try {
        clientSocket.destroy();
      } catch {
        // ignore
      }
      return;
    }

    // Do NOT removeAllListeners / pause-drain: that races with FRP and drops
    // ClientHello. Only unshift early body bytes from the HTTP parser.
    if (head && head.length > 0) {
      try {
        clientSocket.unshift(
          Buffer.isBuffer(head) ? head : Buffer.from(head),
        );
      } catch (err) {
        log.proxyErr(`CONNECT unshift failed ${label}: ${err.message}`);
      }
    }

    let tlsSocket;
    try {
      tlsSocket = new tls.TLSSocket(clientSocket, {
        isServer: true,
        key: tlsOptions.key,
        cert: tlsOptions.cert,
        minVersion: "TLSv1.2",
        maxVersion: "TLSv1.2",
        rejectUnauthorized: false,
        handshakeTimeout: 30_000,
      });
    } catch (err) {
      log.proxyErr(`CONNECT TLS wrap create failed ${label}: ${err.message}`);
      try {
        clientSocket.destroy();
      } catch {
        // ignore
      }
      return;
    }

    const peer =
      clientSocket.remoteAddress != null
        ? `${clientSocket.remoteAddress}:${clientSocket.remotePort || "?"}`
        : "n/a";
    log.proxy(`CONNECT ${label} -> LOCAL-WRAP-TLS peer=${peer}`);

    tlsSocket.once("secure", () => {
      log.success(
        `[Proxy] CONNECT TLS-OK ${label} ALPN=${
          tlsSocket.alpnProtocol || "none"
        } ` +
          `proto=${tlsSocket.getProtocol && tlsSocket.getProtocol()} ` +
          `(LOCAL-WRAP-TLS)`,
      );
      try {
        tlsSocket.__evejsMitmHandshakeOk = true;
      } catch {
        // ignore
      }
      try {
        getConnectWrapHttpServer().emit("connection", tlsSocket);
      } catch (err) {
        log.http2Err(
          `CONNECT WRAP HTTP handoff failed ${label}: ${err.message}`,
        );
      }
    });

    tlsSocket.on("error", (err) => {
      const msg = String((err && err.message) || err || "");
      const code = err && err.code;
      const reason = err && err.reason;
      if (
        tlsSocket.__evejsMitmHandshakeOk &&
        /hang up|ECONNRESET|ECONNABORTED|EPIPE/i.test(msg)
      ) {
        log.debug(
          `connect-wrap post-handshake close: ${msg} code=${code || "n/a"}`,
        );
        return;
      }
      log.http2Err(
        `connect-wrap tls error: ${msg} code=${code || "n/a"} ` +
          `reason=${reason || "n/a"} peer=${peer}`,
      );
    });
  });

  return true;
}

/**
 * Tunnel CONNECT through a clean loopback HTTPS (HTTP/1.1) listener.
 *
 * Order matters for Node's HTTP CONNECT socket + remote SslStream:
 *   1) pause client (Node may already have paused it)
 *   2) dial MITM loopback
 *   3) write "200 Connection Established" and wait for write callback
 *   4) splice bytes (head + data)
 *   5) resume client
 *
 * The previous "200-first + early close handlers" path produced ▲0B ▼0B
 * (client never reached TLS) under FRP/Diagnose.
 */
function attachConnectViaMitmHttpsTunnel(clientSocket, head, label) {
  if (!connectMitmPort) {
    return false;
  }

  const mitmPort = connectMitmPort;
  const tunnelLabel = `${label} via MITM 127.0.0.1:${mitmPort}`;

  try {
    clientSocket.pause();
  } catch {
    // ignore
  }
  try {
    clientSocket.setTimeout(0);
  } catch {
    // ignore
  }

  let settled = false;
  const failDial = (err) => {
    if (settled) {
      return;
    }
    settled = true;
    log.proxyErr(
      `CONNECT MITM dial error ${label}: ${err && err.message ? err.message : err}`,
    );
    if (!clientSocket.destroyed) {
      try {
        clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
      } catch {
        // ignore
      }
      clientSocket.destroy();
    }
  };

  const upstream = net.connect({ host: "127.0.0.1", port: mitmPort }, () => {
    const established =
      "HTTP/1.1 200 Connection Established\r\n" +
      "Proxy-Agent: EveJS Elysian\r\n" +
      "\r\n";

    clientSocket.write(established, (writeErr) => {
      if (writeErr) {
        failDial(writeErr);
        try {
          upstream.destroy();
        } catch {
          // ignore
        }
        return;
      }
      if (settled || clientSocket.destroyed) {
        try {
          upstream.destroy();
        } catch {
          // ignore
        }
        return;
      }
      settled = true;

      log.proxy(`CONNECT ${label} -> LOCAL-MITM-HTTPS 127.0.0.1:${mitmPort}`);

      // Classic bidirectional pipe — simplest splice for TLS-over-CONNECT.
      try {
        clientSocket.setNoDelay(true);
        upstream.setNoDelay(true);
        clientSocket.setTimeout(0);
        upstream.setTimeout(0);
      } catch {
        // ignore
      }

      let upBytes = 0;
      let downBytes = 0;
      let closed = false;
      const finish = (why) => {
        if (closed) {
          return;
        }
        closed = true;
        log.proxy(
          `tunnel closed ${tunnelLabel} ▲${upBytes}B ▼${downBytes}B${
            why ? ` (${why})` : ""
          }`,
        );
        try {
          if (!clientSocket.destroyed) {
            clientSocket.destroy();
          }
        } catch {
          // ignore
        }
        try {
          if (!upstream.destroyed) {
            upstream.destroy();
          }
        } catch {
          // ignore
        }
      };

      if (head && head.length > 0) {
        upstream.write(head);
        upBytes += head.length;
      }
      clientSocket.on("data", (chunk) => {
        upBytes += chunk.length;
        if (!upstream.destroyed) {
          upstream.write(chunk);
        }
      });
      upstream.on("data", (chunk) => {
        downBytes += chunk.length;
        if (!clientSocket.destroyed) {
          clientSocket.write(chunk);
        }
      });
      clientSocket.on("close", () => finish("client-close"));
      upstream.on("close", () => finish("upstream-close"));
      clientSocket.on("error", () => finish("client-error"));
      upstream.on("error", () => finish("upstream-error"));

      try {
        clientSocket.resume();
      } catch {
        // ignore
      }
    });
  });

  upstream.once("error", failDial);
  clientSocket.once("error", () => {
    if (!settled) {
      settled = true;
    }
    try {
      upstream.destroy();
    } catch {
      // ignore
    }
  });

  return true;
}

/**
 * After the public proxy is listening, CONNECT to ourselves then TLS.
 * Proves MITM path works end-to-end with OpenSSL (not SChannel).
 */
function runFullPathConnectTlsSelfTest(httpPort, bindHost) {
  const dialHost =
    bindHost === "0.0.0.0" || bindHost === "::" || bindHost === "[::]"
      ? "127.0.0.1"
      : bindHost;
  try {
    const req = http.request({
      host: dialHost,
      port: httpPort,
      method: "CONNECT",
      path: "dev-public-gateway.evetech.net:443",
      headers: {
        Host: "dev-public-gateway.evetech.net:443",
      },
      timeout: 5000,
    });
    req.on("connect", (res, socket, head) => {
      if (res.statusCode !== 200) {
        log.http2Err(
          `[Proxy] full-path CONNECT self-test bad status ${res.statusCode}`,
        );
        socket.destroy();
        return;
      }
      if (head && head.length > 0) {
        try {
          socket.unshift(head);
        } catch {
          // ignore
        }
      }
      const probe = tls.connect(
        {
          socket,
          servername: "dev-public-gateway.evetech.net",
          rejectUnauthorized: false,
          minVersion: "TLSv1.2",
          maxVersion: "TLSv1.2",
        },
        () => {
          log.success(
            `[Proxy] full-path CONNECT+TLS self-test OK ` +
              `ALPN=${probe.alpnProtocol || "none"} ` +
              `proto=${probe.getProtocol && probe.getProtocol()}`,
          );
          probe.end();
          try {
            socket.destroy();
          } catch {
            // ignore
          }
        },
      );
      probe.on("error", (err) => {
        log.http2Err(
          `[Proxy] full-path CONNECT+TLS self-test FAIL: ${err.message}`,
        );
      });
    });
    req.on("error", (err) => {
      log.http2Err(
        `[Proxy] full-path CONNECT self-test dial FAIL: ${err.message}`,
      );
    });
    req.on("timeout", () => {
      req.destroy(new Error("timeout"));
    });
    req.end();
  } catch (err) {
    log.http2Err(
      `[Proxy] full-path CONNECT self-test setup FAIL: ${err.message}`,
    );
  }
}

function wireTunnel(clientSocket, upstreamSocket, head, label, options = {}) {
  let upBytes = 0;
  let downBytes = 0;
  let closed = false;
  const idleTimeoutMs = Number.isFinite(options.idleTimeoutMs)
    ? options.idleTimeoutMs
    : DEFAULT_PROXY_TUNNEL_IDLE_TIMEOUT_MS;

  // Critical for TLS-over-CONNECT (public-gateway) especially through FRP:
  // disable Nagle so ClientHello / ServerHello are not delayed or coalesced badly.
  clientSocket.setNoDelay(true);
  clientSocket.setKeepAlive(true, SOCKET_KEEPALIVE_INITIAL_DELAY_MS);
  clientSocket.setTimeout(0);
  upstreamSocket.setNoDelay(true);
  upstreamSocket.setKeepAlive(true, SOCKET_KEEPALIVE_INITIAL_DELAY_MS);
  upstreamSocket.setTimeout(idleTimeoutMs > 0 ? idleTimeoutMs : 0);

  const finish = (why) => {
    if (closed) {
      return;
    }
    closed = true;
    log.proxy(`tunnel closed ${label} ▲${upBytes}B ▼${downBytes}B${why ? ` (${why})` : ""}`);
    if (!clientSocket.destroyed) {
      clientSocket.destroy();
    }
    if (!upstreamSocket.destroyed) {
      upstreamSocket.destroy();
    }
  };

  if (head && head.length > 0) {
    upstreamSocket.write(head);
    upBytes += head.length;
  }

  // Manual forward instead of dual pipe+data-listeners (avoids rare stream races
  // when ClientHello arrives immediately after the 200 Connection Established).
  clientSocket.on("data", (chunk) => {
    upBytes += chunk.length;
    if (!upstreamSocket.destroyed) {
      const ok = upstreamSocket.write(chunk);
      if (!ok) {
        clientSocket.pause();
      }
    }
  });
  upstreamSocket.on("data", (chunk) => {
    downBytes += chunk.length;
    if (!clientSocket.destroyed) {
      const ok = clientSocket.write(chunk);
      if (!ok) {
        upstreamSocket.pause();
      }
    }
  });
  clientSocket.on("drain", () => {
    if (!upstreamSocket.destroyed) {
      upstreamSocket.resume();
    }
  });
  upstreamSocket.on("drain", () => {
    if (!clientSocket.destroyed) {
      clientSocket.resume();
    }
  });

  if (idleTimeoutMs > 0) {
    upstreamSocket.on("timeout", () => {
      log.proxyErr(`tunnel timeout ${label} ▲${upBytes}B ▼${downBytes}B`);
      finish("timeout");
    });
  }

  upstreamSocket.on("close", () => finish("upstream-close"));
  clientSocket.on("close", () => finish("client-close"));
  upstreamSocket.on("error", (err) => {
    log.proxyErr(`tunnel upstream error ${label} ${err.message}`);
    finish("upstream-error");
  });
  clientSocket.on("error", (err) => {
    log.proxyErr(`tunnel client error ${label} ${err.message}`);
    finish("client-error");
  });
  clientSocket.on("end", () => {
    if (!upstreamSocket.destroyed) {
      upstreamSocket.end();
    }
  });
  upstreamSocket.on("end", () => {
    if (!clientSocket.destroyed) {
      clientSocket.end();
    }
  });
}

function buildForwardTargetUrl(upstreamBaseUrl, requestPath) {
  return new URL(String(requestPath || "/"), upstreamBaseUrl);
}

function resolveListenUrl() {
  try {
    return new URL(config.microservicesPublicBaseUrl);
  } catch {
    return new URL("http://127.0.0.1:26002/");
  }
}

function resolveBindHost(listenUrl) {
  const configuredBindHost = String(config.microservicesBindHost || "").trim();
  if (configuredBindHost) {
    return configuredBindHost;
  }
  return isLoopbackHost(listenUrl.hostname) ? "127.0.0.1" : listenUrl.hostname;
}

// net.connect() must never target a wildcard listen address. When the proxy
// binds on 0.0.0.0 for multiplayer, CONNECT intercepts still tunnel to the
// local HTTPS responder over loopback — the same path single-player uses.
function resolveLocalInterceptConnectHost(bindHost) {
  const host = String(bindHost || "").trim().toLowerCase();
  if (
    !host ||
    host === "0.0.0.0" ||
    host === "::" ||
    host === "[::]" ||
    host === "*"
  ) {
    return "127.0.0.1";
  }
  return String(bindHost).trim();
}

const ENABLE_LOCAL_INTERCEPT = parseBooleanEnv(
  process.env.EVEJS_PROXY_LOCAL_INTERCEPT,
  shouldEnableLocalInterceptByDefault(),
);
const EXPRESS_PROXY_ENABLED = parseBooleanEnv(
  process.env.EVEJS_EXPRESS_PROXY_ENABLED,
  true,
);
const LOOPBACK_CDN_LISTEN_PORT = parseNonNegativeIntegerEnv(
  process.env.EVEJS_PROXY_LOOPBACK_CDN_LISTEN_PORT,
  443,
);
const PROXY_FORWARD_UPSTREAM_URL = parseOptionalUrl(
  process.env.EVEJS_PROXY_UPSTREAM_BASE_URL,
);
const PROXY_GATEWAY_MODE = String(
  process.env.EVEJS_PROXY_GATEWAY_MODE ||
    (PROXY_FORWARD_UPSTREAM_URL ? "forward" : "local"),
)
  .trim()
  .toLowerCase();
const DEFAULT_PROXY_TUNNEL_IDLE_TIMEOUT_MS = parseNonNegativeIntegerEnv(
  process.env.EVEJS_PROXY_TUNNEL_IDLE_TIMEOUT_MS,
  30_000,
);
const INTERCEPT_PROXY_TUNNEL_IDLE_TIMEOUT_MS = parseNonNegativeIntegerEnv(
  process.env.EVEJS_PROXY_INTERCEPT_TUNNEL_IDLE_TIMEOUT_MS,
  0,
);
const SOCKET_KEEPALIVE_INITIAL_DELAY_MS = parseNonNegativeIntegerEnv(
  process.env.EVEJS_PROXY_SOCKET_KEEPALIVE_INITIAL_DELAY_MS,
  15_000,
);
const LOCAL_INTERCEPT_HOSTS = new Set([
  "dev-public-gateway.evetech.net",
  "public-gateway.evetech.net",
  "app.launchdarkly.com",
  "clientstream.launchdarkly.com",
  "clientsdk.launchdarkly.com",
  "events.launchdarkly.com",
  "stream.launchdarkly.com",
]);
const LAUNCHDARKLY_INTERCEPT_HOSTS = new Set([
  "app.launchdarkly.com",
  "clientstream.launchdarkly.com",
  "clientsdk.launchdarkly.com",
  "events.launchdarkly.com",
  "stream.launchdarkly.com",
]);
const BLOCKED_PROXY_HOSTS = parseHostPatternList(config.proxyBlockedHosts);
const ALLOWED_PROXY_HOSTS = (() => {
  const configured = parseHostPatternList(config.proxyAllowedHosts);
  const derived = ["clientresources.eveonline.com"];
  const imageUrl = parseOptionalUrl(config.imageServerUrl);
  if (imageUrl && imageUrl.hostname && !isLoopbackHost(imageUrl.hostname)) {
    derived.push(imageUrl.hostname);
  }
  return [...configured, ...derived];
})();
const PROXY_UNHANDLED_HOST_POLICY = normalizeUnhandledProxyHostPolicy(
  config.proxyUnhandledHostPolicy,
);

function shouldHandleInterceptLocally() {
  return ENABLE_LOCAL_INTERCEPT && PROXY_GATEWAY_MODE !== "forward";
}

function shouldForwardInterceptToUpstream() {
  return (
    ENABLE_LOCAL_INTERCEPT &&
    PROXY_GATEWAY_MODE === "forward" &&
    Boolean(PROXY_FORWARD_UPSTREAM_URL)
  );
}

function getGatewayUpstreamTarget(defaultPort) {
  if (!PROXY_FORWARD_UPSTREAM_URL) {
    return null;
  }

  const configuredHost = String(
    process.env.EVEJS_PROXY_GATEWAY_UPSTREAM_HOST || "",
  ).trim();
  const configuredPort = Number.parseInt(
    process.env.EVEJS_PROXY_GATEWAY_UPSTREAM_PORT || "",
    10,
  );

  return {
    host: configuredHost || PROXY_FORWARD_UPSTREAM_URL.hostname,
    port: Number.isFinite(configuredPort) && configuredPort > 0
      ? configuredPort
      : defaultPort,
  };
}

function startServer() {
  const express = require("express");
  const app = express();

  app.use((req, res, next) => {
    const targetUrl = parseHttpProxyTarget(req);
    const shouldForwardLoopbackImage =
      targetUrl &&
      isLoopbackHost(targetUrl.hostname) &&
      Number.parseInt(targetUrl.port || "80", 10) === 26001;

    if (shouldForwardLoopbackImage) {
      pipeHttpRequest(req, res, targetUrl);
      return;
    }

    if (targetUrl && shouldBlockHost(targetUrl.hostname)) {
      blockHttpProxyRequest(req, res, targetUrl);
      return;
    }

    if (targetUrl && ENABLE_LOCAL_INTERCEPT && shouldInterceptHost(targetUrl.hostname)) {
      if (shouldHandleInterceptLocally()) {
        log.proxy(`intercept ${req.method} ${targetUrl.href} -> local`);
        next();
        return;
      }

      if (shouldForwardInterceptToUpstream()) {
        const upstreamTargetUrl = buildForwardTargetUrl(
          PROXY_FORWARD_UPSTREAM_URL,
          `${targetUrl.pathname}${targetUrl.search}`,
        );
        log.proxy(`intercept ${req.method} ${targetUrl.href} -> upstream ${upstreamTargetUrl.href}`);
        pipeHttpRequest(req, res, upstreamTargetUrl);
        return;
      }
    }

    if (targetUrl) {
      if (shouldDenyUnhandledProxyHost(targetUrl.hostname, {
        interceptHosts: LOCAL_INTERCEPT_HOSTS,
        allowedHosts: ALLOWED_PROXY_HOSTS,
        policy: PROXY_UNHANDLED_HOST_POLICY,
      })) {
        blockHttpProxyRequest(req, res, targetUrl);
        return;
      }
      pipeHttpRequest(req, res, targetUrl);
      return;
    }

    log.proxy(`${req.method} ${req.url} host=${req.headers.host || "?"}`);
    next();
  });

  app.use(express.json({ limit: "1mb" }));

  app.get("/health", (req, res) => {
    res.status(200).json({
      status: "ok",
      service: "express-secondary",
      gatewayMode: shouldForwardInterceptToUpstream()
        ? "forward"
        : shouldHandleInterceptLocally()
          ? "local"
          : "transparent",
      localIntercept: shouldHandleInterceptLocally(),
      localSecureResponder: Boolean(localSecureResponderServer),
      connectMitmHttps: Boolean(connectMitmPort),
      connectMitmPort: connectMitmPort || null,
      upstreamBaseUrl: PROXY_FORWARD_UPSTREAM_URL
        ? PROXY_FORWARD_UPSTREAM_URL.toString()
        : null,
    });
  });

  const { mountPlayerConnectEndpoints } = require("./playerConnectEndpoints");
  mountPlayerConnectEndpoints(app);

  const { mountWebCompanionBridge } = require("./webCompanionBridge");
  mountWebCompanionBridge(app);

  app.all(/.*/, (req, res) => {
    if (PROXY_FORWARD_UPSTREAM_URL) {
      const upstreamTargetUrl = buildForwardTargetUrl(
        PROXY_FORWARD_UPSTREAM_URL,
        req.url,
      );
      pipeHttpRequest(req, res, upstreamTargetUrl);
      return;
    }
    res.status(200).json(makeResponsePayload(req));
  });

  const listenUrl = resolveListenUrl();
  const httpPort = getUrlPort(listenUrl);
  const httpsPort = httpPort + 1;
  const bindHost = resolveBindHost(listenUrl);
  // Public proxy can listen on 0.0.0.0 for remote friends, but the local HTTPS
  // intercept responder is only reached via in-process CONNECT tunnels — keep
  // that loopback so TLS/SNI for public-gateway matches single-player behavior.
  const localInterceptListenHost = resolveLocalInterceptConnectHost(bindHost);
  const localInterceptConnectHost = localInterceptListenHost;

  if (shouldHandleInterceptLocally()) {
    createLocalSecureResponder(httpsPort, localInterceptListenHost);
    createLoopbackCdnResponder(
      httpsPort,
      LOOPBACK_CDN_LISTEN_PORT,
      localInterceptListenHost,
    );
    // Dedicated HTTP/1.1 HTTPS for CONNECT (Diagnose + FRP-friendly).
    ensureConnectMitmHttpsServerAsync().catch((err) => {
      log.http2Err(`[Proxy] CONNECT MITM HTTPS failed to start: ${err.message}`);
    });
  }

  const proxyServer = http.createServer(app);
  // CONNECT tunnels (TLS-over-proxy) must not be killed by Node 18+ request timeouts.
  try {
    proxyServer.timeout = 0;
    proxyServer.requestTimeout = 0;
    proxyServer.headersTimeout = 0;
    proxyServer.keepAliveTimeout = 0;
  } catch {
    // ignore older Node
  }

  proxyServer.on("connect", (req, clientSocket, head) => {
    // CONNECT tunnels must not be killed by request timers on the IncomingMessage.
    try {
      if (typeof req.setTimeout === "function") {
        req.setTimeout(0);
      }
    } catch {
      // ignore
    }
    try {
      clientSocket.setTimeout(0);
    } catch {
      // ignore
    }

    const targetRaw = req.url || "";
    const { host, port } = parseConnectTarget(targetRaw);

    if (!host || !port) {
      clientSocket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
      clientSocket.destroy();
      return;
    }

    if (shouldBlockHost(host)) {
      log.proxy(`CONNECT ${targetRaw} -> BLOCKED local policy`);
      clientSocket.write(
        "HTTP/1.1 403 Forbidden\r\n" +
        "Proxy-Agent: EveJS Elysian\r\n" +
        "X-EveJS-Proxy-Blocked: true\r\n" +
        "\r\n",
      );
      clientSocket.destroy();
      return;
    }

    const interceptTarget = ENABLE_LOCAL_INTERCEPT && shouldInterceptHost(host);
    if (!interceptTarget && shouldDenyUnhandledProxyHost(host, {
      interceptHosts: LOCAL_INTERCEPT_HOSTS,
      allowedHosts: ALLOWED_PROXY_HOSTS,
      policy: PROXY_UNHANDLED_HOST_POLICY,
    })) {
      log.proxy(`CONNECT ${targetRaw} -> BLOCKED unhandled host policy`);
      clientSocket.write(
        "HTTP/1.1 403 Forbidden\r\n" +
        "Proxy-Agent: EveJS Elysian\r\n" +
        "X-EveJS-Proxy-Blocked: true\r\n" +
        "\r\n",
      );
      clientSocket.destroy();
      return;
    }

    // Gateway intercept: prefer in-process TLS wrap (one less hop than MITM).
    // Fall back to loopback MITM HTTPS if wrap cannot start.
    if (interceptTarget && shouldHandleInterceptLocally()) {
      const mode = String(process.env.EVEJS_CONNECT_TLS_MODE || "wrap")
        .trim()
        .toLowerCase();
      if (mode === "mitm") {
        if (attachConnectViaMitmHttpsTunnel(clientSocket, head, targetRaw)) {
          return;
        }
        ensureConnectMitmHttpsServerAsync()
          .then(() => {
            if (!attachConnectViaMitmHttpsTunnel(clientSocket, head, targetRaw)) {
              clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
              clientSocket.destroy();
            }
          })
          .catch(() => {
            try {
              clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
            } catch {
              // ignore
            }
            clientSocket.destroy();
          });
        return;
      }
      // default: wrap
      if (attachConnectTlsWrap(clientSocket, head, targetRaw)) {
        // Warm MITM https server so secureConnection handoff has a listener.
        ensureConnectMitmHttpsServerAsync().catch(() => {});
        return;
      }
      if (attachConnectViaMitmHttpsTunnel(clientSocket, head, targetRaw)) {
        return;
      }
      ensureConnectMitmHttpsServerAsync()
        .then(() => {
          if (!attachConnectViaMitmHttpsTunnel(clientSocket, head, targetRaw)) {
            clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
            clientSocket.destroy();
          }
        })
        .catch(() => {
          try {
            clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
          } catch {
            // ignore
          }
          clientSocket.destroy();
        });
      return;
    }

    let connectHost = host;
    let connectPort = port;
    let modeLabel = "REMOTE";

    if (interceptTarget && shouldForwardInterceptToUpstream()) {
      const upstreamTarget = getGatewayUpstreamTarget(httpsPort);
      if (upstreamTarget) {
        connectHost = upstreamTarget.host;
        connectPort = upstreamTarget.port;
        modeLabel = "UPSTREAM";
      }
    }

    log.proxy(`CONNECT ${targetRaw} -> ${modeLabel} ${connectHost}:${connectPort}`);

    try {
      clientSocket.pause();
    } catch {
      // ignore
    }

    const upstreamSocket = net.connect(
      { port: connectPort, host: connectHost },
      () => {
        const established =
          "HTTP/1.1 200 Connection Established\r\n" +
          "Proxy-Agent: EveJS Elysian\r\n" +
          "\r\n";
        clientSocket.write(established, () => {
          wireTunnel(
            clientSocket,
            upstreamSocket,
            head,
            `${targetRaw} via ${connectHost}:${connectPort}`,
            {
              idleTimeoutMs: interceptTarget
                ? INTERCEPT_PROXY_TUNNEL_IDLE_TIMEOUT_MS
                : DEFAULT_PROXY_TUNNEL_IDLE_TIMEOUT_MS,
            },
          );
          try {
            clientSocket.resume();
          } catch {
            // ignore
          }
        });
      },
    );

    upstreamSocket.on("error", (err) => {
      log.proxyErr(`connect failed ${connectHost}:${connectPort} ${err.message}`);
      if (!clientSocket.destroyed) {
        try {
          clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        } catch {
          // ignore
        }
      }
      clientSocket.destroy();
    });
  });

  proxyServer.on("error", (err) => {
    log.proxyErr(`server error: ${err.message}`);
  });

  proxyServer.listen(httpPort, bindHost, () => {
    log.success(
      `[Proxy] express listening on ${bindHost}:${httpPort} ` +
        `(intercept=${shouldHandleInterceptLocally()})`,
    );
    if (shouldHandleInterceptLocally()) {
      // MITM may still be binding; slight delay then full-path probe.
      setTimeout(() => {
        ensureConnectMitmHttpsServerAsync()
          .then(() => runFullPathConnectTlsSelfTest(httpPort, bindHost))
          .catch((err) => {
            log.http2Err(
              `[Proxy] MITM not ready for full-path self-test: ${err.message}`,
            );
          });
      }, 250);
    }
  });

  log.debug(
    `express proxy mode: ${
      shouldForwardInterceptToUpstream()
        ? "forward intercept enabled"
        : shouldHandleInterceptLocally()
          ? "local intercept enabled"
          : "transparent forward"
    }`,
  );
}

module.exports = {
  enabled: EXPRESS_PROXY_ENABLED,
  serviceName: "expressServer",
  exec() {
    startServer();
    log.debug(`express server is running on ${config.microservicesPublicBaseUrl}`);
  },
};

module.exports.__testHooks = {
  buildLaunchDarklyEvaluationPayload,
  handleLaunchDarklyHttpRequest,
  hostMatchesPattern,
  hostMatchesAnyPattern,
  launchDarklyEventStreamBody,
  parseHostPatternList,
  shouldAllowListedHost,
  shouldHandleLaunchDarklyHost,
  shouldBlockHost,
  shouldDenyUnhandledProxyHost,
  normalizeUnhandledProxyHostPolicy,
  createLoopbackCdnRequestHandler,
  createLoopbackCdnResponder,
  getGatewayBinaryAsset,
  loadLocalTlsOptions,
};
