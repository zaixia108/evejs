#Requires -Version 5.1
<#
.SYNOPSIS
  One-click EveJS PlayerConnect client launcher for friends.

.DESCRIPTION
  Reads server.json + ca.pem from the same folder, prepares a local EVE client
  copy (start.ini, certificates, optional blue.dll patch), then launches the
  client pointed at the remote EveJS host.
#>
[CmdletBinding()]
param(
  [string]$ClientPath,
  [switch]$SkipLaunch,
  [switch]$ForceSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BundleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ServerJsonPath = Join-Path $BundleRoot "server.json"
$CaPemPath = Join-Path $BundleRoot "ca.pem"
$LocalStatePath = Join-Path $BundleRoot "player-local.json"
$RequiredBuild = "3396210"

function Write-Banner {
  Write-Host ""
  Write-Host "  ============================================================" -ForegroundColor Cyan
  Write-Host "    EveJS PlayerConnect" -ForegroundColor Cyan
  Write-Host "  ============================================================" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step([string]$Message) {
  Write-Host "  $Message" -ForegroundColor Gray
}

function Write-Ok([string]$Message) {
  Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
  Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Err([string]$Message) {
  Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

# StrictMode throws when reading a missing NoteProperty. Always use this helper.
function Get-Prop {
  param(
    $Object,
    [string]$Name,
    $Default = $null
  )
  if ($null -eq $Object) {
    return $Default
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    return $Default
  }
  $value = $prop.Value
  if ($null -eq $value) {
    return $Default
  }
  return $value
}

function Set-Prop {
  param(
    $Object,
    [string]$Name,
    $Value
  )
  if ($null -eq $Object) {
    return
  }
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Read-ServerInfo {
  if (-not (Test-Path -LiteralPath $ServerJsonPath)) {
    throw "server.json not found next to Connect.ps1: $ServerJsonPath"
  }
  $raw = Get-Content -LiteralPath $ServerJsonPath -Raw -Encoding UTF8
  $info = $raw | ConvertFrom-Json

  $hostName = [string](Get-Prop $info "host" "")
  $token = [string](Get-Prop $info "token" "")
  if (-not $hostName) {
    throw "server.json is missing required field 'host'."
  }
  if (-not $token) {
    throw "server.json is missing required field 'token'."
  }

  $gamePort = Get-Prop $info "gamePort" 26000
  $proxyPort = Get-Prop $info "proxyPort" 26002
  $imagePort = Get-Prop $info "imagePort" 26001
  $xmppPort = Get-Prop $info "xmppPort" 5222
  $proxyUrl = [string](Get-Prop $info "proxyUrl" "")
  $cryptoPack = [string](Get-Prop $info "cryptoPack" "Placebo")
  $requiredBuild = [string](Get-Prop $info "requiredBuild" "")

  if (-not $gamePort) { $gamePort = 26000 }
  if (-not $proxyPort) { $proxyPort = 26002 }
  if (-not $imagePort) { $imagePort = 26001 }
  if (-not $xmppPort) { $xmppPort = 5222 }
  if (-not $proxyUrl) {
    $proxyUrl = "http://{0}:{1}/" -f $hostName, $proxyPort
  }
  if (-not $cryptoPack) { $cryptoPack = "Placebo" }
  if ($requiredBuild) {
    $script:RequiredBuild = $requiredBuild
  }

  return [pscustomobject]@{
    host = $hostName
    token = $token
    gamePort = [int]$gamePort
    proxyPort = [int]$proxyPort
    imagePort = [int]$imagePort
    xmppPort = [int]$xmppPort
    proxyUrl = $proxyUrl
    cryptoPack = $cryptoPack
    requiredBuild = $script:RequiredBuild
  }
}

function Read-LocalState {
  # Always return a fully-shaped object so StrictMode never trips on missing props.
  $state = [pscustomobject]@{
    clientPath = ""
    lastHost = ""
    preparedAt = ""
  }
  if (-not (Test-Path -LiteralPath $LocalStatePath)) {
    return $state
  }
  try {
    $raw = Get-Content -LiteralPath $LocalStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Set-Prop $state "clientPath" ([string](Get-Prop $raw "clientPath" ""))
    Set-Prop $state "lastHost" ([string](Get-Prop $raw "lastHost" ""))
    Set-Prop $state "preparedAt" ([string](Get-Prop $raw "preparedAt" ""))
  } catch {
    # keep defaults
  }
  return $state
}

function Save-LocalState($State) {
  ($State | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $LocalStatePath -Encoding UTF8
}

function Resolve-ClientPath([string]$Preferred, $State) {
  $candidates = @()
  if ($Preferred) { $candidates += $Preferred }
  if ($env:EVEJS_CLIENT_PATH) { $candidates += $env:EVEJS_CLIENT_PATH }
  $savedClient = [string](Get-Prop $State "clientPath" "")
  if ($savedClient) { $candidates += $savedClient }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  Write-Host "  First-time setup: select your EVE client folder (the tq folder)." -ForegroundColor Yellow
  Write-Host "  Example: D:\Games\EVE-Copy\EVE\tq" -ForegroundColor DarkGray
  Write-Host "  Required build: $RequiredBuild" -ForegroundColor DarkGray
  Write-Host ""

  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = "Select your copied EVE client tq folder (build $RequiredBuild)"
  $dialog.ShowNewFolderButton = $false
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    throw "No client folder selected."
  }
  $selected = $dialog.SelectedPath
  if (-not (Test-Path -LiteralPath (Join-Path $selected "bin64\exefile.exe"))) {
    if (-not (Test-Path -LiteralPath (Join-Path $selected "bin\exefile.exe"))) {
      throw "exefile.exe was not found under $selected\bin64 or bin. Select the tq folder."
    }
  }
  return (Resolve-Path -LiteralPath $selected).Path
}

function Get-ClientExe([string]$TqPath) {
  $bin64 = Join-Path $TqPath "bin64\exefile.exe"
  if (Test-Path -LiteralPath $bin64) { return $bin64 }
  $bin = Join-Path $TqPath "bin\exefile.exe"
  if (Test-Path -LiteralPath $bin) { return $bin }
  throw "Could not find exefile.exe under $TqPath"
}

function Get-StartIniPath([string]$TqPath) {
  return (Join-Path $TqPath "start.ini")
}

function Read-IniValue([string]$IniPath, [string[]]$Keys) {
  if (-not (Test-Path -LiteralPath $IniPath)) { return $null }
  foreach ($line in Get-Content -LiteralPath $IniPath) {
    foreach ($key in $Keys) {
      if ($line -match ("^\s*{0}\s*=\s*(.+?)\s*$" -f [regex]::Escape($key))) {
        return $Matches[1].Trim()
      }
    }
  }
  return $null
}

function Set-StartIni {
  param(
    [string]$IniPath,
    [string]$ServerHost,
    [string]$CryptoPack
  )

  if (-not (Test-Path -LiteralPath $IniPath)) {
    throw "start.ini not found: $IniPath"
  }

  $backup = "$IniPath.playerconnect.bak"
  if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $IniPath -Destination $backup -Force
  }

  $lines = Get-Content -LiteralPath $IniPath
  $serverKeys = @("server", "serverip")
  $cryptoKeys = @("cryptoPack", "cryptopack")
  $sawServer = $false
  $sawCrypto = $false
  $updated = New-Object System.Collections.Generic.List[string]

  foreach ($line in $lines) {
    $replaced = $false
    foreach ($key in $serverKeys) {
      if ($line -match ("^\s*{0}\s*=" -f [regex]::Escape($key))) {
        if (-not $sawServer) {
          $updated.Add("server = $ServerHost")
          $sawServer = $true
        }
        $replaced = $true
        break
      }
    }
    if ($replaced) { continue }

    foreach ($key in $cryptoKeys) {
      if ($line -match ("^\s*{0}\s*=" -f [regex]::Escape($key))) {
        if (-not $sawCrypto) {
          $updated.Add("cryptoPack = $CryptoPack")
          $sawCrypto = $true
        }
        $replaced = $true
        break
      }
    }
    if ($replaced) { continue }
    $updated.Add($line)
  }

  if (-not $sawServer) { $updated.Add("server = $ServerHost") }
  if (-not $sawCrypto) { $updated.Add("cryptoPack = $CryptoPack") }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($IniPath, $updated.ToArray(), $encoding)
}

function Get-FileSha256Hex([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ProxyBase([string]$ProxyUrl) {
  $proxyBase = [string]$ProxyUrl
  if (-not $proxyBase.EndsWith("/")) { $proxyBase += "/" }
  return $proxyBase
}

function Read-CaCertificate([string]$PemPath) {
  try {
    return Get-PfxCertificate -FilePath $PemPath
  } catch {
    $pemText = Get-Content -LiteralPath $PemPath -Raw
    $base64 = ($pemText -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "\s", "")
    $bytes = [Convert]::FromBase64String($base64)
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $bytes)
  }
}

function Ensure-LocalCaFile {
  param($ServerInfo, [string]$PemPath)

  # ALWAYS refresh from the live host. A stale ca.pem from an old host / old
  # server cert rotation will make XMPP + public-gateway TLS fail with
  # "socket hang up" while game TCP still works.
  $proxyBase = Get-ProxyBase ([string]$ServerInfo.proxyUrl)
  $tokenQ = [uri]::EscapeDataString([string]$ServerInfo.token)
  $healthUri = "{0}playerconnect/health?token={1}" -f $proxyBase, $tokenQ
  $caUri = "{0}playerconnect/ca.pem?token={1}" -f $proxyBase, $tokenQ

  $expectedSha = ""
  try {
    $health = Invoke-RestMethod -TimeoutSec 8 -Uri $healthUri
    if ($health -and $health.caSha256) {
      $expectedSha = ([string]$health.caSha256).ToLowerInvariant()
    }
  } catch {
    Write-Warn "Could not read playerconnect health for CA fingerprint: $($_.Exception.Message)"
  }

  $localSha = Get-FileSha256Hex $PemPath
  $needsDownload = $true
  if ($localSha -and $expectedSha -and ($localSha -eq $expectedSha)) {
    $needsDownload = $false
    Write-Ok "ca.pem matches host fingerprint ($($localSha.Substring(0,12))...)"
  }

  if ($needsDownload) {
    Write-Step "Downloading live ca.pem from host ($($ServerInfo.host))..."
    try {
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $caUri -OutFile $PemPath
    } catch {
      if (Test-Path -LiteralPath $PemPath -PathType Leaf) {
        Write-Warn "Live CA download failed; keeping existing ca.pem. $($_.Exception.Message)"
      } else {
        throw "Could not download ca.pem from $caUri. Is the host running Server.bat? $_"
      }
    }
    $localSha = Get-FileSha256Hex $PemPath
    if ($expectedSha -and $localSha -and ($localSha -ne $expectedSha)) {
      Write-Warn "Downloaded ca.pem sha256 $localSha != health $expectedSha"
    } else {
      Write-Ok "Downloaded ca.pem from host ($($localSha.Substring(0,[Math]::Min(12,$localSha.Length)))...)"
    }
  }

  if (-not (Test-Path -LiteralPath $PemPath -PathType Leaf)) {
    throw "ca.pem still missing at $PemPath"
  }
  return $PemPath
}

function Remove-StaleEveJsRootCerts {
  param([string]$CurrentThumbprint)

  $removed = 0
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
  )
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  try {
    $stale = @($store.Certificates | Where-Object {
      (
        $_.Subject -like "*EvEJS Local*" -or
        $_.Issuer -like "*EvEJS Local*" -or
        $_.Subject -like "*eve.js Public Gateway*" -or
        $_.Issuer -like "*eve.js Public Gateway*"
      ) -and (
        -not $CurrentThumbprint -or $_.Thumbprint -ne $CurrentThumbprint
      )
    })
    foreach ($item in $stale) {
      try {
        $store.Remove($item)
        $removed += 1
      } catch {
        # ignore individual remove failures
      }
    }
  } finally {
    $store.Close()
  }
  if ($removed -gt 0) {
    Write-Ok "Removed $removed stale EveJS certificate(s) from CurrentUser\Root"
  }
}

function Remove-OldEveJsBlocksFromPem {
  param(
    [string]$Content,
    [string]$CurrentThumbprint
  )

  if (-not $Content) { return "" }
  $regex = New-Object System.Text.RegularExpressions.Regex(
    "-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----",
    [System.Text.RegularExpressions.RegexOptions]::Multiline
  )

  $updated = $regex.Replace(
    $Content,
    [System.Text.RegularExpressions.MatchEvaluator]{
      param($match)
      try {
        $base64 = ($match.Value -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "\s", "")
        $bytes = [Convert]::FromBase64String($base64)
        $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $bytes)
        $subject = [string]$c.Subject
        $issuer = [string]$c.Issuer
        $isEveJs = (
          $subject -like "*EvEJS Local*" -or
          $issuer -like "*EvEJS Local*" -or
          $subject -like "*eve.js Public Gateway*" -or
          $issuer -like "*eve.js Public Gateway*"
        )
        if ($isEveJs -and $CurrentThumbprint -and $c.Thumbprint -eq $CurrentThumbprint) {
          return $match.Value
        }
        if ($isEveJs) {
          return ""
        }
      } catch {
        return $match.Value
      }
      return $match.Value
    }
  )
  return ($updated.TrimEnd() + "`r`n")
}

function Install-CaTrust {
  param([string]$PemPath, [string]$TqPath)

  if (-not (Test-Path -LiteralPath $PemPath)) {
    throw "ca.pem not found: $PemPath"
  }

  $cert = Read-CaCertificate -PemPath $PemPath
  $thumb = [string]$cert.Thumbprint
  Write-Step ("EveJS CA thumbprint: {0}" -f $thumb)

  Remove-StaleEveJsRootCerts -CurrentThumbprint $thumb

  # CurrentUser Root trust for OS / SChannel TLS (and some client paths).
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
  )
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  try {
    $exists = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumb }
    if (-not $exists) {
      $store.Add($cert) | Out-Null
      Write-Ok "Installed EveJS CA into CurrentUser\Root"
    } else {
      Write-Ok "EveJS CA already trusted in CurrentUser\Root"
    }
  } finally {
    $store.Close()
  }

  # Inject into every certifi / cacert.pem the client may load. Chat XMPP TLS
  # uses these bundles; public-gateway may use them or SSL_CERT_FILE.
  $caRaw = (Get-Content -LiteralPath $PemPath -Raw).Trim()
  $bundlePaths = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(
      (Join-Path $TqPath "bin64\cacert.pem"),
      (Join-Path $TqPath "bin64\packages\certifi\cacert.pem"),
      (Join-Path $TqPath "bin\cacert.pem"),
      (Join-Path $TqPath "bin\packages\certifi\cacert.pem")
    )) {
    if (Test-Path -LiteralPath $p -PathType Leaf) { $bundlePaths.Add($p) | Out-Null }
  }
  # Also scan beside tq (shared-cache root) — some installs keep packages there.
  $scanRoots = @($TqPath)
  try {
    $parent = (Resolve-Path -LiteralPath (Join-Path $TqPath "..")).Path
    $scanRoots += $parent
  } catch {}
  foreach ($root in $scanRoots) {
    try {
      Get-ChildItem -LiteralPath $root -Recurse -Filter "cacert.pem" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
          if (-not $bundlePaths.Contains($_.FullName)) { $bundlePaths.Add($_.FullName) | Out-Null }
        }
    } catch {}
  }

  if ($bundlePaths.Count -eq 0) {
    Write-Warn "No cacert.pem found under client. XMPP/chat TLS will likely fail."
    Write-Warn "Expected e.g. $TqPath\bin64\cacert.pem or bin64\packages\certifi\cacert.pem"
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)
  $updatedCount = 0
  $primaryBundle = $null
  foreach ($bundlePath in $bundlePaths) {
    try {
      $bundleRaw = Get-Content -LiteralPath $bundlePath -Raw
      $cleaned = Remove-OldEveJsBlocksFromPem -Content $bundleRaw -CurrentThumbprint $thumb
      if (-not $primaryBundle) { $primaryBundle = $bundlePath }
      if ($cleaned.Contains($caRaw)) {
        [System.IO.File]::WriteAllText($bundlePath, $cleaned, $encoding)
        Write-Step "CA already present in $bundlePath"
        $updatedCount += 1
        continue
      }
      $updated = $cleaned.TrimEnd() + "`r`n`r`n" + $caRaw + "`r`n"
      [System.IO.File]::WriteAllText($bundlePath, $updated, $encoding)
      Write-Ok "Installed EveJS CA into $bundlePath"
      $updatedCount += 1
    } catch {
      Write-Warn "Could not update $bundlePath : $($_.Exception.Message)"
    }
  }

  # Build a combined trust file for SSL_CERT_FILE / REQUESTS_CA_BUNDLE:
  # public CAs (from client cacert) + EveJS CA. Using ONLY EveJS CA can make
  # some Python SSL builds behave oddly; combined matches a normal ClientSETUP.
  $combinedPath = Join-Path $BundleRoot "combined-ca-bundle.pem"
  try {
    if ($primaryBundle -and (Test-Path -LiteralPath $primaryBundle)) {
      $combined = Get-Content -LiteralPath $primaryBundle -Raw
    } else {
      $combined = ""
    }
    $combined = Remove-OldEveJsBlocksFromPem -Content $combined -CurrentThumbprint $thumb
    if (-not $combined.Contains($caRaw)) {
      $combined = $combined.TrimEnd() + "`r`n`r`n" + $caRaw + "`r`n"
    }
    [System.IO.File]::WriteAllText($combinedPath, $combined, $encoding)
    Write-Ok "Wrote combined CA bundle: $combinedPath"
  } catch {
    $combinedPath = $PemPath
    Write-Warn "Could not build combined CA bundle; falling back to EveJS CA only."
  }

  Write-Step ("cacert.pem files updated/verified: {0}" -f $updatedCount)
  return [pscustomobject]@{
    CombinedCaPath = $combinedPath
    UpdatedCount = $updatedCount
    Thumbprint = $thumb
  }
}

function Ensure-BlueDllPatched([string]$TqPath) {
  $blueDll = Join-Path $TqPath "bin64\blue.dll"
  if (-not (Test-Path -LiteralPath $blueDll)) {
    Write-Warn "blue.dll not found at $blueDll — skip auto patch."
    return
  }

  $patcher = Join-Path $BundleRoot "tools\blue_dll_patch.ps1"
  if (-not (Test-Path -LiteralPath $patcher)) {
    Write-Warn "blue_dll_patch.ps1 not in this bundle. Patch blue.dll with EveJS ClientSETUP if login fails."
    return
  }

  $statusOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $patcher --status --input $blueDll 2>&1 | Out-String
  if ($statusOut -match "state=already_patched") {
    Write-Ok "blue.dll already patched"
    return
  }
  if ($statusOut -match "state=patchable_original") {
    Write-Step "Patching blue.dll for EveJS..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patcher --input $blueDll --in-place | Out-Null
    Write-Ok "blue.dll patched"
    return
  }
  Write-Warn "Could not auto-patch blue.dll. Status output:`n$statusOut"
}

function Test-ServerHealth($ServerInfo) {
  $proxyBase = [string]$ServerInfo.proxyUrl
  if (-not $proxyBase.EndsWith("/")) { $proxyBase += "/" }
  $healthUri = "{0}playerconnect/health?token={1}" -f $proxyBase, [uri]::EscapeDataString([string]$ServerInfo.token)

  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri $healthUri
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
      $body = $response.Content | ConvertFrom-Json
      if ($body.ok) {
        return $true
      }
    }
  } catch {
    return $false
  }
  return $false
}

function Test-GamePort($ServerInfo) {
  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    $iar = $client.BeginConnect([string]$ServerInfo.host, [int]$ServerInfo.gamePort, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
    if (-not $ok) {
      $client.Close()
      return $false
    }
    $client.EndConnect($iar)
    $client.Close()
    return $true
  } catch {
    return $false
  }
}

function Resolve-ResourceCache([string]$TqPath) {
  $cacheRoot = (Resolve-Path -LiteralPath (Join-Path $TqPath "..")).Path
  $resFiles = Join-Path $cacheRoot "ResFiles"
  $index = Join-Path $cacheRoot "index_tranquility.txt"
  if (-not (Test-Path -LiteralPath $resFiles -PathType Container)) {
    throw "ResFiles missing next to tq: $resFiles`nCopy the full EVE shared cache, not only the tq folder."
  }
  if (-not (Test-Path -LiteralPath $index -PathType Leaf)) {
    throw "index_tranquility.txt missing: $index"
  }
  return [pscustomobject]@{
    CacheRoot = $cacheRoot
    ResFiles = $resFiles
    Index = $index
  }
}

function Apply-NetworkPolicy([string]$ProxyUrl, [string]$ServerHost, [string]$CaPath) {
  $env:http_proxy = $ProxyUrl
  $env:https_proxy = $ProxyUrl
  $env:HTTP_PROXY = $ProxyUrl
  $env:HTTPS_PROXY = $ProxyUrl
  $env:all_proxy = $ProxyUrl
  $env:ALL_PROXY = $ProxyUrl

  # Direct (non-proxy) paths: game TCP, XMPP chat TLS, image HTTP.
  # CCP public-gateway / LaunchDarkly still go through the host proxy so the
  # EveJS intercept can answer them with the local gateway cert.
  $noProxy = "127.0.0.1,localhost,::1,$ServerHost"
  $env:no_proxy = $noProxy
  $env:NO_PROXY = $noProxy
  $env:EVEJS_NO_PROXY = $noProxy

  $env:EVE_CLIENT_SENTRY_DSN = ""
  $env:LD_OFFLINE = "true"
  $env:LAUNCHDARKLY_OFFLINE = "true"
  $env:LAUNCHDARKLY_SEND_EVENTS = "false"
  $env:LD_SEND_EVENTS = "false"

  if ($CaPath -and (Test-Path -LiteralPath $CaPath)) {
    # Prefer combined bundle (public CAs + EveJS CA). EVE's Python stack reads
    # SSL_CERT_FILE / REQUESTS_CA_BUNDLE for XMPP and some HTTPS paths.
    $env:SSL_CERT_FILE = $CaPath
    $env:REQUESTS_CA_BUNDLE = $CaPath
    $env:CURL_CA_BUNDLE = $CaPath
    $env:NODE_EXTRA_CA_CERTS = $CaPath
    Write-Step ("TLS trust bundle: {0}" -f $CaPath)
  }
  $env:SSL_CERT_DIR = ""
}

# ── main ────────────────────────────────────────────────────────────────────
Write-Banner

$server = Read-ServerInfo
$state = Read-LocalState
$tqPath = Resolve-ClientPath -Preferred $ClientPath -State $state
$clientExe = Get-ClientExe -TqPath $tqPath
$startIni = Get-StartIniPath -TqPath $tqPath
$resources = Resolve-ResourceCache -TqPath $tqPath

Write-Step ("Server:  {0}:{1}" -f $server.host, $server.gamePort)
Write-Step ("Proxy:   {0}" -f $server.proxyUrl)
Write-Step ("Client:  {0}" -f $clientExe)
Write-Step ("ResFiles:{0}" -f $resources.ResFiles)
Write-Host ""

$build = Read-IniValue -IniPath $startIni -Keys @("build")
if ($build -and ($build -ne $RequiredBuild)) {
  Write-Warn "Client build is '$build' (expected $RequiredBuild). Login may fail."
}

$needsSetup = $ForceSetup.IsPresent
$currentServer = Read-IniValue -IniPath $startIni -Keys @("server", "serverip")
$currentCrypto = Read-IniValue -IniPath $startIni -Keys @("cryptoPack", "cryptopack")
if ($currentServer -ne [string]$server.host -or $currentCrypto -ne [string]$server.cryptoPack) {
  $needsSetup = $true
}
$savedClientPath = [string](Get-Prop $state "clientPath" "")
if (-not $savedClientPath -or $savedClientPath -ne $tqPath) {
  $needsSetup = $true
}

Write-Step "Checking server reachability..."
$healthOk = Test-ServerHealth -ServerInfo $server
$gameOk = Test-GamePort -ServerInfo $server
if ($healthOk) {
  Write-Ok "PlayerConnect health OK"
} else {
  Write-Warn "PlayerConnect health check failed (proxy :$($server.proxyPort)). Continuing if game port is open..."
}
if ($gameOk) {
  Write-Ok ("Game port {0}:{1} is open" -f $server.host, $server.gamePort)
} else {
  Write-Err ("Cannot reach game port {0}:{1}" -f $server.host, $server.gamePort)
  Write-Host "  Ask the host to run StartMultiplayerHost.bat and open firewall ports." -ForegroundColor Yellow
  exit 2
}

$CaPemPath = Ensure-LocalCaFile -ServerInfo $server -PemPath $CaPemPath

# Always (re)install CA trust. Remote chat (XMPP :5222) and paid-service
# public-gateway TLS both fail with "socket hang up" when the EveJS CA is
# missing from the client certifi bundle / Windows trust store.
Write-Step "Ensuring EveJS CA trust (chat + public gateway)..."
$caInstall = Install-CaTrust -PemPath $CaPemPath -TqPath $tqPath
$trustBundle = $CaPemPath
if ($caInstall -and $caInstall.CombinedCaPath -and (Test-Path -LiteralPath $caInstall.CombinedCaPath)) {
  $trustBundle = [string]$caInstall.CombinedCaPath
}
if ($caInstall -and [int]$caInstall.UpdatedCount -le 0) {
  Write-Warn "No client cacert.pem was updated. Chat/gateway TLS may still fail inside exefile."
  Write-Warn "Confirm you selected the real EVE tq folder (contains bin64\cacert.pem)."
}

if ($needsSetup) {
  Write-Step "Preparing client for this server..."
  Set-StartIni -IniPath $startIni -ServerHost ([string]$server.host) -CryptoPack ([string]$server.cryptoPack)
  Ensure-BlueDllPatched -TqPath $tqPath
  Set-Prop $state "clientPath" $tqPath
  Set-Prop $state "lastHost" ([string]$server.host)
  Set-Prop $state "preparedAt" ((Get-Date).ToString("o"))
  Save-LocalState -State $state
  Write-Ok "Client prepared"
} else {
  Write-Ok "Client already pointed at this server"
}

if ($SkipLaunch) {
  Write-Ok "Setup complete (SkipLaunch)."
  exit 0
}

$proxyUrl = [string]$server.proxyUrl
if (-not $proxyUrl.EndsWith("/")) { $proxyUrl += "/" }
Apply-NetworkPolicy -ProxyUrl $proxyUrl.TrimEnd("/") -ServerHost ([string]$server.host) -CaPath $trustBundle

$env:EO_REMOTEFILECACHEFOLDER = $resources.ResFiles
$clientDir = Split-Path -Parent $clientExe

Write-Host ""
Write-Host "  Launching EVE client..." -ForegroundColor Cyan
Write-Host "    Host:   $($server.host)" -ForegroundColor DarkGray
Write-Host "    Proxy:  $proxyUrl" -ForegroundColor DarkGray
Write-Host "    Client: $clientExe" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Game is running. Close this window after you quit." -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

Push-Location $clientDir
$exitCode = 0
try {
  & $clientExe
  # StrictMode: $LASTEXITCODE is only set after a native process exit.
  if (Test-Path variable:LASTEXITCODE) {
    $exitCode = [int]$LASTEXITCODE
  }
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "  Client exited with code $exitCode"
exit $exitCode
