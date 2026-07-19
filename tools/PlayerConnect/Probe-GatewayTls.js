#!/usr/bin/env node
/**
 * CONNECT + TLS probe for EveJS public-gateway intercept.
 *
 * Usage:
 *   node Probe-GatewayTls.js <proxyHost> <proxyPort>
 *
 * argv[0]=node argv[1]=script argv[2]=host argv[3]=port
 */
"use strict";

const http = require("http");
const tls = require("tls");

const host = process.argv[2];
const port = Number(process.argv[3]);

if (!host || !Number.isFinite(port) || port <= 0) {
  console.error(
    "USAGE node Probe-GatewayTls.js <proxyHost> <proxyPort>",
  );
  console.error(
    `got host=${JSON.stringify(host)} port=${JSON.stringify(process.argv[3])}`,
  );
  process.exit(1);
}

const req = http.request({
  host,
  port,
  method: "CONNECT",
  path: "dev-public-gateway.evetech.net:443",
  headers: { Host: "dev-public-gateway.evetech.net:443" },
  timeout: 12000,
});

req.on("connect", (res, socket, head) => {
  if (res.statusCode !== 200) {
    console.error("CONNECT_STATUS " + res.statusCode);
    process.exit(2);
  }
  if (head && head.length) {
    try {
      socket.unshift(head);
    } catch (_) {
      // ignore
    }
  }
  const s = tls.connect(
    {
      socket,
      servername: "dev-public-gateway.evetech.net",
      rejectUnauthorized: false,
      minVersion: "TLSv1.2",
      maxVersion: "TLSv1.2",
    },
    () => {
      console.log(
        "OK " +
          (s.getProtocol() || "?") +
          " alpn=" +
          (s.alpnProtocol || "none"),
      );
      try {
        const c = s.getPeerCertificate();
        if (c && c.subject) {
          console.log("SUBJECT " + JSON.stringify(c.subject));
        }
        if (c && c.issuer) {
          console.log("ISSUER " + JSON.stringify(c.issuer));
        }
      } catch (_) {
        // ignore
      }
      s.end();
      process.exit(0);
    },
  );
  s.setTimeout(12000, () => {
    console.error("TLS_TIMEOUT");
    s.destroy();
    process.exit(3);
  });
  s.on("error", (e) => {
    console.error("TLS_ERR " + e.message + (e.code ? " code=" + e.code : ""));
    process.exit(4);
  });
});

req.on("timeout", () => {
  console.error("CONNECT_TIMEOUT");
  req.destroy();
  process.exit(5);
});

req.on("error", (e) => {
  console.error("REQ_ERR " + e.message);
  process.exit(6);
});

req.end();
