#Requires -Version 5.1
<#
.SYNOPSIS
    Install pokemon-statusline into ~/.claude/ so Claude Code picks up the
    status line, /gacha slash command, sprites, and Pokedex data.

.PARAMETER Target
    Override the install target. Defaults to "$env:USERPROFILE\.claude".

.PARAMETER NoSettings
    Don't patch settings.json (statusLine + permissions.allow). Useful if you
    want to wire it up by hand.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$NoSettings
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
Write-Host ""
Write-Host "Installing pokemon-statusline" -ForegroundColor Cyan
Write-Host "  source: $src"
Write-Host "  target: $Target"
Write-Host ""

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }

# --- Copy each artefact, mirroring layout ---
$layout = @(
    @{ rel = 'statusline.ps1' },
    @{ rel = 'pokemon-dex.json' },
    @{ rel = 'pokemon-stats.json' },
    @{ rel = 'pokemon-flavor.json' },
    @{ rel = 'scripts\gacha.ps1' },
    @{ rel = 'commands\gacha.md' },
    @{ rel = 'skills\gacha\SKILL.md' }
)
foreach ($e in $layout) {
    $s = Join-Path $src $e.rel
    $d = Join-Path $Target $e.rel
    $dParent = Split-Path -Parent $d
    if (-not (Test-Path $dParent)) { New-Item -ItemType Directory -Path $dParent -Force | Out-Null }
    Copy-Item -Path $s -Destination $d -Force
    Write-Host "  copied: $($e.rel)"
}

# Sprites: 151 files + NOTICE
$spriteSrc = Join-Path $src 'sprites'
$spriteDst = Join-Path $Target 'sprites'
if (Test-Path $spriteDst) { Remove-Item -Path $spriteDst -Recurse -Force }
Copy-Item -Path $spriteSrc -Destination $spriteDst -Recurse -Force
Write-Host "  copied: sprites/ (regular + shiny, 302 files + NOTICE)"

# State file: don't overwrite if it already exists (preserves user progress)
$stateDst = Join-Path $Target 'gacha-state.json'
if (-not (Test-Path $stateDst)) {
    Write-Host "  initial state: will be created on first /gacha run"
} else {
    Write-Host "  kept: gacha-state.json (preserves your collection)"
}

# --- Patch ~/.claude/settings.json ---
if (-not $NoSettings) {
    $settingsPath = Join-Path $Target 'settings.json'
    $slCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Target 'statusline.ps1')`""
    if (Test-Path $settingsPath) {
        $cfg = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $cfg = [pscustomobject]@{}
    }

    # statusLine block
    $slBlock = [pscustomobject]@{ type = 'command'; command = $slCommand; padding = 0 }
    if ($cfg.PSObject.Properties.Name -contains 'statusLine') {
        $cfg.statusLine = $slBlock
    } else {
        $cfg | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $slBlock
    }

    # permissions.allow — ensure Bash + PowerShell allowed so /gacha works
    $want = @('Bash(*)', 'PowerShell(*)')
    if ($cfg.PSObject.Properties.Name -notcontains 'permissions') {
        $cfg | Add-Member -MemberType NoteProperty -Name 'permissions' -Value ([pscustomobject]@{ allow = @() })
    }
    if ($cfg.permissions.PSObject.Properties.Name -notcontains 'allow') {
        $cfg.permissions | Add-Member -MemberType NoteProperty -Name 'allow' -Value @()
    }
    $existing = @($cfg.permissions.allow)
    foreach ($a in $want) {
        if ($existing -notcontains $a) { $existing += $a }
    }
    $cfg.permissions.allow = $existing

    $cfg | ConvertTo-Json -Depth 12 | Out-File -FilePath $settingsPath -Encoding utf8 -Force
    Write-Host "  patched: settings.json (statusLine + permissions.allow)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Open any new Claude Code session — the status line will be live."
Write-Host "Try: /gacha pull   (1 coin = 1 booster, coins auto-earn from session cost)"
Write-Host ""
