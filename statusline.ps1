#Requires -Version 5.1
# Claude Code status line: Pokemon buddy theme.
# Sprite block LEFT, GBA-style STATUS box RIGHT.
# HP = 7-day subscription quota remaining  (from $ctx.rate_limits.weekly.used_percentage)
# MP = 5-hour subscription quota remaining (from $ctx.rate_limits.five_hour.used_percentage)
# SP = compaction-target remaining        (1 - last-assistant-usage / (context_window * 0.8))
# Each output line is wrapped with [0m + [K to prevent bg-color bleed above the line.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# --- Unicode glyphs ---
$G_LANG  = [char]0x27E8   # left angle bracket
$G_RANG  = [char]0x27E9
$G_FULL  = [char]0x2588
$G_MED   = [char]0x2592
$G_DOT   = [char]0x00B7
$G_COIN  = [char]0x26C1   # chains (closest "coin" BMP glyph)
$G_PIPE  = [char]0x2502   # box-drawing vertical (HP|MP|SP divider)

$ESC = [char]27
$RESET_EOL = "$ESC[0m$ESC[K"
function Color([string]$code, [string]$text) { "$ESC[${code}m$text$ESC[0m" }
function Gold([string]$text) { "$ESC[1;38;5;220m$text$ESC[0m" }
function Dim([string]$text) { "$ESC[2m$text$ESC[0m" }

# --- Cross-process state lock (mirrors gacha.ps1 helpers) ---
# Global\ namespace so it spans CC sessions. Keep in sync with gacha.ps1.
function New-StateLock {
    return New-Object System.Threading.Mutex($false, 'Global\PokemonGachaState')
}
function Acquire-StateLock($mutex, [int]$timeoutMs = 2000) {
    if ($null -eq $mutex) { return $false }
    try { return $mutex.WaitOne($timeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}
function Release-StateLock($mutex) {
    if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
}

# --- Read context JSON from stdin ---
# Verified Claude Code 2.1.144 stdin schema (see notes in repo):
#   ctx.rate_limits.five_hour.used_percentage  /  ctx.rate_limits.seven_day.used_percentage
#   ctx.context_window.context_window_size  /  ctx.context_window.total_input_tokens
$raw = [Console]::In.ReadToEnd()
$ctx = try { $raw | ConvertFrom-Json } catch { $null }

$cwd = $null
if ($ctx) {
    if ($ctx.workspace -and $ctx.workspace.current_dir) { $cwd = $ctx.workspace.current_dir }
    elseif ($ctx.cwd) { $cwd = $ctx.cwd }
}
if (-not $cwd) { $cwd = (Get-Location).Path }

$cost      = if ($ctx -and $ctx.cost) { [double]$ctx.cost.total_cost_usd } else { 0.0 }
$durTotal  = if ($ctx -and $ctx.cost) { [double]$ctx.cost.total_duration_ms } else { 0.0 }
$durApi    = if ($ctx -and $ctx.cost) { [double]$ctx.cost.total_api_duration_ms } else { 0.0 }
$transcriptPath = if ($ctx -and $ctx.transcript_path) { [string]$ctx.transcript_path } else { $null }

# --- Paths ---
# Assets (sprites, dex) travel with the script: $PSScriptRoot is the .claude dir.
# State is global at ~/.claude/gacha-state.json so dev (buzz-wiki) + deployed sessions share one
# Pokedex collection / coin balance / buddy / cost_log.
$ClaudeDir = $PSScriptRoot
$gachaStateFile = Join-Path $env:USERPROFILE '.claude\gacha-state.json'
$gachaState = $null
if (Test-Path $gachaStateFile) {
    try {
        $gj = Get-Content $gachaStateFile -Raw -Encoding UTF8
        if ($gj.Trim().Length -gt 0) { $gachaState = $gj | ConvertFrom-Json }
    } catch {}
}

# Load $dex EARLY (originally was loaded ~line 309 after the dirty block, which
# meant the encounter-spawn code at line ~169 inside the dirty block saw $dex=$null
# and never populated $pool. The legacy `foreach ($p in $dex)` bug masked this
# because the empty iteration silently failed too; fixing the loop only exposed
# this deeper ordering issue).
$dex = $null
$dexFile = Join-Path $ClaudeDir 'pokemon-dex.json'
if (Test-Path $dexFile) {
    try { $dex = Get-Content $dexFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

if ($gachaState) {
    # Compute the deltas this render owns; we DON'T mutate $gachaState in-place
    # then serialize the whole object back — that races with concurrent gacha.ps1
    # writes (team/owned/last_pull/stats) and overwrites them with our stale copy.
    # Instead: collect intent here, re-read the freshest state right before save,
    # patch only the fields statusline.ps1 owns, then write.
    $dirty = $false

    $costProcessed = [double]$gachaState.cost_usd_processed
    $delta = $cost - $costProcessed
    $coinsToAdd = 0
    $newProcessed = $costProcessed
    if ($delta -ge 1.0) {
        $coinsToAdd = [int][Math]::Floor($delta)
        $newProcessed = $costProcessed + $coinsToAdd
        $dirty = $true
    }

    $sessionId = if ($ctx -and $ctx.session_id) { [string]$ctx.session_id } else { $null }
    $wasNewSession = ($sessionId -and ($sessionId -ne [string]$gachaState.last_session_id))
    if ($wasNewSession) { $dirty = $true }

    $nowEp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $lastRenderCost = if ($null -ne $gachaState.last_render_cost) { [double]$gachaState.last_render_cost } else { 0.0 }
    $costDelta = if ($wasNewSession) { $cost } else { [Math]::Max(0, $cost - $lastRenderCost) }
    $newCostEntry = $null
    if ($costDelta -gt 0.0001) {
        $newCostEntry = @{ ts = $nowEp; delta = $costDelta }
        $dirty = $true
    }

    if ($dirty) {
        # Acquire cross-process mutex before re-read/write. Short timeout: if a
        # /gacha command is busy we skip THIS write (re-tries on next render);
        # statusline must never block a CC frame.
        $__slMutex = New-StateLock
        $__slLocked = Acquire-StateLock $__slMutex 2000
        if (-not $__slLocked) {
            # Couldn't get the lock — abandon write, leaving deltas for the next
            # render to pick up (cost_usd_processed didn't change, so the same
            # coinsToAdd will recompute; session tick is one-shot but rare enough
            # to lose occasionally).
            Release-StateLock $__slMutex
        } else {
        try {
        # Re-read latest state right before write to avoid stomping on concurrent
        # gacha.ps1 mutations (team/owned/last_pull/stats). Belt-and-suspenders
        # with the mutex above.
        $fresh = $null
        try {
            $fj = Get-Content -Path $gachaStateFile -Raw -Encoding UTF8 -ErrorAction Stop
            if ($fj.Trim().Length -gt 0) { $fresh = $fj | ConvertFrom-Json }
        } catch {}
        if (-not $fresh) { $fresh = $gachaState }   # fall back to the cached copy

        # Patch only fields this script owns.
        if ($coinsToAdd -gt 0) {
            $fresh.coins = [int]$fresh.coins + $coinsToAdd
            $fresh.cost_usd_processed = $newProcessed
        }
        $fresh.last_render_cost = $cost
        if ($wasNewSession) {
            $fresh.last_session_id = $sessionId
            $fresh.sessions_count = [int]$fresh.sessions_count + 1
            if ($fresh.buddy -and $fresh.buddy.id) {
                $fresh.buddy.exp = [int]$fresh.buddy.exp + 1
                # Mirror the tick into team[0].exp — Sync-Buddy-From-Team in gacha.ps1
                # treats team[0] as source of truth and would otherwise wipe this on
                # next /gacha command. Skip if legacy schema (team[0] is bare int);
                # gacha.ps1 migration will pick up buddy.exp into team[0] next run.
                if ($fresh.team -and $fresh.team.Count -gt 0) {
                    $t0 = $fresh.team[0]
                    if ($t0 -is [pscustomobject] -and $t0.PSObject.Properties.Name -contains 'exp') {
                        $t0.exp = [int]$t0.exp + 1
                    }
                }
            }
            # Repel countdown: if user used /gacha use repel, skip encounter rolls for N sessions.
            $repelLeft = if ($null -ne $fresh.repel_sessions) { [int]$fresh.repel_sessions } else { 0 }
            $repelActive = $repelLeft -gt 0
            if ($repelActive) { $fresh.repel_sessions = $repelLeft - 1 }

            # Wild encounter roll: 3% per new session. Only if no encounter pending AND no repel.
            # Pyramid pool C 60 / U 25 / R 12 / HR 3 — HR (legendaries) ONLY appear here.
            # Bumped from 1% to 3% in same commit as the pool-iteration bug fix: at 1%
            # plus the prior bug, the user had ~677 sessions with zero encounters.
            $hasEncounter = ($fresh.encounter -and $fresh.encounter.id -and [int]$fresh.encounter.id -gt 0)
            if (-not $repelActive -and -not $hasEncounter -and (Get-Random -Maximum 100) -lt 3) {
                $rRoll = Get-Random -Maximum 100
                $eRarity = if ($rRoll -lt 3) { 'HR' } elseif ($rRoll -lt 15) { 'R' } elseif ($rRoll -lt 40) { 'U' } else { 'C' }
                # Pick random id from rarity pool. $dex.pokemon is an array of positional
                # rows [id, name_en, name_zh, type1, type2, stage, evolves_to, rarity, pullable, evolve_level]
                # so rarity is row[7], id is row[0]. PRE-FIX BUG: iterated $dex directly
                # (a single JSON object) so $pool was always empty and encounters never spawned.
                $pool = @()
                if ($dex -and $dex.pokemon) {
                    foreach ($p in $dex.pokemon) {
                        if ([string]$p[7] -eq $eRarity) { $pool += [int]$p[0] }
                    }
                }
                if ($pool.Count -gt 0) {
                    $eid = $pool[(Get-Random -Maximum $pool.Count)]
                    $newEncounter = [ordered]@{
                        id            = [int]$eid
                        rarity        = [string]$eRarity
                        attempts_left = 3
                        spawned_at_ep = $nowEp
                    }
                    if ($fresh.PSObject.Properties.Name -contains 'encounter') {
                        $fresh.encounter = $newEncounter
                    } else {
                        $fresh | Add-Member -MemberType NoteProperty -Name 'encounter' -Value $newEncounter -Force
                    }
                }
            }
        }

        # cost_log housekeeping (own field).
        if ($null -eq $fresh.cost_log -or -not ($fresh.cost_log -is [System.Array])) {
            $fresh.cost_log = @()
        }
        if ($newCostEntry) { $fresh.cost_log = @($fresh.cost_log) + $newCostEntry }
        # Trim entries older than 7 days
        $weekAgo = $nowEp - 7 * 86400
        $kept = @()
        foreach ($e in $fresh.cost_log) { if ([int]$e.ts -ge $weekAgo) { $kept += $e } }
        $fresh.cost_log = $kept

        try { $fresh | ConvertTo-Json -Depth 12 | Out-File -FilePath $gachaStateFile -Encoding utf8 -Force } catch {}
        } finally {
            Release-StateLock $__slMutex
        }
        }
    }
}

# --- Type glyphs / colors (mirrors gacha.ps1) ---
$tGlyph = @{
    'normal'   = [char]0x2606; 'fire'     = [char]0x2726; 'water'   = [char]0x25C8
    'electric' = [char]0x26A1; 'grass'    = [char]0x2740; 'ice'     = [char]0x2744
    'fighting' = [char]0x2694; 'poison'   = [char]0x2620; 'ground'  = [char]0x2B23
    'flying'   = [char]0x27A4; 'psychic'  = [char]0x2736; 'bug'     = [char]0x2723
    'rock'     = [char]0x2B22; 'ghost'    = [char]0x263D; 'dragon'  = [char]0x272F
}
$tCol = @{
    'normal'   = '38;5;250'; 'fire'     = '38;5;202'; 'water'   = '38;5;39'
    'electric' = '38;5;226'; 'grass'    = '38;5;46';  'ice'     = '38;5;87'
    'fighting' = '38;5;208'; 'poison'   = '38;5;141'; 'ground'  = '38;5;179'
    'flying'   = '38;5;153'; 'psychic'  = '38;5;213'; 'bug'     = '38;5;154'
    'rock'     = '38;5;138'; 'ghost'    = '38;5;105'; 'dragon'  = '38;5;199'
}
$rarityColor = @{ 'C' = '38;5;245'; 'U' = '38;5;82'; 'R' = '38;5;220'; 'HR' = '38;5;213' }

# --- Badge glyph table (mirrors gacha.ps1 $BadgeGlyphs) ---
# Keep these two copies in sync — see CLAUDE.md "Sprite rendering" note.
$BadgeGlyphs = @{
    1 = @{ glyph=[char]0x25C6; color='38;5;138' }
    2 = @{ glyph=[char]0x25C7; color='38;5;39'  }
    3 = @{ glyph=[char]0x2726; color='38;5;226' }
    4 = @{ glyph=[char]0x2740; color='38;5;213' }
    5 = @{ glyph=[char]0x2605; color='38;5;220' }
    6 = @{ glyph=[char]0x2665; color='38;5;141' }
    7 = @{ glyph=[char]0x25B2; color='38;5;196' }
    8 = @{ glyph=[char]0x25CF; color='38;5;76'  }
}
$BadgeEmptyGlyph = [char]0x00B7

# --- Theme palette (mirrors gacha.ps1 $Themes). state.theme selects which row applies. ---
# Falls back to 'gba' if missing or unknown. Used to override $outerCol / $outerTitleCol /
# $frameCol / $labelCol below.
$Themes = @{
    'gba'     = @{ outer='38;5;220'; outerTitle='1;38;5;226'; frame='38;5;111'; label='38;5;220' }
    'crystal' = @{ outer='38;5;251'; outerTitle='1;38;5;255'; frame='38;5;87';  label='38;5;87'  }
    'dark'    = @{ outer='38;5;240'; outerTitle='38;5;247';   frame='38;5;60';  label='38;5;245' }
}

# --- Mini progress-bar helper ---
function Bar([int]$pct, [int]$cells, [string]$colorFull, [string]$colorEmpty = '38;5;238') {
    if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }
    $filled = [int][Math]::Round(($pct / 100.0) * $cells)
    $out = ''
    for ($i = 0; $i -lt $cells; $i++) {
        if ($i -lt $filled) { $out += Color $colorFull $G_FULL } else { $out += Color $colorEmpty $G_MED }
    }
    return $out
}

# --- BMP emoji glyphs that render 2 cells in Windows Terminal (UAX #11 Wide) ---
# These would otherwise miss the CJK ranges and be undercounted as 1 cell,
# pushing right-side padding 1 char too long for any row containing them.
$WIDE_EMOJI_BMP = @{}
@(0x2614,0x2615,0x26A1,0x26AA,0x26AB,0x26BD,0x26BE,0x26C4,0x26C5,0x26CE,0x26D4,
  0x26EA,0x26F2,0x26F3,0x26F5,0x26FA,0x26FD,0x2705,0x270A,0x270B,0x2728,
  0x274C,0x274E,0x2753,0x2754,0x2755,0x2757,0x2795,0x2796,0x2797,0x27B0,0x27BF
) | ForEach-Object { $WIDE_EMOJI_BMP[$_] = $true }

# --- Helper: visible width of an ANSI-coded line ---
# CJK + wide-emoji glyphs count as 2 cells (East Asian Wide per UAX #11).
function Get-VisibleWidth([string]$s) {
    $stripped = $s -replace "$ESC\[[\d;]*[mK]", ''
    $width = 0
    foreach ($ch in $stripped.ToCharArray()) {
        $code = [int]$ch
        if ($WIDE_EMOJI_BMP.ContainsKey($code) -or
            ($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0x303E) -or
            ($code -ge 0x3041 -and $code -le 0x33FF) -or
            ($code -ge 0x3400 -and $code -le 0x4DBF) -or
            ($code -ge 0x4E00 -and $code -le 0x9FFF) -or
            ($code -ge 0xA000 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE4F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

# --- Level formula: triangular EXP curve (mirrors gacha.ps1) ---
# thresh(L) = L*(L-1)/2 exp to reach L. Get-Level returns the largest L with
# thresh(L) <= exp. The exact inverse is floor((1+sqrt(1+8*exp))/2); the older
# floor(sqrt(2*exp))+1 was only correct at the level boundary and rendered
# negative within-level progress in the middle.
function Get-Level([int]$exp) {
    if ($exp -lt 0) { return 1 }
    return [int][Math]::Floor((1 + [Math]::Sqrt(1 + 8.0 * $exp)) / 2)
}
function Get-ExpForLevel([int]$lvl) {
    if ($lvl -le 1) { return 0 }
    return [int]($lvl * ($lvl - 1) / 2)
}

# --- Dex lookup helper (dex loaded earlier at top, before the dirty block) ---
function Lookup-Poke($dex, [int]$id) {
    if (-not $dex) { return $null }
    foreach ($p in $dex.pokemon) {
        if ([int]$p[0] -eq $id) {
            return @{
                id = [int]$p[0]; name_en = [string]$p[1]; name_zh = [string]$p[2]
                type1 = [string]$p[3]; stage = [int]$p[5]
                evolves_to = $p[6]; rarity = [string]$p[7]
                evolve_level = if ($null -ne $p[9]) { [int]$p[9] } else { $null }
            }
        }
    }
    return $null
}

# --- Resolve team for sprite area (1 leader + up to 2 companions = 3 visible). Rest go to TEAM-overflow text. ---
# Team rows are now objects @{id, exp, shiny} (post-migration). Pull .id for
# sprite/name lookups; per-slot exp isn't used here — leader EXP bar reads
# gachaState.buddy.exp, which Sync-Buddy keeps mirrored to team[0].
$teamAll = @()
if ($gachaState -and $gachaState.team) {
    foreach ($x in $gachaState.team) {
        $xid = if ($null -ne $x.id) { [int]$x.id } else { [int]$x }   # tolerate legacy int rows
        $teamAll += $xid
    }
} elseif ($gachaState -and $gachaState.buddy -and $gachaState.buddy.id) {
    $teamAll = @([int]$gachaState.buddy.id)
}
$visibleSprites = @()
$overflowCompanions = @()
if ($teamAll.Count -gt 0) {
    $cap = [Math]::Min(3, $teamAll.Count)
    for ($i = 0; $i -lt $cap; $i++) { $visibleSprites += [int]$teamAll[$i] }
    if ($teamAll.Count -gt 3) {
        for ($i = 3; $i -lt $teamAll.Count; $i++) { $overflowCompanions += [int]$teamAll[$i] }
    }
}

# Per-team-slot duplicate label: when a dex_id appears more than once in team,
# tag each occurrence with [A]/[B]/[C]/... in team order so the user can tell
# which copy is which in the name row and overflow segment.
$dupTotals = @{}
foreach ($t in $teamAll) {
    $k = [string][int]$t
    if ($dupTotals.ContainsKey($k)) { $dupTotals[$k] = $dupTotals[$k] + 1 } else { $dupTotals[$k] = 1 }
}
$slotLetter = @()   # parallel to $teamAll: '' if unique, 'A'/'B'/... if dupe
$dupSeen = @{}
foreach ($t in $teamAll) {
    $k = [string][int]$t
    if ($dupTotals[$k] -gt 1) {
        $seen = if ($dupSeen.ContainsKey($k)) { $dupSeen[$k] + 1 } else { 1 }
        $dupSeen[$k] = $seen
        $slotLetter += ([string][char]([byte][char]'A' + $seen - 1))
    } else {
        $slotLetter += ''
    }
}

# --- Build LEFT column: stats only (no leader text — that lives in sprite area now) ---
$parts = @()

# --- HP (7-day) + MP (5-hour) from $ctx.rate_limits if Claude Code exposes it (CC 1.445+) ---
# Schema is best-effort: try several plausible key names + percentage encodings.
function Get-RateLimitObj($rl, [string]$window) {
    if (-not $rl) { return $null }
    $candidates = if ($window -eq '5h') {
        @('five_hour', 'fiveHour', 'hourly', '5h', 'five_hour_opus', 'fiveHourOpus')
    } else {
        @('weekly', 'seven_day', 'sevenDay', '7d', 'weekly_opus', 'weeklyOpus')
    }
    foreach ($k in $candidates) {
        $obj = $null
        try { $obj = $rl.$k } catch { }
        if ($obj) { return $obj }
    }
    return $null
}
function Get-RateLimitPct($obj) {
    if (-not $obj) { return $null }
    foreach ($k in @('used_percentage', 'usedPercentage', 'used_percent', 'usedPercent', 'percentage', 'used')) {
        $v = $null
        try { $v = $obj.$k } catch { }
        if ($null -ne $v) { return [double]$v }
    }
    return $null
}

$rlObj = $null
if ($ctx) {
    foreach ($k in @('rate_limits', 'rateLimits', 'limits', 'usage', 'rate_limit')) {
        $cand = $null
        try { $cand = $ctx.$k } catch { }
        if ($cand) { $rlObj = $cand; break }
    }
}
$rlWeekly = Get-RateLimitObj $rlObj '7d'
$rlFiveHr = Get-RateLimitObj $rlObj '5h'
$weeklyUsedPct = Get-RateLimitPct $rlWeekly
$fiveHrUsedPct = Get-RateLimitPct $rlFiveHr

if ($null -ne $weeklyUsedPct) {
    $hpPct = [int][Math]::Max(0, [Math]::Min(100, 100 - $weeklyUsedPct))
    $hpSrc = 'sub'
} else {
    # Fallback: cost_log $500 weekly budget
    $BUDGET_7DAY = 500.0
    $cost7d = 0.0
    if ($gachaState -and $gachaState.cost_log) {
        $nowEp2 = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $weekAgo2 = $nowEp2 - 7 * 86400
        foreach ($e in $gachaState.cost_log) {
            $ts = [int]$e.ts
            if ($ts -ge $weekAgo2) { $cost7d += [double]$e.delta }
        }
    }
    $hpPct = [int][Math]::Max(0, [Math]::Min(100, 100 - ($cost7d / $BUDGET_7DAY * 100)))
    $hpSrc = 'est'
}
$hpColor = if ($hpPct -ge 70) { '38;5;46' } elseif ($hpPct -ge 30) { '38;5;226' } else { '38;5;196' }

if ($null -ne $fiveHrUsedPct) {
    $mpPct = [int][Math]::Max(0, [Math]::Min(100, 100 - $fiveHrUsedPct))
    $mpSrc = 'sub'
} else {
    # Fallback: cost_log $50 5-hour budget
    $BUDGET_5HOUR = 50.0
    $cost5h = 0.0
    if ($gachaState -and $gachaState.cost_log) {
        $nowEp2 = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $fiveHrAgo = $nowEp2 - 5 * 3600
        foreach ($e in $gachaState.cost_log) {
            $ts = [int]$e.ts
            if ($ts -ge $fiveHrAgo) { $cost5h += [double]$e.delta }
        }
    }
    $mpPct = [int][Math]::Max(0, [Math]::Min(100, 100 - ($cost5h / $BUDGET_5HOUR * 100)))
    $mpSrc = 'est'
}
$mpColor = if ($mpPct -ge 70) { '38;5;46' } elseif ($mpPct -ge 30) { '38;5;226' } else { '38;5;196' }

# --- SP = compaction-target remaining ---
# Prefer $ctx.context_window (Claude Code exposes it directly with input_tokens + window size).
# Compaction triggers around 80% of context_window_size.
$ctxWindow = 200000
$ctxTokens = $null
if ($ctx -and $ctx.context_window) {
    $cw = $ctx.context_window
    if ($cw.context_window_size -and [int]$cw.context_window_size -gt 0) { $ctxWindow = [int]$cw.context_window_size }
    if ($null -ne $cw.total_input_tokens) { $ctxTokens = [int]$cw.total_input_tokens }
}
$compactThreshold = [int]($ctxWindow * 0.8)
if ($null -ne $ctxTokens) {
    $spUsedPct = [Math]::Min(100, ($ctxTokens / [double]$compactThreshold) * 100)
    $spPct = [int][Math]::Max(0, 100 - $spUsedPct)
    $spSrc = "$([int]($ctxTokens / 1000))k"
} else {
    $spPct = 100; $spSrc = 'ctx'
}
$spColor = if ($spPct -ge 70) { '38;5;39' } elseif ($spPct -ge 30) { '38;5;226' } else { '38;5;196' }

$parts += "$(Color '38;5;196' 'HP ') $(Bar $hpPct 5 $hpColor) $(Color '38;5;245' "$($hpPct.ToString().PadLeft(3))% 7d")"
$parts += "$(Color '38;5;208' 'MP ') $(Bar $mpPct 5 $mpColor) $(Color '38;5;245' "$($mpPct.ToString().PadLeft(3))% 5h")"
$parts += "$(Color '38;5;39'  'SP ') $(Bar $spPct 5 $spColor) $(Color '38;5;245' "$($spPct.ToString().PadLeft(3))% $spSrc")"

if ($gachaState) {
    $parts += "$(Color '38;5;220' "$G_COIN  $([int]$gachaState.coins) coin")"
    $caught = 0
    if ($gachaState.owned) {
        foreach ($k in $gachaState.owned.PSObject.Properties.Name) {
            if ([int]$gachaState.owned.$k.count -gt 0) { $caught++ }
        }
    }
    $parts += "$(Color '38;5;255' "DEX $caught/151")"
    if ($gachaState.last_pull -and $gachaState.last_pull.id) {
        $lp = $gachaState.last_pull
        $rTag = Color $rarityColor[[string]$lp.rarity] ([string]$lp.rarity)
        $nTag = if ([bool]$lp.shiny) { Gold ([string]$lp.name_zh) } else { Color '38;5;255' ([string]$lp.name_zh) }
        $parts += "$(Color '38;5;245' 'LAST') $rTag $nTag"
    }
    # STREAK row: only when current >= 2, so the 0/1 case doesn't add a row of noise.
    # Sparkle count clamps at 5 cells so the box width doesn't blow up on a long streak.
    $bsCur = [int]$gachaState.battle_streak_current
    if ($bsCur -ge 2) {
        $bsBest = [int]$gachaState.battle_streak_best
        $sparkCh = [char]0x2726
        $sparkCount = [Math]::Min($bsCur, 5)
        $sparks = ([string]$sparkCh) * $sparkCount
        $sparkCol = if ($bsCur -ge 3) { '1;38;5;220' } else { '38;5;208' }
        $parts += "$(Color '38;5;141' 'STR') $(Color $sparkCol $sparks) $(Color '38;5;245' "$bsCur (best $bsBest)")"
    }
}

# TEAM overflow (companions beyond visible sprites)
if ($overflowCompanions.Count -gt 0) {
    $companionGlyphs = @()
    for ($oi = 0; $oi -lt $overflowCompanions.Count; $oi++) {
        $cid = [int]$overflowCompanions[$oi]
        $info = Lookup-Poke $dex $cid
        $cType = if ($info) { $info.type1 } else { 'normal' }
        $cGlyph = if ($tGlyph.ContainsKey($cType)) { Color $tCol[$cType] "$($tGlyph[$cType])" } else { '?' }
        # Slot letter index for overflow = visible-3 + overflow-position
        $slotIdx = $visibleSprites.Count + $oi
        $cLetter = if ($slotIdx -lt $slotLetter.Count -and $slotLetter[$slotIdx]) { (Color '1;38;5;226' "[$($slotLetter[$slotIdx])]") } else { '' }
        $companionGlyphs += "$cGlyph$(Color '38;5;245' "#$('{0:D3}' -f $cid)")$cLetter"
    }
    $parts += "$(Color '38;5;141' 'TEAM') $($companionGlyphs -join ' ')"
}

# --- Build RIGHT column: sprite art + name row + leader extra row ---
$rightCol = @()
$widths = @()
if ($visibleSprites.Count -ge 1) {
    $sprites = @()
    foreach ($id in $visibleSprites) {
        $path = Join-Path $ClaudeDir "sprites\regular\$id.txt"
        if (Test-Path $path) { $sprites += , @(Get-Content $path -Encoding UTF8) }
    }
    if ($sprites.Count -ge 1) {
        # Top-pad shorter sprites to align baselines
        $maxLines = 0
        foreach ($s in $sprites) { if ($s.Count -gt $maxLines) { $maxLines = $s.Count } }
        $padded = @()
        foreach ($s in $sprites) {
            $need = $maxLines - $s.Count
            if ($need -gt 0) {
                $blanks = @()
                for ($k = 0; $k -lt $need; $k++) { $blanks += '' }
                $padded += , ($blanks + $s)
            } else { $padded += , $s }
        }
        # Per-sprite column widths
        foreach ($s in $padded) {
            $maxW = 0
            foreach ($l in $s) {
                $w = Get-VisibleWidth $l
                if ($w -gt $maxW) { $maxW = $w }
            }
            $widths += $maxW
        }
        # Sprite art rows
        for ($i = 0; $i -lt $maxLines; $i++) {
            $row = ''
            for ($j = 0; $j -lt $padded.Count; $j++) {
                $line = $padded[$j][$i]
                if ($null -eq $line) { $line = '' }
                $vw = Get-VisibleWidth $line
                $pad = ' ' * ([Math]::Max(0, $widths[$j] - $vw + 2))
                $row += $line + $pad
            }
            $rightCol += $row
        }
        # Name row: each pokemon shows `glyph #NNN name_zh`. Leader bolded.
        $nameRow = ''
        for ($j = 0; $j -lt $visibleSprites.Count; $j++) {
            $id = [int]$visibleSprites[$j]
            $info = Lookup-Poke $dex $id
            $type = if ($info) { $info.type1 } else { 'normal' }
            $name_zh = if ($info) { $info.name_zh } else { "#$id" }
            $glyph = if ($tGlyph.ContainsKey($type)) { Color $tCol[$type] "$($tGlyph[$type])" } else { '?' }
            $isLeader = ($j -eq 0)
            # Leader shiny check via buddy cache; companions skip shiny check for now
            $shiny = $false
            $nick = $null
            if ($isLeader -and $gachaState -and $gachaState.buddy) {
                $shiny = [bool]$gachaState.buddy.shiny
                if ($gachaState.buddy.PSObject.Properties.Name -contains 'nickname' -and $gachaState.buddy.nickname) {
                    $nick = [string]$gachaState.buddy.nickname
                }
            }
            $displayName = if ($nick) { $nick } else { $name_zh }
            $nameTxt = if ($shiny) { Gold $displayName } elseif ($isLeader) { "$ESC[1;38;5;255m$displayName$ESC[0m" } else { Color '38;5;255' $displayName }
            $letterTag = if ($j -lt $slotLetter.Count -and $slotLetter[$j]) { ' ' + (Color '1;38;5;226' "[$($slotLetter[$j])]") } else { '' }
            $cell = "$glyph #$('{0:D3}' -f $id) $nameTxt$letterTag"
            $cellW = Get-VisibleWidth $cell
            $cellPad = ' ' * ([Math]::Max(0, $widths[$j] - $cellW + 2))
            $nameRow += $cell + $cellPad
        }
        $rightCol += $nameRow
        # Leader extra row: L<lvl> + EXP bar under leader. EVO badge if ready.
        if ($gachaState -and $gachaState.buddy -and $gachaState.buddy.id -and $widths.Count -gt 0) {
            $bExp = [int]$gachaState.buddy.exp
            $bLvl = Get-Level $bExp
            $bEvolveLvl = if ($null -ne $gachaState.buddy.evolve_level) { [int]$gachaState.buddy.evolve_level } else { $null }
            $bHasEvol = ($null -ne $gachaState.buddy.evolves_to -and "$($gachaState.buddy.evolves_to)" -ne '')
            if ($null -eq $bEvolveLvl -or -not $bHasEvol) {
                $li = Lookup-Poke $dex ([int]$gachaState.buddy.id)
                if ($li) {
                    if ($null -eq $bEvolveLvl) { $bEvolveLvl = $li.evolve_level }
                    if (-not $bHasEvol -and $null -ne $li.evolves_to) { $bHasEvol = $true }
                }
            }
            $evoBadge = ''
            if ($bHasEvol -and $null -ne $bEvolveLvl) {
                if ($bLvl -ge $bEvolveLvl -and [int]$gachaState.coins -ge $bEvolveLvl) {
                    $evoBadge = ' ' + (Color '1;38;5;226' '*EVO*')
                }
            }
            # EXP bar: shows progress within current level (exp gained since reaching $bLvl
            # vs exp needed to reach $bLvl+1). More meaningful than %-to-evolve under the
            # non-linear curve where mid-game levels span tens of sessions each.
            $leaderExtra = ''
            $curThresh = Get-ExpForLevel $bLvl
            $nextThresh = Get-ExpForLevel ($bLvl + 1)
            $within = $bExp - $curThresh
            $span = [Math]::Max(1, $nextThresh - $curThresh)
            $lvlPct = [int][Math]::Min(100, ($within / [double]$span) * 100)
            $expBar = Bar $lvlPct 5 '38;5;82'
            if ($bHasEvol -and $null -ne $bEvolveLvl) {
                $leaderExtra = "$(Color '1;38;5;82' "LV. $bLvl") $expBar $(Color '38;5;245' "$within/$span") $(Dim "(evo LV. $bEvolveLvl)")$evoBadge"
            } else {
                $leaderExtra = "$(Color '1;38;5;82' "LV. $bLvl") $expBar $(Color '38;5;245' "$within/$span")"
            }
            $extraW = Get-VisibleWidth $leaderExtra
            $extraPad = ' ' * ([Math]::Max(0, $widths[0] - $extraW + 2))
            $rightCol += $leaderExtra + $extraPad
        }
    }
}

# --- Wrap stats in GBA-style double-line frame ---
$T_LT = [string][char]0x2554   # top-left double corner
$T_RT = [string][char]0x2557
$T_LB = [string][char]0x255A
$T_RB = [string][char]0x255D
$T_HZ = [string][char]0x2550   # horizontal double line
$T_VT = [string][char]0x2551   # vertical double line
$themeName = if ($gachaState -and $gachaState.theme) { [string]$gachaState.theme } else { 'gba' }
if (-not $Themes.ContainsKey($themeName)) { $themeName = 'gba' }
$T = $Themes[$themeName]
$frameCol = $T.frame
$labelCol = $T.label

$contentW = 0
foreach ($p in $parts) {
    $w = Get-VisibleWidth $p
    if ($w -gt $contentW) { $contentW = $w }
}
$contentW = [Math]::Max(20, $contentW + 2)   # +2 inner padding

$labelText = ' STATUS '
$leftFillN = 2
$rightFillN = $contentW - $leftFillN - $labelText.Length
if ($rightFillN -lt 0) { $rightFillN = 0 }
$horizLeft = $T_HZ * $leftFillN
$horizRight = $T_HZ * $rightFillN
$horizFull = $T_HZ * $contentW

$boxTop = (Color $frameCol "$T_LT$horizLeft") + (Color $labelCol $labelText) + (Color $frameCol "$horizRight$T_RT")
$boxBot = Color $frameCol "$T_LB$horizFull$T_RB"
$boxLines = @($boxTop)
foreach ($p in $parts) {
    $w = Get-VisibleWidth $p
    $pad = ' ' * [Math]::Max(0, $contentW - $w - 1)
    $boxLines += (Color $frameCol $T_VT) + ' ' + $p + $pad + (Color $frameCol $T_VT)
}
$boxLines += $boxBot

# --- Optional BADGES sub-box: same width as STATUS, stacked directly underneath ---
$badgeBoxLines = @()
if ($gachaState -and $gachaState.gyms_beaten -and $gachaState.gyms_beaten.Count -gt 0) {
    $beatenSet = @{}
    foreach ($g in $gachaState.gyms_beaten) { $beatenSet[[int]$g] = $true }
    $slots = @()
    for ($i = 1; $i -le 8; $i++) {
        $bg = $BadgeGlyphs[$i]
        if ($beatenSet[$i]) { $slots += (Color $bg.color "$($bg.glyph)") }
        else { $slots += (Color '38;5;238' "$BadgeEmptyGlyph") }
    }
    $badgeContent = ($slots -join ' ') + '  ' + (Color '1;38;5;220' "$($beatenSet.Count)/8")
    $bLabelText = ' BADGES '
    $bLeftFillN = 2
    $bRightFillN = $contentW - $bLeftFillN - $bLabelText.Length
    if ($bRightFillN -lt 0) { $bRightFillN = 0 }
    $bHorizLeft  = $T_HZ * $bLeftFillN
    $bHorizRight = $T_HZ * $bRightFillN
    $bTop = (Color $frameCol "$T_LT$bHorizLeft") + (Color $labelCol $bLabelText) + (Color $frameCol "$bHorizRight$T_RT")
    $bBot = Color $frameCol "$T_LB$horizFull$T_RB"
    $bcW  = Get-VisibleWidth $badgeContent
    $bcPad = ' ' * [Math]::Max(0, $contentW - $bcW - 1)
    $bContentLine = (Color $frameCol $T_VT) + ' ' + $badgeContent + $bcPad + (Color $frameCol $T_VT)
    $badgeBoxLines = @($bTop, $bContentLine, $bBot)
}
# Combine STATUS + BADGES into one right-column block so V-centering treats them as a unit
$rightBoxLines = if ($badgeBoxLines.Count -gt 0) { $boxLines + $badgeBoxLines } else { $boxLines }

# --- Compute sprite-block + status-box visible widths ---
$rightArr = @($rightCol)
$spriteBlockW = 0
foreach ($r in $rightArr) {
    $w = Get-VisibleWidth $r
    if ($w -gt $spriteBlockW) { $spriteBlockW = $w }
}
$boxBlockW = 0
foreach ($r in $rightBoxLines) {
    $w = Get-VisibleWidth $r
    if ($w -gt $boxBlockW) { $boxBlockW = $w }
}

# --- Compose inner content rows: sprite block (left) + GAP + status box (right), V-centered ---
$GAP = '   '
$innerH = [Math]::Max($rightArr.Count, $rightBoxLines.Count)
$spritePadTop = [int][Math]::Floor(($innerH - $rightArr.Count) / 2.0)
$boxPadTop = [int][Math]::Floor(($innerH - $rightBoxLines.Count) / 2.0)
$innerContentW = $spriteBlockW + $GAP.Length + $boxBlockW
$innerRows = @()
for ($i = 0; $i -lt $innerH; $i++) {
    $sIdx = $i - $spritePadTop
    $bIdx = $i - $boxPadTop
    $sLine = if ($sIdx -ge 0 -and $sIdx -lt $rightArr.Count) { $rightArr[$sIdx] } else { '' }
    $bLine = if ($bIdx -ge 0 -and $bIdx -lt $rightBoxLines.Count) { $rightBoxLines[$bIdx] } else { '' }
    $sVw = Get-VisibleWidth $sLine
    $sPad = ' ' * [Math]::Max(0, $spriteBlockW - $sVw)
    $innerRows += $sLine + $sPad + $GAP + $bLine
}

# --- Outer GBA-cartridge frame: gold double-line border + "POKEMON" title bar, H+V padding ---
$H_PAD = 4   # spaces inside frame on left & right of inner content
$V_PAD = 1   # blank rows above & below inner content inside frame
$outerCol = $T.outer
$outerTitleCol = $T.outerTitle
$outerInnerW = $innerContentW + 2 * $H_PAD
$outerTitle = ' POKEMON '
$oLeftFill = 3
$oRightFill = $outerInnerW - $oLeftFill - $outerTitle.Length
if ($oRightFill -lt 0) { $oRightFill = 0 }
$oTop = (Color $outerCol "$T_LT$($T_HZ * $oLeftFill)") + (Color $outerTitleCol $outerTitle) + (Color $outerCol "$($T_HZ * $oRightFill)$T_RT")
$oBot = Color $outerCol "$T_LB$($T_HZ * $outerInnerW)$T_RB"
$oBlank = (Color $outerCol $T_VT) + (' ' * $outerInnerW) + (Color $outerCol $T_VT)

# --- Encounter banner (above outer frame): shows pending wild pokemon ---
$encBanner = $null
if ($gachaState -and $gachaState.encounter -and $gachaState.encounter.id -and [int]$gachaState.encounter.id -gt 0) {
    $eid = [int]$gachaState.encounter.id
    $erty = [string]$gachaState.encounter.rarity
    $eatt = [int]$gachaState.encounter.attempts_left
    $einfo = Lookup-Poke $dex $eid
    if ($einfo) {
        $eType = $einfo.type1
        $eGlyph = if ($tGlyph.ContainsKey($eType)) { Color $tCol[$eType] "$($tGlyph[$eType])" } else { '?' }
        $eName = $einfo.name_zh
        # Color the WILD! tag by rarity so HR pops as legendary
        $tagCol = if ($erty -eq 'HR') { '1;38;5;213' } elseif ($erty -eq 'R') { '1;38;5;220' } elseif ($erty -eq 'U') { '1;38;5;82' } else { '1;38;5;245' }
        $wildText = if ($erty -eq 'HR') { 'LEGENDARY' } else { 'WILD' }
        $encBanner = "  $(Color $tagCol "[$wildText !] ") $eGlyph #$('{0:D3}' -f $eid) $(Color '1;38;5;255' $eName) $(Dim "[$erty]")  $(Color '38;5;245' "$eatt attempts left")  $(Dim '/gacha catch')"
    }
}

# --- Buddy dialog: occasional zh-TW quip keyed by buddy.type1 ---
# Catalog of 3-4 lines per type. Picked deterministically from session_id+type
# so within a session the line is stable; new session may roll a new one. Shown
# only 50% of the time (also deterministic from session_id) — keeps it
# occasional instead of every-render chatty.
$BuddyLines = @{
    'normal'   = @('一切如常。', '今天天氣不錯。', '陪你工作中～', '想做點什麼但又懶得動')
    'fire'     = @('🔥 燃燒吧！', '今天的火焰特別旺。', '不要靠太近，會燙到。', '咳，剛剛打了一個熱噴嚏')
    'water'    = @('水量充沛，狀態 OK。', '想去衝浪。', '今天的水很清涼。', '~~~ 飄飄的')
    'electric' = @('⚡ 又是充滿電的一天！', '靜電有點刺刺的⚡', '你的鍵盤聽起來像在打字呢⚡', '今天的雷雲很有食慾。')
    'grass'    = @('光合作用中... ☘', '土壤的味道真好聞。', '感覺今天會發芽。', '葉子有點蜷起來了')
    'ice'      = @('外面好暖，我不喜歡。', '今天我發了冰光線。', '結霜的觸感很棒。', '不要靠太近，會冷。')
    'fighting' = @('💪 訓練時間到！', '想單挑嗎？', '今天的拳頭特別硬。', '出招要快、要狠、要準。')
    'poison'   = @('別碰我喔～', '今天的毒液濃度剛剛好', '聞起來像紫色', '我的觸手有自己的想法')
    'ground'   = @('土壤鬆軟，挖洞容易。', '今天的地震只有 1 級', '泥土的味道真好', '腳下的塵土告訴我...')
    'flying'   = @('飛行中... 風很大', '想看雲嗎？', '從上面看下來，你超小', '今天的天空很藍')
    'psychic'  = @('我感應到... 你在改 code 嗎', '心靈感應很累', '腦袋有點抽抽的', '預感今天會打贏')
    'bug'      = @('觸角顫動中', '光線好刺眼', '今天我絲很多', '蟲蟲危機！')
    'rock'     = @('硬硬的，沒事', '岩石不會說話。', '今天的礦物心情不錯', '靜止中...')
    'ghost'    = @('呵呵呵... 👻', '你看得到我嗎', '影子不見了！', '今天適合鬧鬼')
    'dragon'   = @('龍威壓，發動！', '今天感覺特別強', '想噴一下嗎', '神龍見首不見尾')
}

$buddyBanner = $null
if ($gachaState -and $gachaState.buddy -and $gachaState.buddy.id) {
    $btype = [string]$gachaState.buddy.type1
    if ($BuddyLines.ContainsKey($btype) -and -not [string]::IsNullOrEmpty($sessionId)) {
        # Decoupled hashes so the 50% gate doesn't bias which lines get picked.
        # Earlier bug: same hash for both meant gate(h%2==0) constrained h to
        # even, and pick(h%4) on even h only ever yielded {0, 2} — half the
        # lines were unreachable. Now: gate uses high bits, pick uses low bits.
        $h = 0
        foreach ($ch in $sessionId.ToCharArray()) { $h = ($h * 31 + [int]$ch) -band 0x7fffffff }
        $gateBit = ($h -shr 16) -band 1
        if ($gateBit -eq 0) {
            $lines = $BuddyLines[$btype]
            $idx = $h % $lines.Count
            $nick = $null
            if ($gachaState.buddy.PSObject.Properties.Name -contains 'nickname' -and $gachaState.buddy.nickname) {
                $nick = [string]$gachaState.buddy.nickname
            }
            $bname = if ($nick) { $nick } else { $gachaState.buddy.name_zh }
            $bcol = if ($tCol.ContainsKey($btype)) { $tCol[$btype] } else { '38;5;255' }
            $buddyBanner = "  $(Color $bcol $bname): $(Color '38;5;255' $lines[$idx])"
        }
    }
}

# --- Daily theme banner (above outer frame): rotates by weekday, mirrors $DailyThemes in gacha.ps1 ---
$DailyThemes = @{
    'Monday'    = @{ name='蟲蟲星期一'; type='bug';      glyph=[char]0x2723 }
    'Tuesday'   = @{ name='火紅星期二'; type='fire';     glyph=[char]0x2726 }
    'Wednesday' = @{ name='水流星期三'; type='water';    glyph=[char]0x25C8 }
    'Thursday'  = @{ name='雷光星期四'; type='electric'; glyph=[char]0x26A1 }
    'Friday'    = @{ name='綠葉星期五'; type='grass';    glyph=[char]0x2740 }
    'Saturday'  = @{ name='超能星期六'; type='psychic';  glyph=[char]0x2736 }
    'Sunday'    = @{ name='神龍星期日'; type='dragon';   glyph=[char]0x272F }
}
$themeBanner = $null
$dowKey = (Get-Date).DayOfWeek.ToString()
if ($DailyThemes.ContainsKey($dowKey)) {
    $dt = $DailyThemes[$dowKey]
    $dtCol = if ($tCol.ContainsKey($dt.type)) { $tCol[$dt.type] } else { '38;5;220' }
    $themeBanner = "  $(Color '38;5;220' 'EVENT') $(Color $dtCol "$($dt.glyph)") $(Color '1;38;5;220' $dt.name) $(Dim '— 30% pull 重抽到') $(Color $dtCol $dt.type.ToUpper())"
}

# --- Output ---
if ($buddyBanner) { "$RESET_EOL$buddyBanner$RESET_EOL" }
if ($themeBanner) { "$RESET_EOL$themeBanner$RESET_EOL" }
if ($encBanner)   { "$RESET_EOL$encBanner$RESET_EOL" }
"$RESET_EOL$oTop$RESET_EOL"
for ($v = 0; $v -lt $V_PAD; $v++) { "$RESET_EOL$oBlank$RESET_EOL" }
foreach ($row in $innerRows) {
    $rVw = Get-VisibleWidth $row
    $rPad = ' ' * [Math]::Max(0, $innerContentW - $rVw)
    $line = (Color $outerCol $T_VT) + (' ' * $H_PAD) + $row + $rPad + (' ' * $H_PAD) + (Color $outerCol $T_VT)
    "$RESET_EOL$line$RESET_EOL"
}
for ($v = 0; $v -lt $V_PAD; $v++) { "$RESET_EOL$oBlank$RESET_EOL" }
"$RESET_EOL$oBot$RESET_EOL"
