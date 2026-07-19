#Requires -Version 5.1
<#
  EveJS PlayerConnect Diagnose
  Run on the CLIENT PC to check FRP/DDNS host, CA, XMPP TLS, and gateway tunnel.

  Usage:
    cd 到本脚本所在目录（含 server.json）
    powershell -ExecutionPolicy Bypass -File .\Diagnose.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
# Hide PowerShell progress bars (Test-NetConnection / WebRequest) that cover [FAIL] text.
$ProgressPreference = "SilentlyContinue"

$BundleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ServerJson = Join-Path $BundleRoot "server.json"
$CaPath = Join-Path $BundleRoot "ca.pem"

function Write-Title([string]$t) {
  Write-Host ""
  Write-Host "=== $t ===" -ForegroundColor Cyan
}
function Write-Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Bad([string]$t) {
  # Extra blank lines so FAIL is not scrolled under residual progress UI.
  Write-Host ""
  Write-Host "  [FAIL] $t" -ForegroundColor Red
  Write-Host ""
}
function Write-Info([string]$t) { Write-Host "  $t" -ForegroundColor Gray }

# Bump when Diagnose behavior changes — must appear in console so we know
# the client is not running a stale copy from an old PlayerConnect zip.
$script:DiagnoseVersion = "2026-07-19d-schannel"

# C# AcceptAll is required on Windows PowerShell 5.1. Bare scriptblocks are
# often NOT wired as RemoteCertificateValidationCallback, so SChannel rejects
# the EveJS leaf (server: ▲ClientHello ▼ServerCert + client-close, no TLS-OK).
$script:EveJsAcceptAllCallback = $null
try {
  Add-Type -TypeDefinition @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class EveJsTlsAccept {
  public static readonly RemoteCertificateValidationCallback AcceptAll =
    delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
      return true;
    };
}
"@ -ErrorAction Stop
  $script:EveJsAcceptAllCallback = [EveJsTlsAccept]::AcceptAll
} catch {
  try {
    $script:EveJsAcceptAllCallback = [System.Net.Security.RemoteCertificateValidationCallback] {
      param($sender, $certificate, $chain, $sslPolicyErrors)
      return $true
    }
  } catch {
    $script:EveJsAcceptAllCallback = $null
  }
}

function Get-AcceptAllCertCallback {
  if ($null -eq $script:EveJsAcceptAllCallback) {
    throw "RemoteCertificateValidationCallback not available (Add-Type failed)"
  }
  return $script:EveJsAcceptAllCallback
}

try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12 -bor `
    [Net.SecurityProtocolType]::Tls11 -bor `
    [Net.SecurityProtocolType]::Tls
} catch {
  # ignore
}

if (-not (Test-Path -LiteralPath $ServerJson)) {
  throw "server.json not found next to Diagnose.ps1: $ServerJson"
}

$server = Get-Content -LiteralPath $ServerJson -Raw -Encoding UTF8 | ConvertFrom-Json
$hostName = [string]$server.host
$token = [string]$server.token
$proxyPort = if ($server.proxyPort) { [int]$server.proxyPort } else { 26002 }
$xmppPort = if ($server.xmppPort) { [int]$server.xmppPort } else { 5222 }
$gamePort = if ($server.gamePort) { [int]$server.gamePort } else { 26000 }
$proxyBase = "http://{0}:{1}/" -f $hostName, $proxyPort

Write-Host ""
Write-Host "  EveJS PlayerConnect Diagnose" -ForegroundColor Cyan
Write-Host "  Host: $hostName" -ForegroundColor DarkGray
Write-Host ("  Script version: {0}" -f $script:DiagnoseVersion) -ForegroundColor DarkGray
if ($null -eq $script:EveJsAcceptAllCallback) {
  Write-Bad "TLS cert accept callback failed to load — gateway/XMPP TLS tests will be unreliable"
}

# ── 1) health ───────────────────────────────────────────────────────────────
Write-Title "1) PlayerConnect health"
$health = $null
try {
  $health = Invoke-RestMethod -TimeoutSec 10 -Uri ("{0}playerconnect/health?token={1}" -f $proxyBase, [uri]::EscapeDataString($token))
  Write-Ok ("ok={0} host={1} xmppHost={2} gamePortOpen={3}" -f $health.ok, $health.host, $health.xmppHost, $health.gamePortOpen)
  Write-Info ("caSha256={0}" -f $health.caSha256)
} catch {
  Write-Bad "health failed: $($_.Exception.Message)"
  Write-Info "Check FRP tunnel for TCP $proxyPort and that EveJS is running on the host."
}

# ── 2) CA ───────────────────────────────────────────────────────────────────
Write-Title "2) Download live CA from host"
try {
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 `
    -Uri ("{0}playerconnect/ca.pem?token={1}" -f $proxyBase, [uri]::EscapeDataString($token)) `
    -OutFile $CaPath
  $sha = (Get-FileHash -LiteralPath $CaPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Ok "saved $CaPath"
  Write-Info "sha256=$sha"
  $expected = if ($health -and $health.caSha256) { ([string]$health.caSha256).ToLowerInvariant() } else { "" }
  if ($expected -and ($sha -ne $expected)) {
    Write-Bad "ca.pem sha does not match health.caSha256"
  } elseif ($expected) {
    Write-Ok "ca.pem matches health fingerprint"
  }
} catch {
  Write-Bad "ca.pem download failed: $($_.Exception.Message)"
}

function Get-CaCert([string]$Path) {
  try { return Get-PfxCertificate -FilePath $Path }
  catch {
    $pem = Get-Content -LiteralPath $Path -Raw
    $b64 = ($pem -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "\s", "")
    $bytes = [Convert]::FromBase64String($b64)
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $bytes)
  }
}

$ca = $null
if (Test-Path -LiteralPath $CaPath) {
  $ca = Get-CaCert $CaPath
  Write-Info ("CA Subject={0}" -f $ca.Subject)
  Write-Info ("CA Thumb  ={0}" -f $ca.Thumbprint)
}

# ── 3) TCP ports ────────────────────────────────────────────────────────────
function Test-TcpPort([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000) {
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    if ($client) {
      try { $client.Close() } catch {}
    }
  }
}

Write-Title "3) TCP ports (game / image / proxy / xmpp)"
foreach ($p in @($gamePort, 26001, $proxyPort, $xmppPort)) {
  if (Test-TcpPort -TargetHost $hostName -Port $p) {
    Write-Ok "TCP $p open"
  } else {
    Write-Bad "TCP $p closed or filtered (FRP / firewall?)"
  }
}

# ── 4) Direct XMPP TLS ──────────────────────────────────────────────────────
function Test-DirectTls([string]$TargetHost, [int]$Port, [string]$Sni, $TrustedCa) {
  Write-Title ("4) Direct TLS {0}:{1} SNI={2}" -f $TargetHost, $Port, $Sni)
  $script:remoteCert = $null
  $script:policy = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(5000, $false)) {
      Write-Bad "TCP connect timeout"
      $client.Close()
      return
    }
    $client.EndConnect($iar)
    Write-Ok "TCP connected"

    $callback = Get-AcceptAllCertCallback
    $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
    $tls12 = [System.Security.Authentication.SslProtocols]::Tls12
    $ssl.AuthenticateAsClient($Sni, $null, $tls12, $false)
    Write-Ok ("TLS handshake completed ({0})" -f $ssl.SslProtocol)
    $leaf = $null
    if ($ssl.RemoteCertificate) {
      $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
    }
    if ($leaf) {
      Write-Info ("leaf Subject={0}" -f $leaf.Subject)
      Write-Info ("leaf Issuer ={0}" -f $leaf.Issuer)
      if ($TrustedCa -and $leaf.Issuer -eq $TrustedCa.Subject) {
        Write-Ok "leaf is issued by the EveJS CA from playerconnect/ca.pem"
      } elseif ($TrustedCa) {
        Write-Bad "leaf issuer does NOT match EveJS CA — host certs may be out of sync"
        Write-Info ("expected issuer: {0}" -f $TrustedCa.Subject)
      }
      if ($leaf.Subject -notmatch [regex]::Escape($Sni) -and $Sni -ne "localhost") {
        Write-Info "Note: Subject may use SAN; name mismatch only matters without AcceptAll callback."
      }
    }

    $ssl.Dispose()
    $client.Close()
  } catch {
    Write-Bad "TLS failed: $($_.Exception.Message)"
  }
}

Test-DirectTls -TargetHost $hostName -Port $xmppPort -Sni $hostName -TrustedCa $ca
Test-DirectTls -TargetHost $hostName -Port $xmppPort -Sni "localhost" -TrustedCa $ca

# ── 5) Gateway via HTTP proxy CONNECT ───────────────────────────────────────
function Read-ConnectResponse([System.Net.Sockets.NetworkStream]$Stream) {
  # Read raw bytes until CRLFCRLF — do NOT use StreamReader (it can buffer past
  # the HTTP headers and steal the start of the TLS handshake).
  $prevTimeout = $Stream.ReadTimeout
  try {
    $Stream.ReadTimeout = 10000
  } catch {}
  $ms = New-Object System.IO.MemoryStream
  $prev = [byte[]]@(0, 0, 0, 0)
  try {
    while ($true) {
      $b = $Stream.ReadByte()
      if ($b -lt 0) { break }
      $ms.WriteByte([byte]$b)
      $prev[0] = $prev[1]; $prev[1] = $prev[2]; $prev[2] = $prev[3]; $prev[3] = [byte]$b
      if ($prev[0] -eq 13 -and $prev[1] -eq 10 -and $prev[2] -eq 13 -and $prev[3] -eq 10) {
        break
      }
      if ($ms.Length -gt 8192) { throw "CONNECT response too large / missing header end" }
    }
  } finally {
    try { $Stream.ReadTimeout = $prevTimeout } catch {}
  }
  if ($ms.Length -eq 0) {
    throw "empty CONNECT response (connection closed before proxy replied)"
  }
  return [Text.Encoding]::ASCII.GetString($ms.ToArray())
}

function Test-GatewayTls {
  param(
    [string]$ProxyHost,
    [int]$ProxyPort,
    [string]$ProtocolLabel,
    $SslProtocol
  )
  Write-Info "--- try $ProtocolLabel ---"
  $script:remoteCert = $null
  $script:policy = $null
  $client = $null
  $ssl = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.Connect($ProxyHost, $ProxyPort)
    $stream = $client.GetStream()
    $req = "CONNECT dev-public-gateway.evetech.net:443 HTTP/1.1`r`nHost: dev-public-gateway.evetech.net:443`r`nConnection: keep-alive`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $resp = Read-ConnectResponse $stream
    $statusLine = ($resp -split "`r`n")[0]
    Write-Info "proxy reply: $statusLine"
    if ($statusLine -notmatch "200") {
      Write-Bad "proxy CONNECT failed"
      Write-Info ("raw: {0}" -f ($resp.Substring(0, [Math]::Min(200, $resp.Length)) -replace "`r|`n", " | "))
      return $false
    }
    Write-Ok "proxy CONNECT established (tunnel)"
    $callback = Get-AcceptAllCertCallback
    $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
    if ($null -ne $SslProtocol) {
      $ssl.AuthenticateAsClient("dev-public-gateway.evetech.net", $null, $SslProtocol, $false)
    } else {
      $tls12 = [System.Security.Authentication.SslProtocols]::Tls12
      $ssl.AuthenticateAsClient("dev-public-gateway.evetech.net", $null, $tls12, $false)
    }
    Write-Ok ("Gateway TLS completed ({0})" -f $ssl.SslProtocol)
    if ($ssl.RemoteCertificate) {
      $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
      Write-Info ("leaf Subject={0}" -f $leaf.Subject)
      Write-Info ("leaf Issuer ={0}" -f $leaf.Issuer)
      if ($ca -and $leaf.Issuer -eq $ca.Subject) {
        Write-Ok "gateway leaf is issued by the EveJS CA"
      } elseif ($ca) {
        Write-Bad "gateway leaf issuer does NOT match EveJS CA"
      }
    }
    return $true
  } catch {
    $ex = $_.Exception
    Write-Bad "gateway TLS failed ($ProtocolLabel): $($ex.Message)"
    if ($ex.InnerException) {
      Write-Info ("inner: {0}" -f $ex.InnerException.Message)
    }
    Write-Info "If callback is broken, SChannel resets after ServerHello (server: client-close, no TLS-OK)."
    return $false
  } finally {
    if ($ssl) { try { $ssl.Dispose() } catch {} }
    if ($client) { try { $client.Close() } catch {} }
  }
}

Write-Title ("5) Gateway TLS via proxy {0}:{1} CONNECT dev-public-gateway.evetech.net:443" -f $hostName, $proxyPort)
Write-Info ("Diagnose version: {0}" -f $script:DiagnoseVersion)
$tls12 = [System.Security.Authentication.SslProtocols]::Tls12
$okGw = Test-GatewayTls -ProxyHost $hostName -ProxyPort $proxyPort -ProtocolLabel "TLS1.2 + C# AcceptAll" -SslProtocol $tls12
if (-not $okGw) {
  Start-Sleep -Milliseconds 400
  $okGw = Test-GatewayTls -ProxyHost $hostName -ProxyPort $proxyPort -ProtocolLabel "TLS1.2 retry" -SslProtocol $tls12
}
# Optional second opinion via curl (often Schannel or LibreSSL with -k).
if (-not $okGw) {
  $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
  if ($curl) {
    Write-Info "--- try curl.exe -k via HTTP proxy ---"
    try {
      $proxyUrl = "http://{0}:{1}" -f $hostName, $proxyPort
      $args = @(
        "-sS", "-k", "--connect-timeout", "8", "--max-time", "20",
        "-x", $proxyUrl,
        "-o", "NUL",
        "-w", "%{http_code}",
        "https://dev-public-gateway.evetech.net/"
      )
      $code = & curl.exe @args 2>&1
      $codeStr = "$code".Trim()
      Write-Info ("curl http_code={0}" -f $codeStr)
      if ($codeStr -match '^[23]\d\d$') {
        Write-Ok "curl gateway via proxy succeeded (TLS path OK; SslStream may still be picky)"
        $okGw = $true
      } else {
        Write-Bad "curl gateway via proxy failed"
      }
    } catch {
      Write-Bad ("curl test error: {0}" -f $_.Exception.Message)
    }
  }
}
if (-not $okGw) {
  Write-Info "CONNECT 200 + TLS reset often means:"
  Write-Info "  1) Client Diagnose.ps1 is STALE. Console must show:"
  Write-Info "       Script version: 2026-07-19d-schannel"
  Write-Info "       --- try TLS1.2 + C# AcceptAll ---"
  Write-Info "  2) Server log while step 5 runs must show:"
  Write-Info "       PRX CONNECT ... -> LOCAL-MITM-HTTPS"
  Write-Info "       [Proxy] CONNECT TLS-OK ...   (handshake completed)"
  Write-Info "     BAD: tunnel closed ▲xxxB ▼yyyB (client-close) WITHOUT TLS-OK"
  Write-Info "  3) Server startup should show:"
  Write-Info "       full-path CONNECT+TLS self-test OK"
  Write-Info "  4) Sync server.js + localTlsCertificate.js, full restart."
  Write-Info "  5) GET /health => localIntercept=true, connectMitmHttps=true"
  Write-Info "In-game paid UI also needs CA in client cacert.pem (Client launcher)."
}

# ── 6) How to read server logs ──────────────────────────────────────────────
Write-Title "6) How to read host server logs"
Write-Host @"
  On the SERVER window, while Diagnose runs step 5:

    GOOD (current code):
      [Proxy] CONNECT MITM HTTPS ready on 127.0.0.1:... (HTTP/1.1, path=LOCAL-MITM-HTTPS)
      PRX  CONNECT ... -> LOCAL-MITM-HTTPS 127.0.0.1:...

    BAD (old in-process TLS wrap — ECONNRESET under FRP):
      PRX  CONNECT ... -> LOCAL-INPROCESS-TLS
      H2   inprocess TLSSocket error: read ECONNRESET

    BAD (older loopback pipe only):
      PRX  CONNECT ... -> LOCAL 127.0.0.1:26003

    BAD intercept off:
      PRX  CONNECT ... -> REMOTE dev-public-gateway.evetech.net:443

  Deploy the latest server.js into the folder that actually runs EveJS
  (e.g. C:\server\GorkServer\EveJS-v0.12.2-GUI), then fully restart.

  health / ca.pem only prove HTTP :$proxyPort.
  Chat needs TLS :$xmppPort. Gateway needs CONNECT + LOCAL-MITM-HTTPS.
"@ -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Done. Press Enter to close."
[void][Console]::ReadLine()
