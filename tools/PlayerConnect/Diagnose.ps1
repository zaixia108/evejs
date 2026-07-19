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

    $callback = {
      param($sender, $certificate, $chain, $sslPolicyErrors)
      $script:remoteCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
      $script:policy = $sslPolicyErrors
      return $true
    }
    $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
    $ssl.AuthenticateAsClient($Sni)
    Write-Ok ("TLS handshake completed ({0})" -f $ssl.SslProtocol)
    Write-Info ("leaf Subject={0}" -f $script:remoteCert.Subject)
    Write-Info ("leaf Issuer ={0}" -f $script:remoteCert.Issuer)
    Write-Info ("SslPolicyErrors={0}" -f $script:policy)

    if ($TrustedCa -and $script:remoteCert.Issuer -eq $TrustedCa.Subject) {
      Write-Ok "leaf is issued by the EveJS CA from playerconnect/ca.pem"
    } elseif ($TrustedCa) {
      Write-Bad "leaf issuer does NOT match EveJS CA — host certs may be out of sync"
      Write-Info ("expected issuer: {0}" -f $TrustedCa.Subject)
    }

    $pol = "$($script:policy)"
    if ($pol -match "RemoteCertificateNameMismatch") {
      Write-Bad "Certificate name mismatch: cert CN/SAN does not include '$Sni'"
      Write-Info "On SERVER: set gameServerHost/xmppConnectHost to your domain,"
      Write-Info "  delete server\certs\xmpp-dev-cert.pem and xmpp-dev-key.pem,"
      Write-Info "  re-run Server launcher configure, restart EveJS."
      Write-Info "  Expect leaf Subject=CN=$Sni and SslPolicyErrors=None."
    } elseif ($pol -ne "None" -and $pol -ne "") {
      Write-Bad "Windows trust errors: $pol (install CA into Root + client cacert.pem)"
    }

    $ssl.Dispose()
    $client.Close()
  } catch {
    Write-Bad "TLS failed: $($_.Exception.Message)"
    if ($script:remoteCert) {
      Write-Info ("leaf Subject={0}" -f $script:remoteCert.Subject)
      Write-Info ("leaf Issuer ={0}" -f $script:remoteCert.Issuer)
    }
  }
}

Test-DirectTls -TargetHost $hostName -Port $xmppPort -Sni $hostName -TrustedCa $ca
Test-DirectTls -TargetHost $hostName -Port $xmppPort -Sni "localhost" -TrustedCa $ca

# ── 5) Gateway via HTTP proxy CONNECT ───────────────────────────────────────
function Read-ConnectResponse([System.Net.Sockets.NetworkStream]$Stream) {
  # Read raw bytes until CRLFCRLF — do NOT use StreamReader (it can buffer past
  # the HTTP headers and steal the start of the TLS handshake).
  $ms = New-Object System.IO.MemoryStream
  $prev = [byte[]]@(0, 0, 0, 0)
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
    $req = "CONNECT dev-public-gateway.evetech.net:443 HTTP/1.1`r`nHost: dev-public-gateway.evetech.net:443`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $resp = Read-ConnectResponse $stream
    $statusLine = ($resp -split "`r`n")[0]
    Write-Info "proxy reply: $statusLine"
    if ($statusLine -notmatch "200") {
      Write-Bad "proxy CONNECT failed"
      return $false
    }
    Write-Ok "proxy CONNECT established (tunnel)"
    $callback = {
      param($sender, $certificate, $chain, $sslPolicyErrors)
      $script:remoteCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
      $script:policy = $sslPolicyErrors
      return $true
    }
    $ssl = New-Object System.Net.Security.SslStream($stream, $false, $callback)
    if ($null -ne $SslProtocol) {
      $ssl.AuthenticateAsClient("dev-public-gateway.evetech.net", $null, $SslProtocol, $false)
    } else {
      $ssl.AuthenticateAsClient("dev-public-gateway.evetech.net")
    }
    Write-Ok ("Gateway TLS completed ({0})" -f $ssl.SslProtocol)
    Write-Info ("leaf Subject={0}" -f $script:remoteCert.Subject)
    Write-Info ("leaf Issuer ={0}" -f $script:remoteCert.Issuer)
    Write-Info ("SslPolicyErrors={0}" -f $script:policy)
    if ($ca -and $script:remoteCert.Issuer -eq $ca.Subject) {
      Write-Ok "gateway leaf is issued by the EveJS CA"
    } elseif ($ca) {
      Write-Bad "gateway leaf issuer does NOT match EveJS CA"
    }
    return $true
  } catch {
    Write-Bad "gateway TLS failed ($ProtocolLabel): $($_.Exception.Message)"
    if ($script:remoteCert) {
      Write-Info ("leaf Subject={0} Issuer={1}" -f $script:remoteCert.Subject, $script:remoteCert.Issuer)
    }
    return $false
  } finally {
    if ($ssl) { try { $ssl.Dispose() } catch {} }
    if ($client) { try { $client.Close() } catch {} }
  }
}

Write-Title ("5) Gateway TLS via proxy {0}:{1} CONNECT dev-public-gateway.evetech.net:443" -f $hostName, $proxyPort)
$tls12 = [System.Security.Authentication.SslProtocols]::Tls12
$okGw = Test-GatewayTls -ProxyHost $hostName -ProxyPort $proxyPort -ProtocolLabel "default SslProtocols" -SslProtocol $null
if (-not $okGw) {
  $okGw = Test-GatewayTls -ProxyHost $hostName -ProxyPort $proxyPort -ProtocolLabel "TLS1.2 only" -SslProtocol $tls12
}
if (-not $okGw) {
  Write-Info "CONNECT 200 + TLS reset often means:"
  Write-Info "  1) Server still on OLD path. Log must show:"
  Write-Info "       PRX CONNECT ... -> LOCAL-MITM-HTTPS 127.0.0.1:<port>"
  Write-Info "     Startup should also show: CONNECT MITM HTTPS ready ..."
  Write-Info "  2) BAD (broken old path):"
  Write-Info "       PRX CONNECT ... -> LOCAL-INPROCESS-TLS"
  Write-Info "       H2  inprocess TLSSocket error: read ECONNRESET"
  Write-Info "  3) BAD (even older): -> LOCAL 127.0.0.1:26003 then hang up"
  Write-Info "  4) Update the folder that actually runs the server, full restart."
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
