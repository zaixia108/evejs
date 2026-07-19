#!/usr/bin/env node
/**
 * Apply multiplayer host settings to evejs.config.local.json and emit a
 * PlayerConnect bundle friends can use to join this server.
 *
 * Usage:
 *   node tools/PlayerConnect/configure-multiplayer-host.js --host 192.168.1.10
 *   node tools/PlayerConnect/configure-multiplayer-host.js --host auto
 *   node tools/PlayerConnect/configure-multiplayer-host.js --host auto --token mySecret
 *   node tools/PlayerConnect/configure-multiplayer-host.js --host auto --localhost-only
 */

"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const net = require("net");

const repoRoot = path.resolve(__dirname, "../..");
const localConfigPath = path.join(repoRoot, "evejs.config.local.json");
const caSourcePath = path.join(repoRoot, "server/certs/xmpp-ca-cert.pem");

function parseArgs(argv) {
  const args = {
    host: "auto",
    token: null,
    localhostOnly: false,
    keepDevAuth: false,
    skipBundle: false,
    json: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--host" || token === "-h") {
      args.host = String(argv[++i] || "auto").trim();
    } else if (token === "--token" || token === "-t") {
      args.token = String(argv[++i] || "").trim();
    } else if (token === "--localhost-only") {
      args.localhostOnly = true;
    } else if (token === "--keep-dev-auth") {
      args.keepDevAuth = true;
    } else if (token === "--skip-bundle") {
      args.skipBundle = true;
    } else if (token === "--json") {
      args.json = true;
    } else if (token === "--help") {
      printHelp();
      process.exit(0);
    }
  }

  return args;
}

function printHelp() {
  process.stdout.write(`configure-multiplayer-host.js

Options:
  --host <ip|hostname|auto>   Advertised address for clients (default: auto)
  --token <secret>            PlayerConnect shared token (default: keep or generate)
  --localhost-only            Revert listeners to 127.0.0.1 (disable remote bind)
  --keep-dev-auth             Leave devAutoCreateAccounts / devSkipPasswordValidation alone
  --skip-bundle               Do not write the PlayerConnect bundle folder
  --json                      Print a JSON summary on stdout
  --help                      Show this help
`);
}

function isPrivateIPv4(address) {
  if (!net.isIPv4(address)) {
    return false;
  }
  const parts = address.split(".").map((part) => Number(part));
  if (parts[0] === 10) {
    return true;
  }
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) {
    return true;
  }
  if (parts[0] === 192 && parts[1] === 168) {
    return true;
  }
  return false;
}

function detectLanHost() {
  const interfaces = os.networkInterfaces();
  const candidates = [];

  for (const entries of Object.values(interfaces)) {
    if (!entries) {
      continue;
    }
    for (const entry of entries) {
      if (!entry || entry.internal) {
        continue;
      }
      const family = entry.family;
      if (family !== "IPv4" && family !== 4) {
        continue;
      }
      candidates.push(entry.address);
    }
  }

  const privateFirst = candidates.find(isPrivateIPv4);
  if (privateFirst) {
    return privateFirst;
  }
  if (candidates.length > 0) {
    return candidates[0];
  }
  return "127.0.0.1";
}

function normalizeHost(rawHost, localhostOnly) {
  if (localhostOnly) {
    return "127.0.0.1";
  }
  const host = String(rawHost || "auto").trim();
  if (!host || host.toLowerCase() === "auto") {
    return detectLanHost();
  }
  return host;
}

function stripJsonComments(text) {
  // evejs.config.local.json allows // line comments.
  return String(text || "").replace(/^\s*\/\/.*$/gm, "");
}

function readConfigObject(filePath) {
  if (!fs.existsSync(filePath)) {
    return {};
  }
  const raw = fs.readFileSync(filePath, "utf8");
  try {
    return JSON.parse(stripJsonComments(raw));
  } catch (error) {
    throw new Error(`Could not parse ${filePath}: ${error.message}`);
  }
}

function formatConfigValue(value) {
  if (typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "boolean" || typeof value === "number") {
    return JSON.stringify(value);
  }
  return JSON.stringify(value);
}

// Patch individual top-level keys in-place so we preserve comments and do not
// re-run the full config validator (which currently rejects blank strings that
// are otherwise valid defaults in evejs.config.local.json).
function patchConfigFile(filePath, updates) {
  let text = fs.existsSync(filePath)
    ? fs.readFileSync(filePath, "utf8")
    : "{\n}\n";

  if (!text.trim()) {
    text = "{\n}\n";
  }

  const missingKeys = [];

  for (const [key, value] of Object.entries(updates)) {
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // Match:   "key": <value>,
    const pattern = new RegExp(
      `^([ \\t]*)"${escapedKey}"([ \\t]*:[ \\t]*)([^,\\r\\n]+)(,?)[ \\t]*$`,
      "m",
    );
    const replacementValue = formatConfigValue(value);
    if (pattern.test(text)) {
      text = text.replace(
        pattern,
        (match, indent, colon, _oldValue, trailingComma) => {
          const comma = trailingComma || ",";
          return `${indent}"${key}"${colon}${replacementValue}${comma}`;
        },
      );
    } else {
      missingKeys.push([key, value]);
    }
  }

  if (missingKeys.length > 0) {
    const insertAt = text.lastIndexOf("}");
    if (insertAt < 0) {
      throw new Error(`Config file ${filePath} does not look like a JSON object.`);
    }
    let prefix = text.slice(0, insertAt).replace(/\s*$/, "");
    if (!/\{\s*$/.test(prefix) && !/,\s*$/.test(prefix)) {
      prefix = prefix.replace(
        /("(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?)(\s*)$/,
        "$1,$2",
      );
    }
    const lines = missingKeys.map(([key, value]) => {
      return `  "${key}": ${formatConfigValue(value)},`;
    });
    text = `${prefix}\n${lines.join("\n")}\n}\n`;
  }

  fs.writeFileSync(filePath, text, "utf8");
  readConfigObject(filePath);
}

function ensureToken(existingToken, requestedToken) {
  if (requestedToken) {
    return requestedToken;
  }
  const current = String(existingToken || "").trim();
  if (current) {
    return current;
  }
  return crypto.randomBytes(16).toString("hex");
}

function withTrailingSlash(url) {
  const value = String(url || "").trim();
  if (!value) {
    return value;
  }
  return value.endsWith("/") ? value : `${value}/`;
}

function copyTextFile(source, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function writeTextFile(destination, content) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, content, "utf8");
}

function buildConnectBat() {
  return `@echo off
setlocal EnableDelayedExpansion
title EveJS PlayerConnect
for %%I in ("%~dp0.") do set "BUNDLE_ROOT=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BUNDLE_ROOT%\\Connect.ps1"
set "EXIT_CODE=!errorlevel!"
if not "!EXIT_CODE!"=="0" (
  echo.
  echo   Connect failed with code !EXIT_CODE!.
  pause
)
exit /b !EXIT_CODE!
`;
}

function buildBundleReadme(serverInfo) {
  return `EveJS PlayerConnect Bundle
==========================

Server: ${serverInfo.host}
Game TCP: ${serverInfo.host}:${serverInfo.gamePort}
Proxy:    http://${serverInfo.host}:${serverInfo.proxyPort}/
Images:   http://${serverInfo.host}:${serverInfo.imagePort}/
Chat:     ${serverInfo.host}:${serverInfo.xmppPort}

How friends join
----------------
1. Copy this whole folder to your friend's PC.
2. Friend must have a full EVE 24.01 build 3396210 client copy
   (including ResFiles + index_tranquility.txt). Do NOT use their live TQ install.
3. Double-click Client.bat (or Connect.bat).
4. First run asks for the EVE client folder, installs the CA certificate,
   patches start.ini / blue.dll if needed, then launches the game.
5. Log in with any username/password. The first login creates that account
   when the host left auto-create enabled.

Firewall (host machine)
-----------------------
Open inbound TCP ports:
  ${serverInfo.gamePort}  (game)
  ${serverInfo.imagePort}  (images)
  ${serverInfo.proxyPort}  (proxy / PlayerConnect)
  ${serverInfo.xmppPort}   (chat)

Token is embedded in server.json. Do not post this folder publicly.
`;
}

function writePlayerBundle(serverInfo, caPath) {
  const bundleRoot = path.join(repoRoot, "_local", "player-connect-bundle");
  fs.mkdirSync(bundleRoot, { recursive: true });

  if (caPath && fs.existsSync(caPath)) {
    copyTextFile(caPath, path.join(bundleRoot, "ca.pem"));
  } else {
    // Friends can still download the CA from /playerconnect/ca.pem after the
    // host has started the server once (certs are created on first boot).
    process.stderr.write(
      "[WARN] CA not found yet. Bundle will download ca.pem from the host on first connect.\n",
    );
  }
  writeTextFile(
    path.join(bundleRoot, "server.json"),
    `${JSON.stringify(serverInfo, null, 2)}\n`,
  );
  writeTextFile(path.join(bundleRoot, "Connect.bat"), buildConnectBat());
  writeTextFile(path.join(bundleRoot, "README.txt"), buildBundleReadme(serverInfo));

  const connectPs1Source = path.join(__dirname, "Connect.ps1");
  if (!fs.existsSync(connectPs1Source)) {
    throw new Error(`Missing Connect.ps1 at ${connectPs1Source}`);
  }
  copyTextFile(connectPs1Source, path.join(bundleRoot, "Connect.ps1"));

  // Root-style Client.bat alias so friends only need one obvious button.
  const clientBatSource = path.join(repoRoot, "Client.bat");
  if (fs.existsSync(clientBatSource)) {
    copyTextFile(clientBatSource, path.join(bundleRoot, "Client.bat"));
  } else {
    writeTextFile(path.join(bundleRoot, "Client.bat"), buildConnectBat());
  }

  const patcherFiles = [
    ["blue_dll_patch.ps1", path.join(repoRoot, "tools/ClientSETUP/blue_dll_patch.ps1")],
    ["blue_patch_recipe.json", path.join(repoRoot, "tools/ClientSETUP/blue_patch_recipe.json")],
  ];
  for (const [name, source] of patcherFiles) {
    if (fs.existsSync(source)) {
      copyTextFile(source, path.join(bundleRoot, "tools", name));
    }
  }

  return bundleRoot;
}

function resolveCaPath() {
  if (fs.existsSync(caSourcePath)) {
    return caSourcePath;
  }
  try {
    const modulePaths = module.paths.slice();
    module.paths.unshift(path.join(repoRoot, "server/node_modules"));
    const {
      ensureCertificateAuthority,
    } = require(path.join(
      repoRoot,
      "server/src/_secondary/express/localTlsCertificate",
    ));
    ensureCertificateAuthority();
    module.paths = modulePaths;
  } catch {
    // Server packages may not be installed yet; Connect.ps1 can fetch the CA.
  }
  return fs.existsSync(caSourcePath) ? caSourcePath : null;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const current = readConfigObject(localConfigPath);

  const host = normalizeHost(args.host, args.localhostOnly);
  const bindHost = args.localhostOnly ? "127.0.0.1" : "0.0.0.0";
  const gamePort = Number(current.serverPort || 26000) || 26000;
  const imagePort = 26001;
  const proxyPort = 26002;
  const xmppPort = Number(current.xmppServerPort || 5222) || 5222;
  const token = ensureToken(current.playerConnectToken, args.token);

  const updates = {
    gameServerBindHost: bindHost,
    gameServerHost: args.localhostOnly ? "127.0.0.1" : host,
    imageServerBindHost: bindHost,
    imageServerUrl: args.localhostOnly
      ? "http://127.0.0.1:26001/"
      : withTrailingSlash(`http://${host}:${imagePort}/`),
    microservicesBindHost: bindHost,
    microservicesRedirectUrl: args.localhostOnly
      ? "http://localhost:26002/"
      : withTrailingSlash(`http://${host}:${proxyPort}/`),
    microservicesPublicBaseUrl: args.localhostOnly
      ? "http://127.0.0.1:26002/"
      : withTrailingSlash(`http://${host}:${proxyPort}/`),
    xmppServerBindHost: bindHost,
    xmppConnectHost: args.localhostOnly ? "localhost" : host,
    playerConnectToken: token,
  };

  if (!args.keepDevAuth && !args.localhostOnly) {
    updates.devAutoCreateAccounts = true;
    updates.devSkipPasswordValidation = false;
  }

  if (!fs.existsSync(localConfigPath)) {
    const seed = {
      ...updates,
    };
    writeTextFile(localConfigPath, `${JSON.stringify(seed, null, 2)}\n`);
  } else {
    patchConfigFile(localConfigPath, updates);
  }

  // Rebuild XMPP leaf so domain/FRP advertise hosts are on the cert CN/SAN
  // (stale certs often still say CN=192.168.x.x after switching to a domain).
  try {
    const modulePaths = module.paths.slice();
    module.paths.unshift(path.join(repoRoot, "server/node_modules"));
    const {
      ensureXmppTlsCertificate,
    } = require(path.join(
      repoRoot,
      "server/src/_secondary/express/localTlsCertificate",
    ));
    const xmppCert = path.join(repoRoot, "server/certs/xmpp-dev-cert.pem");
    const xmppKey = path.join(repoRoot, "server/certs/xmpp-dev-key.pem");
    const xmppHost = args.localhostOnly ? "localhost" : host;
    const result = ensureXmppTlsCertificate({
      outCertPath: xmppCert,
      outKeyPath: xmppKey,
      commonName: xmppHost,
      extraHosts: [host, "localhost", "127.0.0.1"],
      force: false,
    });
    module.paths = modulePaths;
    if (result && result.rebuilt) {
      process.stderr.write(
        `[INFO] Rebuilt XMPP TLS certificate for host=${xmppHost}\n`,
      );
    }
  } catch (error) {
    process.stderr.write(
      `[WARN] Could not rebuild XMPP cert (will retry on server start): ${error.message}\n`,
    );
  }

  const advertisedHost = args.localhostOnly ? "127.0.0.1" : host;
  const serverInfo = {
    service: "evejs-playerconnect",
    host: advertisedHost,
    gamePort,
    imagePort,
    proxyPort,
    xmppPort,
    token,
    proxyUrl: withTrailingSlash(`http://${advertisedHost}:${proxyPort}/`),
    imageServerUrl: withTrailingSlash(`http://${advertisedHost}:${imagePort}/`),
    cryptoPack: "Placebo",
    requiredBuild: "3396210",
    generatedAt: new Date().toISOString(),
  };

  let bundleRoot = null;
  if (!args.skipBundle && !args.localhostOnly) {
    const caPath = resolveCaPath();
    bundleRoot = writePlayerBundle(serverInfo, caPath);
  }

  const summary = {
    ok: true,
    mode: args.localhostOnly ? "localhost" : "multiplayer",
    host: advertisedHost,
    bindHost,
    token,
    gamePort,
    imagePort,
    proxyPort,
    xmppPort,
    configPath: localConfigPath,
    bundleRoot,
    auth: {
      devAutoCreateAccounts: Object.prototype.hasOwnProperty.call(
        updates,
        "devAutoCreateAccounts",
      )
        ? updates.devAutoCreateAccounts
        : current.devAutoCreateAccounts,
      devSkipPasswordValidation: Object.prototype.hasOwnProperty.call(
        updates,
        "devSkipPasswordValidation",
      )
        ? updates.devSkipPasswordValidation
        : current.devSkipPasswordValidation,
    },
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
    return;
  }

  process.stdout.write("\n  EveJS multiplayer host configuration applied.\n\n");
  process.stdout.write(`  Mode:        ${summary.mode}\n`);
  process.stdout.write(`  Bind:        ${bindHost}\n`);
  process.stdout.write(`  Advertise:   ${advertisedHost}\n`);
  process.stdout.write(`  Game:        ${advertisedHost}:${gamePort}\n`);
  process.stdout.write(`  Proxy:       http://${advertisedHost}:${proxyPort}/\n`);
  process.stdout.write(`  Images:      http://${advertisedHost}:${imagePort}/\n`);
  process.stdout.write(`  Chat:        ${advertisedHost}:${xmppPort}\n`);
  process.stdout.write(`  Token:       ${token}\n`);
  process.stdout.write(`  Config:      ${localConfigPath}\n`);
  if (bundleRoot) {
    process.stdout.write(`  Bundle:      ${bundleRoot}\n`);
    process.stdout.write(
      "\n  Give friends the player-connect-bundle folder and have them run Connect.bat.\n",
    );
  }
  process.stdout.write(
    "\n  Restart the server for bind/advertise settings to take effect.\n\n",
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(
    `\n[ERROR] ${error && error.message ? error.message : error}\n`,
  );
  process.exit(1);
}
