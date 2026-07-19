#Requires -Version 5.1
<#
.SYNOPSIS
  Configure this EveJS install as a multiplayer host and export a friend bundle.
#>
[CmdletBinding()]
param(
  [string]$HostAddress = "auto",
  [string]$Token = "",
  [switch]$LocalhostOnly,
  [switch]$KeepDevAuth,
  [switch]$OpenFirewall,
  [switch]$SkipBundle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$NodeScript = Join-Path $PSScriptRoot "configure-multiplayer-host.js"

function Write-Banner {
  Write-Host ""
  Write-Host "  ============================================================" -ForegroundColor Cyan
  Write-Host "    EveJS Multiplayer Host Setup" -ForegroundColor Cyan
  Write-Host "  ============================================================" -ForegroundColor Cyan
  Write-Host ""
}

function Ensure-Node {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    throw "Node.js is not installed or not on PATH. Install LTS from https://nodejs.org"
  }
}

function Open-EveJsFirewallRules {
  param(
    [int]$GamePort = 26000,
    [int]$ImagePort = 26001,
    [int]$ProxyPort = 26002,
    [int]$XmppPort = 5222
  )

  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host "  [WARN] Firewall rules need Administrator. Re-run this script elevated, or open ports manually:" -ForegroundColor Yellow
    Write-Host "         TCP $GamePort, $ImagePort, $ProxyPort, $XmppPort" -ForegroundColor Yellow
    return
  }

  $rules = @(
    @{ Name = "EveJS Game TCP"; Port = $GamePort },
    @{ Name = "EveJS Image HTTP"; Port = $ImagePort },
    @{ Name = "EveJS Proxy HTTP"; Port = $ProxyPort },
    @{ Name = "EveJS XMPP Chat"; Port = $XmppPort }
  )

  foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
      Write-Host "  Firewall rule already exists: $($rule.Name)" -ForegroundColor DarkGray
      continue
    }
    New-NetFirewallRule `
      -DisplayName $rule.Name `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort $rule.Port `
      -Profile Any | Out-Null
    Write-Host "  Added firewall rule: $($rule.Name) (TCP $($rule.Port))" -ForegroundColor Green
  }
}

Write-Banner
Ensure-Node

$nodeArgs = @($NodeScript, "--host", $HostAddress)
if ($Token) { $nodeArgs += @("--token", $Token) }
if ($LocalhostOnly) { $nodeArgs += "--localhost-only" }
if ($KeepDevAuth) { $nodeArgs += "--keep-dev-auth" }
if ($SkipBundle) { $nodeArgs += "--skip-bundle" }
$nodeArgs += "--json"

Push-Location $RepoRoot
try {
  $jsonText = & node @nodeArgs
  if ($LASTEXITCODE -ne 0) {
    throw "configure-multiplayer-host.js failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$summary = $jsonText | ConvertFrom-Json

Write-Host "  Mode:      $($summary.mode)"
Write-Host "  Bind:      $($summary.bindHost)"
Write-Host "  Advertise: $($summary.host)"
Write-Host "  Game:      $($summary.host):$($summary.gamePort)"
Write-Host "  Proxy:     http://$($summary.host):$($summary.proxyPort)/"
Write-Host "  Images:    http://$($summary.host):$($summary.imagePort)/"
Write-Host "  Chat:      $($summary.host):$($summary.xmppPort)"
Write-Host "  Token:     $($summary.token)"
Write-Host "  Config:    $($summary.configPath)"
if ($summary.bundleRoot) {
  Write-Host "  Bundle:    $($summary.bundleRoot)" -ForegroundColor Green
}

if ($OpenFirewall -and -not $LocalhostOnly) {
  Write-Host ""
  Write-Host "  Configuring Windows Firewall inbound rules..." -ForegroundColor Cyan
  Open-EveJsFirewallRules `
    -GamePort ([int]$summary.gamePort) `
    -ImagePort ([int]$summary.imagePort) `
    -ProxyPort ([int]$summary.proxyPort) `
    -XmppPort ([int]$summary.xmppPort)
}

Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Start the server with StartServer.bat (choose 1 = Server only)."
if ($summary.bundleRoot) {
  Write-Host "    2. Copy this folder to your friends:"
  Write-Host "         $($summary.bundleRoot)" -ForegroundColor Yellow
  Write-Host "    3. Friends double-click Connect.bat"
}
Write-Host "    4. Restart is required if the server was already running."
Write-Host ""
