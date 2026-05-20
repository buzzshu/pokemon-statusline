#Requires -Version 5.1
# Pokemon Gacha engine for Claude Code status line buddy system.
# Subcommands: pull | pulls N | buddy ID | evolve ID | trade | dex | status | help
# Pure ASCII source; Unicode glyphs built at runtime via [char]0xXXXX.

param(
    [Parameter(Position=0)][string]$Cmd = 'status',
    [Parameter(Position=1)][string]$Arg = '',
    [Parameter(Position=2)][string]$Arg2 = '',
    [Parameter(Position=3)][string]$Arg3 = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# --- Paths ---
# Dex/sprites travel with the script (works for both dev <repo>/.claude/scripts and deployed ~/.claude/scripts).
# State is GLOBAL at ~/.claude/gacha-state.json so dev + deployed share one collection.
$ClaudeDir = Split-Path -Parent $PSScriptRoot
$StateFile = Join-Path $env:USERPROFILE '.claude\gacha-state.json'
$DexFile = Join-Path $ClaudeDir 'pokemon-dex.json'
$StatsFile = Join-Path $ClaudeDir 'pokemon-stats.json'

# --- Unicode glyphs (BMP single-char, built at runtime to keep file ASCII) ---
$DOT      = [char]0x00B7   # middle dot
$ARROW    = [char]0x2192   # right arrow
$SPARKLE  = [char]0x2728   # sparkles (emoji-ish, BMP)
$TypeGlyph = @{
    'normal'   = [char]0x2606
    'fire'     = [char]0x2726
    'water'    = [char]0x25C8
    'electric' = [char]0x26A1
    'grass'    = [char]0x2740
    'ice'      = [char]0x2744
    'fighting' = [char]0x2694
    'poison'   = [char]0x2620
    'ground'   = [char]0x2B23
    'flying'   = [char]0x27A4
    'psychic'  = [char]0x2736
    'bug'      = [char]0x2723
    'rock'     = [char]0x2B22
    'ghost'    = [char]0x263D
    'dragon'   = [char]0x272F
}

$TypeColor = @{
    'normal'   = '38;5;250'
    'fire'     = '38;5;202'
    'water'    = '38;5;39'
    'electric' = '38;5;226'
    'grass'    = '38;5;46'
    'ice'      = '38;5;87'
    'fighting' = '38;5;208'
    'poison'   = '38;5;141'
    'ground'   = '38;5;179'
    'flying'   = '38;5;153'
    'psychic'  = '38;5;213'
    'bug'      = '38;5;154'
    'rock'     = '38;5;138'
    'ghost'    = '38;5;105'
    'dragon'   = '38;5;199'
}

$RarityColor = @{ 'C' = '38;5;245'; 'U' = '38;5;82'; 'R' = '38;5;220'; 'HR' = '38;5;213' }

# --- Level formula: triangular EXP curve (gentle quadratic — exponential-ish, not crazy) ---
# thresh(L) = L*(L-1)/2 exp to REACH level L. Inverse: level = floor(sqrt(2*exp)) + 1.
#   L1=0, L2=1, L3=3, L4=6, L5=10, L10=45, L16=120, L25=300, L36=630, L55=1485
# +1 exp per session, so first 5 levels go fast; mid-game (L16) takes ~120 sessions
# of dedicated buddying, L25+ is real commitment.
function Get-Level([int]$exp) {
    if ($exp -lt 0) { return 1 }
    return [int][Math]::Floor([Math]::Sqrt(2.0 * $exp)) + 1
}
function Get-ExpForLevel([int]$lvl) {
    if ($lvl -le 1) { return 0 }
    return [int]($lvl * ($lvl - 1) / 2)
}

$ESC = [char]27
function Color([string]$code, [string]$text) { "$ESC[${code}m$text$ESC[0m" }
function Bold([string]$text) { "$ESC[1m$text$ESC[0m" }
function Dim([string]$text) { "$ESC[2m$text$ESC[0m" }
function Gold([string]$text) { "$ESC[1;38;5;220m$text$ESC[0m" }
function Print([string]$line = '') {
    [Console]::WriteLine($line)
    [Console]::Out.Flush()  # force unbuffered for reveal animation
}

# Visible-width counter: strips ANSI, doubles CJK / wide-emoji BMP chars.
$WIDE_EMOJI_BMP = @{}
@(0x2614,0x2615,0x26A1,0x26AA,0x26AB,0x26BD,0x26BE,0x26C4,0x26C5,0x26CE,0x26D4,
  0x26EA,0x26F2,0x26F3,0x26F5,0x26FA,0x26FD,0x2705,0x270A,0x270B,0x2728,
  0x274C,0x274E,0x2753,0x2754,0x2755,0x2757,0x2795,0x2796,0x2797,0x27B0,0x27BF
) | ForEach-Object { $WIDE_EMOJI_BMP[$_] = $true }
function Get-VisibleWidth([string]$s) {
    $stripped = $s -replace "$ESC\[[\d;]*[mK]", ''
    $w = 0
    foreach ($ch in $stripped.ToCharArray()) {
        $c = [int]$ch
        if ($WIDE_EMOJI_BMP.ContainsKey($c) -or
            ($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0x303E) -or
            ($c -ge 0x3041 -and $c -le 0x33FF) -or
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or
            ($c -ge 0xA000 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}
function Format-RarityBadge([string]$rarity, [bool]$shiny) {
    $body = if ($shiny) { "[$SPARKLE$rarity$SPARKLE]" } else { "[$rarity]" }
    if ($shiny) { return Gold $body }
    return Color $RarityColor[$rarity] $body
}

# --- ConvertFrom-Json -> mutable hashtable (PS 5.1 lacks -AsHashtable) ---
function ConvertTo-Ht($o) {
    if ($null -eq $o) { return $null }
    # Primitive short-circuit: PSObject auto-wraps pipeline items, so Int32/etc.
    # would falsely match `-is [pscustomobject]` if checked after. Check primitives first.
    if ($o -is [string] -or $o -is [bool] -or $o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal] -or $o -is [datetime]) {
        return $o
    }
    if ($o -is [System.Array]) {
        # Use foreach (not pipeline) to avoid PSObject auto-wrapping of items.
        $arr = @()
        foreach ($item in $o) { $arr += , (ConvertTo-Ht $item) }
        return , $arr  # leading comma prevents PS from unwrapping single-element array on return
    }
    if ($o -is [pscustomobject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Ht $p.Value }
        return $h
    }
    return $o
}

# --- Load Pokedex ---
$DexRaw = Get-Content $DexFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Dex = @{}
$ByRarity = @{ 'C' = @(); 'U' = @(); 'R' = @(); 'HR' = @() }
foreach ($p in $DexRaw.pokemon) {
    $entry = @{
        id           = [int]$p[0]
        name_en      = [string]$p[1]
        name_zh      = [string]$p[2]
        type1        = [string]$p[3]
        type2        = if ($p[4]) { [string]$p[4] } else { $null }
        stage        = [int]$p[5]
        evolves_to   = if ($null -ne $p[6]) { [int]$p[6] } else { $null }
        rarity       = [string]$p[7]
        pullable     = [bool]$p[8]
        evolve_level = if ($null -ne $p[9]) { [int]$p[9] } else { $null }
    }
    $Dex[[string]$entry.id] = $entry
    # Pull pool only contains pullable=true pokemon (stage 0). Evolved forms
    # (stage 1+) are dex-display-only and obtained via /gacha evolve.
    if ($entry.pullable) { $ByRarity[$entry.rarity] += , [int]$entry.id }
}

# --- Type effectiveness chart (Gen 1 canonical intent) ---
# Multiplier when atkType is used vs defType. Missing entry = 1.0x.
# Stack defType1 + defType2 multiplicatively (0 × anything = 0 = immunity).
$TypeChart = @{
    'normal'   = @{ 'rock'=0.5; 'ghost'=0 }
    'fire'     = @{ 'fire'=0.5; 'water'=0.5; 'grass'=2; 'ice'=2; 'bug'=2; 'rock'=0.5; 'dragon'=0.5 }
    'water'    = @{ 'fire'=2; 'water'=0.5; 'grass'=0.5; 'ground'=2; 'rock'=2; 'dragon'=0.5 }
    'electric' = @{ 'water'=2; 'electric'=0.5; 'grass'=0.5; 'ground'=0; 'flying'=2; 'dragon'=0.5 }
    'grass'    = @{ 'fire'=0.5; 'water'=2; 'grass'=0.5; 'poison'=0.5; 'ground'=2; 'flying'=0.5; 'bug'=0.5; 'rock'=2; 'dragon'=0.5 }
    'ice'      = @{ 'water'=0.5; 'grass'=2; 'ice'=0.5; 'ground'=2; 'flying'=2; 'dragon'=2 }
    'fighting' = @{ 'normal'=2; 'ice'=2; 'poison'=0.5; 'flying'=0.5; 'psychic'=0.5; 'bug'=0.5; 'rock'=2; 'ghost'=0 }
    'poison'   = @{ 'grass'=2; 'poison'=0.5; 'ground'=0.5; 'bug'=2; 'rock'=0.5; 'ghost'=0.5 }
    'ground'   = @{ 'fire'=2; 'electric'=2; 'grass'=0.5; 'poison'=2; 'flying'=0; 'bug'=0.5; 'rock'=2 }
    'flying'   = @{ 'electric'=0.5; 'grass'=2; 'fighting'=2; 'bug'=2; 'rock'=0.5 }
    'psychic'  = @{ 'fighting'=2; 'poison'=2; 'psychic'=0.5 }
    'bug'      = @{ 'fire'=0.5; 'grass'=2; 'fighting'=0.5; 'poison'=2; 'flying'=0.5; 'psychic'=2; 'ghost'=0.5 }
    'rock'     = @{ 'fire'=2; 'ice'=2; 'fighting'=0.5; 'ground'=0.5; 'flying'=2; 'bug'=2 }
    'ghost'    = @{ 'normal'=0; 'psychic'=2; 'ghost'=2 }
    'dragon'   = @{ 'dragon'=2 }
}
# Gen 1 move category by type: special = "energy" types (Fire/Water/Grass/Electric/Ice/Psychic/Dragon),
# physical = everything else. Determines atk/def stat used in damage calc.
$SpecialTypes = @('fire','water','grass','electric','ice','psychic','dragon')

# --- 8 Gen 1 gym leaders (canonical RBY) ---
$GymLeaders = @(
    @{ idx=1; city='灰色道館'; leader_name='小剛';   poke_id=95;  level=14; badge='灰色徽章' }    # Brock - Onix
    @{ idx=2; city='華藍道館'; leader_name='小霞';   poke_id=121; level=21; badge='藍色徽章' }    # Misty - Starmie
    @{ idx=3; city='枯葉道館'; leader_name='馬志士'; poke_id=26;  level=24; badge='雷光徽章' }    # Surge - Raichu
    @{ idx=4; city='玉虹道館'; leader_name='莉佳';   poke_id=45;  level=29; badge='彩虹徽章' }    # Erika - Vileplume
    @{ idx=5; city='金黃道館'; leader_name='沙奈';   poke_id=65;  level=43; badge='金色徽章' }    # Sabrina - Alakazam
    @{ idx=6; city='淺紅道館'; leader_name='阿桔';   poke_id=110; level=43; badge='沼澤徽章' }    # Koga - Weezing
    @{ idx=7; city='紅蓮道館'; leader_name='夏伯';   poke_id=59;  level=47; badge='火紅徽章' }    # Blaine - Arcanine
    @{ idx=8; city='常磐道館'; leader_name='阪木';   poke_id=112; level=50; badge='地球徽章' }    # Giovanni - Rhydon
)

# --- Achievement definitions (20 milestones) ---
# Each entry: slug (unique key in state.achievements), name_zh (display), desc (hint),
# kind (group for display ordering).
$Achievements = @(
    @{ slug='first-pull';     name_zh='初次見面';   desc='完成你的第一次 pull';                       kind='pull' }
    @{ slug='pull-10';        name_zh='十抽達人';   desc='累計 10 次 pull';                          kind='pull' }
    @{ slug='pull-100';       name_zh='百抽達人';   desc='累計 100 次 pull';                         kind='pull' }
    @{ slug='first-hr';       name_zh='首見傳說';   desc='收集到第一隻 HR (神獸)';                   kind='collection' }
    @{ slug='first-shiny';    name_zh='首見閃光';   desc='抓到第一隻 shiny 寶可夢';                  kind='collection' }
    @{ slug='shiny-5';        name_zh='閃閃發亮';   desc='累計 5 隻 shiny';                          kind='collection' }
    @{ slug='dex-25';         name_zh='新手訓練家'; desc='圖鑑完成度 25% (38/151)';                  kind='dex' }
    @{ slug='dex-50';         name_zh='資深訓練家'; desc='圖鑑完成度 50% (76/151)';                  kind='dex' }
    @{ slug='dex-100';        name_zh='大師訓練家'; desc='圖鑑完成度 100% (151/151)';                kind='dex' }
    @{ slug='all-starters';   name_zh='御三家齊全'; desc='同時擁有妙蛙種子 / 小火龍 / 傑尼龜';       kind='collection' }
    @{ slug='all-fossils';    name_zh='化石獵人';   desc='擁有菊石獸 / 化石盔 / 化石翼龍';           kind='collection' }
    @{ slug='all-legendary';  name_zh='神話收藏家'; desc='集滿急凍鳥 / 閃電鳥 / 火焰鳥 / 超夢 / 夢幻'; kind='collection' }
    @{ slug='first-evolve';   name_zh='初次進化';   desc='第一次 /gacha evolve 成功';                kind='train' }
    @{ slug='buddy-l25';      name_zh='培育達人';   desc='Buddy 練到 LV. 25 (exp 300)';              kind='train' }
    @{ slug='buddy-l50';      name_zh='培育大師';   desc='Buddy 練到 LV. 50 (exp 1225)';             kind='train' }
    @{ slug='triple-clone';   name_zh='複製戰隊';   desc='Team 同時有 3 隻同 dex 寶可夢 [A][B][C]';  kind='team' }
    @{ slug='first-trade';    name_zh='首次交易';   desc='第一次 /gacha trade 完成';                  kind='train' }
    @{ slug='gym-1';          name_zh='道館初勝';   desc='打贏第一個道館';                            kind='battle' }
    @{ slug='gym-all';        name_zh='全道館征服'; desc='打贏全部 8 個 Gen 1 道館';                  kind='battle' }
    @{ slug='streak-10';      name_zh='戰鬥不敗';   desc='戰鬥最高連勝 10 場';                        kind='battle' }
)

function Count-Caught($state) {
    $n = 0
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught) { $n++ }
    }
    return $n
}
function Has-CaughtEver($state, [int]$id) {
    $k = [string]$id
    if (-not $state.owned.Contains($k)) { return $false }
    return ($null -ne $state.owned[$k].first_caught)
}
function Check-AnyOwnedHR($state) {
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught -and $Dex.ContainsKey($k) -and $Dex[$k].rarity -eq 'HR') { return $true }
    }
    return $false
}
function Check-TripleClone($state) {
    if (-not $state.team) { return $false }
    $counts = @{}
    foreach ($t in $state.team) {
        $k = [string][int]$t
        if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 } else { $counts[$k] = 1 }
    }
    foreach ($k in $counts.Keys) { if ($counts[$k] -ge 3) { return $true } }
    return $false
}
function Test-Achievement-Earned($state, [string]$slug) {
    switch ($slug) {
        'first-pull'    { return ([int]$state.stats.pulls_total -ge 1) }
        'pull-10'       { return ([int]$state.stats.pulls_total -ge 10) }
        'pull-100'      { return ([int]$state.stats.pulls_total -ge 100) }
        'first-hr'      { return (Check-AnyOwnedHR $state) }
        'first-shiny'   { return ([int]$state.stats.shinies_total -ge 1) }
        'shiny-5'       { return ([int]$state.stats.shinies_total -ge 5) }
        'dex-25'        { return ((Count-Caught $state) -ge 38) }
        'dex-50'        { return ((Count-Caught $state) -ge 76) }
        'dex-100'       { return ((Count-Caught $state) -ge 151) }
        'all-starters'  { return ((Has-CaughtEver $state 1) -and (Has-CaughtEver $state 4) -and (Has-CaughtEver $state 7)) }
        'all-fossils'   { return ((Has-CaughtEver $state 138) -and (Has-CaughtEver $state 140) -and (Has-CaughtEver $state 142)) }
        'all-legendary' { return ((Has-CaughtEver $state 144) -and (Has-CaughtEver $state 145) -and (Has-CaughtEver $state 146) -and (Has-CaughtEver $state 150) -and (Has-CaughtEver $state 151)) }
        'first-evolve'  { return ([int]$state.stats.evolutions_done -ge 1) }
        'buddy-l25'     { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 25) }
        'buddy-l50'     { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 50) }
        'triple-clone'  { return (Check-TripleClone $state) }
        'first-trade'   { return ([int]$state.stats.trades_done -ge 1) }
        'gym-1'         { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 1) }
        'gym-all'       { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 8) }
        'streak-10'     { return ([int]$state.battle_streak_best -ge 10) }
    }
    return $false
}

# Returns array of slugs newly earned this call. Mutates $state.achievements.
function Check-Achievements($state) {
    if (-not $state.achievements) { $state.achievements = [ordered]@{} }
    $newly = @()
    foreach ($a in $Achievements) {
        $slug = [string]$a.slug
        if ($state.achievements.Contains($slug)) { continue }
        if (Test-Achievement-Earned $state $slug) {
            $state.achievements[$slug] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            $newly += $slug
        }
    }
    return ,$newly
}

function Show-Achievements($state) {
    if (-not $state.achievements) { $state.achievements = [ordered]@{} }
    $earnedCount = $state.achievements.Count
    $total = $Achievements.Count
    Print ''
    Print (Bold "=== Achievements ($earnedCount/$total) ===")
    Print ''
    $kindOrder = @('pull','collection','dex','train','team','battle')
    foreach ($k in $kindOrder) {
        $list = $Achievements | Where-Object { $_.kind -eq $k }
        if ($list.Count -eq 0) { continue }
        Print "  $(Color '38;5;111' "[$($k.ToUpper())]")"
        foreach ($a in $list) {
            $slug = [string]$a.slug
            if ($state.achievements.Contains($slug)) {
                $earnedAt = [string]$state.achievements[$slug]
                $datePart = if ($earnedAt.Length -ge 10) { $earnedAt.Substring(0, 10) } else { $earnedAt }
                Print "    $(Color '1;38;5;82' '✓') $(Color '1;38;5;255' $a.name_zh) $(Dim "(earned $datePart)")"
            } else {
                Print "    $(Color '38;5;238' '☐') $(Color '38;5;245' $a.name_zh) $(Dim "— $($a.desc)")"
            }
        }
        Print ''
    }
}

# --- Daily themed pull events ---
# Day-of-week → boosted type. 30% of rolls within a rarity get re-rolled from the
# themed type pool (if it has any pullable members in that rarity).
$DailyThemes = @{
    'Monday'    = @{ name='蟲蟲星期一';   type='bug';      glyph_idx=0x2723 }
    'Tuesday'   = @{ name='火紅星期二';   type='fire';     glyph_idx=0x2726 }
    'Wednesday' = @{ name='水流星期三';   type='water';    glyph_idx=0x25C8 }
    'Thursday'  = @{ name='雷光星期四';   type='electric'; glyph_idx=0x26A1 }
    'Friday'    = @{ name='綠葉星期五';   type='grass';    glyph_idx=0x2740 }
    'Saturday'  = @{ name='超能星期六';   type='psychic';  glyph_idx=0x2736 }
    'Sunday'    = @{ name='神龍星期日';   type='dragon';   glyph_idx=0x272F }
}
function Get-DailyTheme {
    $dow = (Get-Date).DayOfWeek.ToString()
    if ($DailyThemes.ContainsKey($dow)) {
        $t = $DailyThemes[$dow]
        return @{ day=$dow; name=$t.name; type=$t.type; glyph=[char]$t.glyph_idx }
    }
    return $null
}
function Get-RandomIdInRarity-Themed([string]$rarity) {
    $theme = Get-DailyTheme
    if ($theme) {
        # Build themed sub-pool: pullable + matching type within this rarity
        $themedIds = @()
        foreach ($id in $ByRarity[$rarity]) {
            $p = $Dex[[string]$id]
            if ($p.type1 -eq $theme.type -or $p.type2 -eq $theme.type) { $themedIds += [int]$id }
        }
        if ($themedIds.Count -gt 0 -and (Get-Random -Maximum 100) -lt 30) {
            return [int]$themedIds[(Get-Random -Maximum $themedIds.Count)]
        }
    }
    return Get-RandomIdInRarity $rarity
}

function Show-Event {
    $theme = Get-DailyTheme
    Print ''
    Print (Bold "=== Daily Event ===")
    Print ''
    if (-not $theme) {
        Print '  No event today.'
        Print ''
        return
    }
    $glyph = Color $TypeColor[$theme.type] "$($theme.glyph)"
    Print "  $glyph $(Color '1;38;5;220' $theme.name)  $(Dim "($($theme.day))")"
    Print "  $(Dim "30% 機率將 pull 結果重抽到") $(Color $TypeColor[$theme.type] $theme.type.ToUpper())$(Dim " 屬性的同 rarity 寶可夢。")"
    $next = [DateTime]::Now.Date.AddDays(1)
    $rem = $next - [DateTime]::Now
    Print "  $(Dim "下一輪：$($next.ToString('yyyy-MM-dd')) (剩 $([Math]::Floor($rem.TotalHours))h$($rem.Minutes)m)")"
    Print ''
}

# --- Base stats (Gen 1, Gen 2+ split convention) keyed by id ---
$Stats = @{}
if (Test-Path $StatsFile) {
    $StatsRaw = Get-Content $StatsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($s in $StatsRaw.stats) {
        $Stats[[string]([int]$s[0])] = @{
            hp  = [int]$s[1]; atk = [int]$s[2]; def = [int]$s[3]
            spa = [int]$s[4]; spd = [int]$s[5]; spe = [int]$s[6]
            bst = [int]$s[1] + [int]$s[2] + [int]$s[3] + [int]$s[4] + [int]$s[5] + [int]$s[6]
        }
    }
}

# --- State load/save ---
function Get-DefaultState {
    return [ordered]@{
        version            = 1
        coins              = 0
        cost_usd_processed = 0.0
        last_session_id    = $null
        sessions_count     = 0
        owned              = [ordered]@{}
        buddy              = $null
        team               = @()
        last_pull          = $null
        stats              = [ordered]@{
            pulls_total      = 0
            shinies_total    = 0
            evolutions_done  = 0
            trades_done      = 0
        }
    }
}

function Load-State {
    $state = $null
    if (Test-Path $StateFile) {
        try {
            $raw = Get-Content $StateFile -Raw -Encoding UTF8
            if ($raw.Trim().Length -gt 0) {
                $state = ConvertTo-Ht ($raw | ConvertFrom-Json)
            }
        } catch {
            Write-Warning "State corrupt; starting fresh"
            # Preserve the broken file so it can be inspected / restored
            try {
                $ts = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                $corruptDir = Join-Path (Split-Path -Parent $StateFile) 'backups'
                if (-not (Test-Path $corruptDir)) { New-Item -ItemType Directory -Path $corruptDir -Force | Out-Null }
                Copy-Item -Path $StateFile -Destination (Join-Path $corruptDir "gacha-state.corrupt.$ts.json") -Force
            } catch {}
        }
    }
    if ($null -eq $state) { $state = Get-DefaultState }
    # Backward-compat: ensure team field exists and seeded from buddy if legacy state
    if (-not $state.Contains('team') -or $null -eq $state.team) { $state.team = @() }
    if ($state.team.Count -eq 0 -and $state.buddy -and $state.buddy.id) {
        $state.team = @([int]$state.buddy.id)
    }
    # Batch 2 schema additions
    if (-not $state.Contains('gyms_beaten') -or $null -eq $state.gyms_beaten) { $state.gyms_beaten = @() }
    # Batch 3 schema additions
    if (-not $state.Contains('achievements') -or $null -eq $state.achievements) { $state.achievements = [ordered]@{} }
    if (-not $state.Contains('battle_streak_current')) { $state.battle_streak_current = 0 }
    if (-not $state.Contains('battle_streak_best')) { $state.battle_streak_best = 0 }
    return $state
}

function Save-State($state) {
    $dir = Split-Path -Parent $StateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Keep a backup of the previous state so a future parse-failure reset doesn't
    # wipe progress. backups/ keeps the last 5 .bak files (timestamped).
    if (Test-Path $StateFile) {
        $backDir = Join-Path $dir 'backups'
        if (-not (Test-Path $backDir)) { New-Item -ItemType Directory -Path $backDir -Force | Out-Null }
        $ts = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $backFile = Join-Path $backDir "gacha-state.$ts.bak.json"
        try { Copy-Item -Path $StateFile -Destination $backFile -Force } catch {}
        # Trim to last 5
        $olds = @(Get-ChildItem -Path $backDir -Filter 'gacha-state.*.bak.json' | Sort-Object Name -Descending)
        if ($olds.Count -gt 5) {
            $olds[5..($olds.Count - 1)] | ForEach-Object { try { Remove-Item -Path $_.FullName -Force } catch {} }
        }
    }
    $state | ConvertTo-Json -Depth 12 | Out-File -FilePath $StateFile -Encoding utf8 -Force
}

# --- Owned-collection helpers ---
function Get-OwnedCount($state, [int]$id) {
    $k = [string]$id
    if ($state.owned.Contains($k)) { return [int]$state.owned[$k].count }
    return 0
}
function Get-OwnedShinyCount($state, [int]$id) {
    $k = [string]$id
    if ($state.owned.Contains($k)) { return [int]$state.owned[$k].shiny_count }
    return 0
}
function Add-Owned($state, [int]$id, [bool]$shiny) {
    $k = [string]$id
    if (-not $state.owned.Contains($k)) {
        $state.owned[$k] = [ordered]@{
            count         = 0
            shiny_count   = 0
            first_caught  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    $state.owned[$k].count = [int]$state.owned[$k].count + 1
    if ($shiny) { $state.owned[$k].shiny_count = [int]$state.owned[$k].shiny_count + 1 }
}
function Remove-Owned($state, [int]$id, [int]$n = 1) {
    $k = [string]$id
    if (-not $state.owned.Contains($k)) { return $false }
    $cur = [int]$state.owned[$k].count
    if ($cur -lt $n) { return $false }
    $state.owned[$k].count = $cur - $n
    return $true
}

# --- Random helpers ---
function Get-RandomRarity {
    # HR (legendaries) REMOVED from pull pool — they only spawn via session-trigger
    # encounters now. R absorbs the freed 0.5% so the curve stays smooth.
    # Tighter post-mid-game tuning: dex completion is slow so single C/U rolls
    # naturally start producing dupes; R should feel genuinely rare per pull.
    $r = Get-Random -Maximum 1000
    if ($r -lt 30)  { return 'R'  }   # 0-29     = R  (3%)
    if ($r -lt 100) { return 'U'  }   # 30-99    = U  (7%)
    return 'C'                        # 100-999  = C  (90%)
}

function Get-EncounterRarity {
    # Encounter pool (1% trigger per new session): pyramid distribution
    # C 60 / U 25 / R 12 / HR 3 — HR encounters average ~3300 sessions apart.
    $r = Get-Random -Maximum 100
    if ($r -lt 3)  { return 'HR' }   # 0-2      = HR (3%)
    if ($r -lt 15) { return 'R'  }   # 3-14     = R  (12%)
    if ($r -lt 40) { return 'U'  }   # 15-39    = U  (25%)
    return 'C'                       # 40-99    = C  (60%)
}

# Per-id base catch rates. HR (legendaries) get canonical-flavored difficulty;
# non-HR uses a flat rate by rarity tier. Each /gacha catch attempt rolls this.
$LegendaryCatchRate = @{
    144 = 0.20   # Articuno
    145 = 0.20   # Zapdos
    146 = 0.20   # Moltres
    150 = 0.10   # Mewtwo (hardest, canonical)
    151 = 0.15   # Mew
}
function Get-CatchRate([int]$id, [string]$rarity) {
    if ($rarity -eq 'HR' -and $LegendaryCatchRate.ContainsKey($id)) {
        return [double]$LegendaryCatchRate[$id]
    }
    switch ($rarity) {
        'C'  { return 0.80 }
        'U'  { return 0.50 }
        'R'  { return 0.30 }
        'HR' { return 0.15 }   # fallback if a future HR isn't in the legendary table
        default { return 0.50 }
    }
}
function Get-RandomIdInRarity([string]$rarity) {
    $ids = $ByRarity[$rarity]
    if (-not $ids -or $ids.Count -eq 0) { return $null }
    return [int]$ids[(Get-Random -Maximum $ids.Count)]
}
function Roll-Shiny { return ((Get-Random -Maximum $DexRaw.shiny_rate_denominator) -eq 0) }

# --- Encounter system: HR-only catch channel + occasional non-HR spawns ---
# Session-triggered (1% per new session in statusline.ps1). User catches with
# /gacha catch (1 coin per attempt, 3 attempts total, then escapes).
function Spawn-Encounter($state) {
    if ($state.encounter -and [int]$state.encounter.id -gt 0) { return $false }   # one at a time
    $rarity = Get-EncounterRarity
    $id = Get-RandomIdInRarity $rarity
    if (-not $id) { return $false }
    $state.encounter = [ordered]@{
        id             = [int]$id
        rarity         = [string]$rarity
        attempts_left  = 3
        spawned_at_ep  = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }
    return $true
}

function Catch-Encounter($state) {
    if (-not $state.encounter -or -not $state.encounter.id) {
        Print (Color '38;5;196' "No wild pokemon to catch right now. Stay tuned — wild spawns trigger on new sessions (1% chance).")
        return
    }
    if ([int]$state.coins -lt 1) {
        Print (Color '38;5;196' "Need 1 coin to throw a Poke Ball; have $([int]$state.coins).")
        return
    }
    $id = [int]$state.encounter.id
    $rarity = [string]$state.encounter.rarity
    $poke = $Dex[[string]$id]
    if (-not $poke) {
        Print (Color '38;5;196' "Encounter data corrupt — clearing.")
        $state.encounter = $null
        return
    }
    $state.coins = [int]$state.coins - 1
    $rate = Get-CatchRate $id $rarity
    $roll = (Get-Random -Maximum 10000) / 10000.0
    $caught = ($roll -lt $rate)
    $glyph = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
    $name = Color '38;5;255' $poke.name_zh
    Print ''
    Print "  $(Dim '>> POKE BALL THROWN <<')"
    Start-Sleep -Milliseconds 400
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 350
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 350
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 400
    if ($caught) {
        $shiny = Roll-Shiny
        Add-Owned $state $id $shiny
        if ($shiny) { $state.stats.shinies_total = [int]$state.stats.shinies_total + 1 }
        $shinyTag = if ($shiny) { ' ' + (Gold "$SPARKLE SHINY $SPARKLE") } else { '' }
        $rarityBadge = Format-RarityBadge $rarity $shiny
        Print "  $(Color '1;38;5;82' 'GOTCHA!')  $rarityBadge  $glyph #$('{0:D3}' -f $id) $name$shinyTag"
        Print ''
        Print (Dim "  Catch rate was $([Math]::Round($rate * 100, 1))%. Coins: $([int]$state.coins).")
        $state.encounter = $null
    } else {
        $state.encounter.attempts_left = [int]$state.encounter.attempts_left - 1
        if ([int]$state.encounter.attempts_left -le 0) {
            Print "  $(Color '38;5;196' 'Oh no! The wild') $glyph #$('{0:D3}' -f $id) $name $(Color '38;5;196' 'broke free and fled!')"
            Print ''
            Print (Dim "  Catch rate was $([Math]::Round($rate * 100, 1))%. Coins: $([int]$state.coins).")
            $state.encounter = $null
        } else {
            Print "  $(Color '38;5;208' 'The pokemon broke free!')  $glyph #$('{0:D3}' -f $id) $name $(Dim "(attempts left: $([int]$state.encounter.attempts_left))")"
            Print ''
            Print (Dim "  Catch rate $([Math]::Round($rate * 100, 1))%. Try again: /gacha catch. Coins: $([int]$state.coins).")
        }
    }
    Print ''
}

# --- Card line formatter ---
function Format-CardLine([hashtable]$poke, [bool]$shiny, [string]$rarity, [bool]$isNew = $false) {
    $type = $poke.type1
    $glyph = $TypeGlyph[$type]
    $tc = $TypeColor[$type]
    $rc = $RarityColor[$rarity]
    $idStr = '{0:D3}' -f $poke.id
    $shinyMark = if ($shiny) { Gold ("*$SPARKLE*") } else { '   ' }
    $rarityBadge = Color $rc $rarity.PadRight(2)
    $glyphCol = Color $tc "$glyph"
    $nameCol = if ($shiny) { Gold $poke.name_zh } else { Color '38;5;255' $poke.name_zh }
    $enName = Dim "($($poke.name_en))"
    $newTag = if ($isNew) { Color '38;5;226' ' NEW' } else { '' }
    return "  $shinyMark $rarityBadge $glyphCol #$idStr $nameCol $enName$newTag"
}

# --- Subcommands ---

function Show-Status($state) {
    $coins = [int]$state.coins
    # caught = ever-caught (first_caught != null), matches dex/status-line semantics.
    $caught = 0
    $shinyTotal = 0
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught) { $caught++ }
        $shinyTotal += [int]$state.owned[$k].shiny_count
    }
    $dexTotal = 151
    $pct = [Math]::Round(($caught / [double]$dexTotal) * 100, 1)
    $pulls = [int]$state.stats.pulls_total
    $evols = [int]$state.stats.evolutions_done
    $trades = [int]$state.stats.trades_done

    Print ''
    Print (Bold "=== Pokemon Gacha ===")
    Print ''
    Print "  $(Bold (Color '38;5;220' "$coins coins"))"
    Print "  $(Dim "Dex $caught/$dexTotal ($pct%) $DOT Shiny $shinyTotal $DOT Pulls $pulls")"
    Print "  $(Dim "Evolutions $evols $DOT Trades $trades")"

    if ($state.buddy -and $state.buddy.id) {
        $bid = [int]$state.buddy.id
        $bp = $Dex[[string]$bid]
        $shiny = [bool]$state.buddy.shiny
        $exp = [int]$state.buddy.exp
        $lvl = Get-Level $exp
        $glyph = Color $TypeColor[$bp.type1] "$($TypeGlyph[$bp.type1])"
        $name = if ($shiny) { Gold $bp.name_zh } else { Color '38;5;255' $bp.name_zh }
        Print ''
        Print "  $(Dim 'Buddy:') $glyph #$('{0:D3}' -f $bp.id) $name LV. $lvl  $(Dim "(exp $exp)")"
    } else {
        Print ''
        Print "  $(Dim 'No buddy set. Use ``/gacha buddy <id>`` to pick one.')"
    }

    Print ''
    Print "  $(Dim "Commands: pull $DOT pulls N $DOT buddy ID $DOT evolve ID $DOT trade $DOT dex $DOT help")"
    Print ''
}

function Pull-Pack($state, [bool]$silent = $false) {
    if ([int]$state.coins -lt 1) {
        if (-not $silent) { Print (Color '38;5;196' "Not enough coins. Earn rate: `$1 USD session cost = 1 coin (cost-only mode).") }
        return @()
    }
    $state.coins = [int]$state.coins - 1
    $state.stats.pulls_total = [int]$state.stats.pulls_total + 1

    # 1 coin = 1 card. Rarity rolled by C 90% / U 7% / R 2.5% / HR 0.5%.
    # No floor (single card means no "guarantee >= uncommon"); luck of the draw.
    # Pool does not exclude already-owned — duplicates are expected and count toward
    # multi-copy team slots (you can field up to N copies of #X if you own N).
    $rar = Get-RandomRarity
    $id = Get-RandomIdInRarity-Themed $rar
    $sh = Roll-Shiny
    $cards = @(@{ id = $id; shiny = $sh; rarity = $rar })

    $newSet = @{}
    foreach ($c in $cards) {
        $wasZero = (Get-OwnedCount $state ([int]$c.id)) -eq 0
        Add-Owned $state ([int]$c.id) ([bool]$c.shiny)
        if ($c.shiny) { $state.stats.shinies_total = [int]$state.stats.shinies_total + 1 }
        if ($wasZero) { $newSet[[string]$c.id] = $true }
    }

    # Track most notable card from this pack (for status line "last pull" display)
    $rarityRank = @{ 'HR' = 4; 'R' = 3; 'U' = 2; 'C' = 1 }
    $bestCard = $null
    $bestScore = -1
    foreach ($c in $cards) {
        $score = ($rarityRank[$c.rarity] * 10) + $(if ($c.shiny) { 5 } else { 0 })
        if ($score -gt $bestScore) {
            $bestCard = $c
            $bestScore = $score
        }
    }
    if ($bestCard) {
        $bp = $Dex[[string]$bestCard.id]
        $state.last_pull = [ordered]@{
            id      = [int]$bestCard.id
            name_zh = $bp.name_zh
            type1   = $bp.type1
            rarity  = [string]$bestCard.rarity
            shiny   = [bool]$bestCard.shiny
            when    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        }
    }

    if (-not $silent) {
        $c = $cards[0]   # 1-card pack
        $poke = $Dex[[string]$c.id]

        Print ''
        Print (Bold "=== Pulling... ===")
        Print ''
        Start-Sleep -Milliseconds 400

        # Reveal sprite line-by-line (top-down) for suspense
        $spritePath = Join-Path $ClaudeDir "sprites\regular\$([int]$c.id).txt"
        if (Test-Path $spritePath) {
            Get-Content $spritePath -Encoding UTF8 | ForEach-Object {
                Print $_
                Start-Sleep -Milliseconds 90
            }
        }
        Start-Sleep -Milliseconds 300

        # Rarity badge (bottom-left) + name on same line
        $badge = Format-RarityBadge ([string]$c.rarity) ([bool]$c.shiny)
        $glyph = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
        $nameCol = if ($c.shiny) { Gold $poke.name_zh } else { Color '38;5;255' $poke.name_zh }
        $enName = "$ESC[2m($($poke.name_en))$ESC[0m"
        $newTag = if ($newSet[[string]$c.id]) { Color '38;5;226' ' NEW' } else { '' }
        Print "  $badge  $glyph #$('{0:D3}' -f $poke.id) $nameCol $enName$newTag"

        # Shiny fanfare
        if ($c.shiny) {
            Start-Sleep -Milliseconds 300
            Print ''
            Print (Gold "  *** $SPARKLE  SHINY!  $SPARKLE ***")
            Start-Sleep -Milliseconds 700
        }

        Print ''
        Print (Dim "  Coins: $([int]$state.coins) $DOT Pulls: $([int]$state.stats.pulls_total)")
        Print ''
    }
    return , $cards
}

function Pull-Multi($state, [int]$n) {
    if ($n -lt 1) { Print "N must be >= 1"; return }
    if ([int]$state.coins -lt $n) {
        Print (Color '38;5;196' "Need $n coins; have $([int]$state.coins).")
        return
    }
    Print ''
    Print (Bold "=== Multi-pull: $n packs ===")
    $allCards = @()
    for ($i = 1; $i -le $n; $i++) {
        $cards = Pull-Pack $state $true
        if ($null -eq $cards -or $cards.Count -eq 0) { break }
        $allCards += $cards
    }
    $shinies = @($allCards | Where-Object { $_.shiny })
    $hrs = @($allCards | Where-Object { $_.rarity -eq 'HR' })
    $rs  = @($allCards | Where-Object { $_.rarity -eq 'R' })
    $us  = @($allCards | Where-Object { $_.rarity -eq 'U' })
    Print ''
    Print (Dim "  Totals: $($allCards.Count) cards $DOT HR $($hrs.Count) $DOT R $($rs.Count) $DOT U $($us.Count) $DOT Shiny $($shinies.Count)")
    Print ''
    $notable = @($allCards | Where-Object { $_.rarity -in @('R','HR') -or $_.shiny })
    if ($notable.Count -gt 0) {
        Print "  Notable pulls:"
        foreach ($c in $notable) {
            $poke = $Dex[[string]$c.id]
            $line = Format-CardLine $poke ([bool]$c.shiny) ([string]$c.rarity)
            Print $line
        }
        Print ''
    }
    Print (Dim "  Coins remaining: $([int]$state.coins) $DOT Total pulls: $([int]$state.stats.pulls_total)")
    Print ''
}

function Set-Buddy($state, [int]$id) {
    if (-not $Dex.ContainsKey([string]$id)) {
        Print (Color '38;5;196' "Unknown pokemon id: $id")
        return
    }
    if ((Get-OwnedCount $state $id) -lt 1) {
        Print (Color '38;5;196' "You don't own $($Dex[[string]$id].name_zh) (#$id). Pull packs to catch one.")
        return
    }
    $shiny = (Get-OwnedShinyCount $state $id) -gt 0
    $poke = $Dex[[string]$id]

    # Sync team: place id at team[0] (leader). Keep existing members, max 6.
    if (-not $state.team) { $state.team = @() }
    $newTeam = @([int]$id)
    foreach ($x in $state.team) {
        if ([int]$x -ne [int]$id -and $newTeam.Count -lt 6) { $newTeam += [int]$x }
    }
    $state.team = $newTeam

    if ($null -eq $state.buddy -or [int]$state.buddy.id -ne $id) {
        $state.buddy = [ordered]@{
            id           = $id
            shiny        = $shiny
            exp          = 0
            nickname     = $null
            name_zh      = $poke.name_zh
            type1        = $poke.type1
            stage        = [int]$poke.stage
            evolves_to   = $poke.evolves_to
            evolve_level = $poke.evolve_level
        }
        $poke = $Dex[[string]$id]
        $glyph = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
        $name = if ($shiny) { Gold $poke.name_zh } else { Color '38;5;255' $poke.name_zh }
        $shinyTag = if ($shiny) { Gold ' (shiny)' } else { '' }
        Print ''
        Print "  Buddy set: $glyph #$('{0:D3}' -f $id) $name$shinyTag"
        Print ''
    } else {
        $state.buddy.shiny = $shiny
        Print "  Already your buddy."
    }
}

function Add-Team($state, [int]$id) {
    if (-not $Dex.ContainsKey([string]$id)) { Print (Color '38;5;196' "Unknown pokemon id: $id"); return }
    $owned = Get-OwnedCount $state $id
    if ($owned -lt 1) { Print (Color '38;5;196' "You don't own $($Dex[[string]$id].name_zh) (#$id)."); return }
    if (-not $state.team) { $state.team = @() }
    # Allow duplicates in team up to how many copies you actually own.
    $inTeam = @($state.team | Where-Object { [int]$_ -eq [int]$id }).Count
    if ($inTeam -ge $owned) {
        Print (Color '38;5;196' "You only own $owned x $($Dex[[string]$id].name_zh) (#$id) and all are already in your team.")
        return
    }
    if ($state.team.Count -ge 6) { Print (Color '38;5;196' "Team is full (6/6). Remove someone first: /gacha team remove <id>"); return }
    $state.team += [int]$id
    $newCount = @($state.team | Where-Object { [int]$_ -eq [int]$id }).Count
    $copyTag = if ($newCount -gt 1) { " (copy $newCount of $owned)" } else { '' }
    Print ''
    Print "  Added $($Dex[[string]$id].name_zh) (#$id)$copyTag to team. Slot $([int]$state.team.Count)/6."
    Print ''
}

function Move-Team($state, [int]$id, [int]$newPos1) {
    if (-not $state.team -or $state.team.Count -eq 0) { Print (Color '38;5;196' "Team is empty."); return }
    if (-not ($state.team -contains [int]$id)) { Print (Color '38;5;196' "Pokemon #$id not in team."); return }
    $newIdx = $newPos1 - 1
    if ($newIdx -lt 0 -or $newIdx -ge $state.team.Count) {
        Print (Color '38;5;196' "Position $newPos1 out of range (1..$($state.team.Count)).")
        return
    }
    if ($newIdx -eq 0) {
        Print (Color '38;5;196' "Position 1 is the LEADER slot. Use /gacha buddy $id to switch leader.")
        return
    }
    $without = @()
    foreach ($t in $state.team) {
        if ([int]$t -ne [int]$id) { $without += [int]$t }
    }
    $reordered = @()
    for ($i = 0; $i -lt $without.Count; $i++) {
        if ($i -eq $newIdx) { $reordered += [int]$id }
        $reordered += [int]$without[$i]
    }
    if ($newIdx -ge $without.Count) { $reordered += [int]$id }
    $state.team = $reordered
    Print ''
    Print "  Moved $($Dex[[string]$id].name_zh) (#$id) to position $newPos1."
    Print ''
}

function Remove-Team($state, [int]$id) {
    if (-not $state.team -or $state.team.Count -eq 0) { Print (Color '38;5;196' "Team is empty."); return }
    if (-not ($state.team -contains [int]$id)) { Print (Color '38;5;196' "Pokemon #$id not in team."); return }
    if ($state.team.Count -eq 1) {
        Print (Color '38;5;196' "Can't remove the only team member. Set a different buddy first.")
        return
    }
    # If multiple copies, remove the LAST occurrence (preserves leader at index 0).
    $occurrences = @()
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        if ([int]$state.team[$i] -eq [int]$id) { $occurrences += $i }
    }
    $removeAt = $occurrences[-1]
    if ($removeAt -eq 0 -and $state.team.Count -gt 1) {
        Print (Color '38;5;196' "Can't remove the LEADER while team has others. Switch leader first: /gacha buddy <other-id>")
        return
    }
    $newArr = @()
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        if ($i -ne $removeAt) { $newArr += [int]$state.team[$i] }
    }
    $state.team = $newArr
    $remaining = @($state.team | Where-Object { [int]$_ -eq [int]$id }).Count
    $remTag = if ($remaining -gt 0) { " ($remaining copy(s) still in team)" } else { '' }
    Print ''
    Print "  Removed $($Dex[[string]$id].name_zh) (#$id) from team. Slot $([int]$state.team.Count)/6.$remTag"
    Print ''
}

function Show-Album($state) {
    $ownedIds = @()
    foreach ($k in @($state.owned.Keys)) {
        if ([int]$state.owned[$k].count -ge 1) { $ownedIds += [int]$k }
    }
    if ($ownedIds.Count -eq 0) {
        Print ''
        Print "  No pokemon caught yet. Try /gacha pull."
        Print ''
        return
    }
    $ownedIds = @($ownedIds | Sort-Object)
    Print ''
    Print (Bold "=== Album ($($ownedIds.Count)/151) ===")
    Print ''

    $perRow = 3
    $cellPad = 2   # spaces between sprite cells
    for ($start = 0; $start -lt $ownedIds.Count; $start += $perRow) {
        $end = [Math]::Min($start + $perRow - 1, $ownedIds.Count - 1)
        $chunk = $ownedIds[$start..$end]

        # Load each sprite's lines + compute per-column widths
        $cellLines = @()
        $widths = @()
        $maxRows = 0
        foreach ($id in $chunk) {
            $path = Join-Path $ClaudeDir "sprites\regular\$([int]$id).txt"
            $lines = if (Test-Path $path) { @(Get-Content $path -Encoding UTF8) } else { @("[no sprite #$id]") }
            $w = 0
            foreach ($l in $lines) {
                $vw = Get-VisibleWidth $l
                if ($vw -gt $w) { $w = $vw }
            }
            $cellLines += ,$lines
            $widths += $w
            if ($lines.Count -gt $maxRows) { $maxRows = $lines.Count }
        }

        # Print each sprite row, padded to its cell width
        for ($i = 0; $i -lt $maxRows; $i++) {
            $row = ''
            for ($j = 0; $j -lt $chunk.Count; $j++) {
                $line = if ($i -lt $cellLines[$j].Count) { $cellLines[$j][$i] } else { '' }
                $pad = ' ' * [Math]::Max(0, $widths[$j] - (Get-VisibleWidth $line))
                $row += $line + $pad + (' ' * $cellPad)
            }
            Print $row
        }

        # Caption row: glyph #NNN name [shiny ✨]
        $captionRow = ''
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            $id = [int]$chunk[$j]
            $p = $Dex[[string]$id]
            $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
            $isShiny = (Get-OwnedShinyCount $state $id) -gt 0
            $nameTxt = if ($isShiny) { Gold $p.name_zh } else { Color '38;5;255' $p.name_zh }
            $shinyTag = if ($isShiny) { ' ' + (Color '1;38;5;220' [string][char]0x2728) } else { '' }
            $cnt = [int]$state.owned[[string]$id].count
            $cntTag = if ($cnt -gt 1) { Dim " x$cnt" } else { '' }
            $cell = " $glyph #$('{0:D3}' -f $id) $nameTxt$shinyTag$cntTag"
            $pad = ' ' * [Math]::Max(0, $widths[$j] - (Get-VisibleWidth $cell))
            $captionRow += $cell + $pad + (' ' * $cellPad)
        }
        Print $captionRow
        Print ''
    }
    Print "  $(Dim 'Caught total:') $($ownedIds.Count)$(Dim '/151')"
    Print ''
}

function Show-Team($state) {
    if (-not $state.team -or $state.team.Count -eq 0) {
        Print ''
        Print "  Team is empty. Use /gacha buddy <id> to start a team."
        Print ''
        return
    }
    Print ''
    Print (Bold "=== Team ($($state.team.Count)/6) ===")
    Print ''
    # Pre-pass: count occurrences per dex_id so duplicates get A/B/C... labels.
    $dupTotals = @{}
    foreach ($t in $state.team) {
        $k = [string]$t
        if ($dupTotals.ContainsKey($k)) { $dupTotals[$k] = $dupTotals[$k] + 1 } else { $dupTotals[$k] = 1 }
    }
    $dupSeen = @{}
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        $id = [int]$state.team[$i]
        if (-not $Dex.ContainsKey([string]$id)) { continue }
        $p = $Dex[[string]$id]
        $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
        $shiny = (Get-OwnedShinyCount $state $id) -gt 0
        $name = if ($shiny) { Gold $p.name_zh } else { Color '38;5;255' $p.name_zh }
        $tag = if ($i -eq 0) { Color '1;38;5;226' '[LEADER]' } else { Dim "  team    " }
        $lvlTag = if ($i -eq 0 -and $state.buddy) { "LV. $(Get-Level ([int]$state.buddy.exp))" } else { '' }
        # Duplicate label A/B/C/... assigned in team-order when same dex_id has >1 copy in team.
        $k = [string]$id
        $copyLabel = ''
        if ($dupTotals[$k] -gt 1) {
            $seen = if ($dupSeen.ContainsKey($k)) { $dupSeen[$k] + 1 } else { 1 }
            $dupSeen[$k] = $seen
            $letter = [char]([byte][char]'A' + $seen - 1)
            $copyLabel = ' ' + (Color '1;38;5;226' "[$letter]")
        }
        Print "  $tag $glyph #$('{0:D3}' -f $id) $name$copyLabel $(Dim "($($p.name_en))") $lvlTag"
    }
    Print ''
    Print "  $(Dim '/gacha team add <id> | remove <id> | move <id> <pos> | /gacha buddy <id> (switch leader)')"
    Print ''
}

# --- Stat sparkline helpers ---
# Sparkline: one block character per stat, height = value / 255.
$SPARKBLOCKS = @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
function Stat-Sparkline([int]$v) {
    $idx = [Math]::Min(7, [int][Math]::Floor(($v / 256.0) * 8))
    if ($idx -lt 0) { $idx = 0 }
    return [string]$SPARKBLOCKS[$idx]
}
function Stat-Color([int]$v) {
    # red < 40, orange < 70, yellow < 100, green < 130, cyan < 160, blue >= 160
    if ($v -lt 40)  { return '38;5;196' }
    if ($v -lt 70)  { return '38;5;208' }
    if ($v -lt 100) { return '38;5;220' }
    if ($v -lt 130) { return '38;5;82'  }
    if ($v -lt 160) { return '38;5;51'  }
    return '38;5;39'
}
function Stats-Compact($s) {
    # Single-line "HP▅ ATK▄ DEF▃ SpA▅ SpD▅ Spd▂" with per-stat color.
    $hp  = "$(Color (Stat-Color $s.hp)  "HP$(Stat-Sparkline $s.hp)")"
    $atk = "$(Color (Stat-Color $s.atk) "ATK$(Stat-Sparkline $s.atk)")"
    $def = "$(Color (Stat-Color $s.def) "DEF$(Stat-Sparkline $s.def)")"
    $spa = "$(Color (Stat-Color $s.spa) "SpA$(Stat-Sparkline $s.spa)")"
    $spd = "$(Color (Stat-Color $s.spd) "SpD$(Stat-Sparkline $s.spd)")"
    $spe = "$(Color (Stat-Color $s.spe) "Spd$(Stat-Sparkline $s.spe)")"
    return "$hp $atk $def $spa $spd $spe"
}

function Show-Stats($state, [int]$id) {
    $key = [string]$id
    if (-not $Dex.ContainsKey($key)) {
        Print (Color '38;5;196' "Unknown pokemon id: $id"); return
    }
    if (-not $Stats.ContainsKey($key)) {
        Print (Color '38;5;196' "No stats data for #$id."); return
    }
    $p = $Dex[$key]
    $s = $Stats[$key]
    $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
    $shiny = (Get-OwnedShinyCount $state $id) -gt 0
    $name = if ($shiny) { Gold $p.name_zh } else { Color '38;5;255' $p.name_zh }
    $rarityBadge = Color $RarityColor[$p.rarity] "[$($p.rarity)]"
    Print ''
    Print "  $glyph #$('{0:D3}' -f $id) $name $rarityBadge  $(Dim "($($p.name_en))")"
    Print "  $(Dim "BST $($s.bst) · type1 $($p.type1)" + $(if($p.type2){" / type2 $($p.type2)"} else {''}))"
    Print ''
    $entries = @(
        @{ label='HP '; v=$s.hp  },
        @{ label='Atk'; v=$s.atk },
        @{ label='Def'; v=$s.def },
        @{ label='SpA'; v=$s.spa },
        @{ label='SpD'; v=$s.spd },
        @{ label='Spd'; v=$s.spe }
    )
    foreach ($e in $entries) {
        $v = [int]$e.v
        $cells = [int][Math]::Floor(($v / 255.0) * 20)
        if ($cells -lt 0) { $cells = 0 }; if ($cells -gt 20) { $cells = 20 }
        $col = Stat-Color $v
        $bar = (Color $col ([string][char]0x2588 * $cells)) + (Color '38;5;238' ([string][char]0x2592 * (20 - $cells)))
        Print "  $(Color '38;5;245' $e.label)  $bar  $(Color $col ('{0,3}' -f $v))"
    }
    Print ''
}

# --- Battle engine ---
function Get-TypeMultiplier([string]$atkType, $defType1, $defType2) {
    $m = 1.0
    foreach ($dt in @($defType1, $defType2)) {
        if (-not $dt) { continue }
        if ($TypeChart.ContainsKey($atkType) -and $TypeChart[$atkType].ContainsKey($dt)) {
            $m = $m * $TypeChart[$atkType][$dt]
        }
    }
    return $m
}

function Build-Combatant([int]$id, [int]$lvl, [bool]$shiny = $false) {
    $key = [string]$id
    $p = $Dex[$key]
    $s = if ($Stats.ContainsKey($key)) { $Stats[$key] } else { @{ hp=100; atk=80; def=80; spa=80; spd=80; spe=80 } }
    # HP scales mildly with level so battles at high levels don't end instantly.
    $hpMax = [int]([Math]::Floor((2.0 * [int]$s.hp + 31) * $lvl / 100.0) + $lvl + 10)
    return @{
        id        = $id
        name_zh   = $p.name_zh
        name_en   = $p.name_en
        type1     = $p.type1
        type2     = $p.type2
        stats     = $s
        glyph     = "$($TypeGlyph[$p.type1])"
        glyphCol  = $TypeColor[$p.type1]
        level     = $lvl
        shiny     = $shiny
        hp_cur    = $hpMax
        hp_max    = $hpMax
    }
}

function Compute-Damage($atk, $def) {
    $isSpecial = $SpecialTypes -contains $atk.type1
    $atkStat = if ($isSpecial) { [int]$atk.stats.spa } else { [int]$atk.stats.atk }
    $defStat = if ($isSpecial) { [int]$def.stats.spd } else { [int]$def.stats.def }
    $power = 80
    $base = ((2.0 * $atk.level + 10) * $power * $atkStat / (250.0 * $defStat)) + 2
    $stab = 1.5   # attacker uses its own type
    $typeMul = Get-TypeMultiplier $atk.type1 $def.type1 $def.type2
    $variance = (Get-Random -Minimum 85 -Maximum 101) / 100.0
    $dmg = [int][Math]::Floor($base * $stab * $typeMul * $variance)
    if ($dmg -lt 1 -and $typeMul -gt 0) { $dmg = 1 }
    if ($typeMul -eq 0) { $dmg = 0 }
    return @{ damage = $dmg; typeMul = $typeMul; isSpecial = $isSpecial }
}

function Format-Combatant($c) {
    $glyph = Color $c.glyphCol $c.glyph
    $name = if ($c.shiny) { Gold $c.name_zh } else { Color '38;5;255' $c.name_zh }
    return "$glyph #$('{0:D3}' -f $c.id) $name LV. $($c.level)"
}

function Format-HPBar($c) {
    $pct = if ($c.hp_max -gt 0) { [Math]::Max(0, [Math]::Min(1.0, $c.hp_cur / [double]$c.hp_max)) } else { 0 }
    $cells = [int][Math]::Floor($pct * 15)
    $col = if ($pct -ge 0.5) { '38;5;82' } elseif ($pct -ge 0.2) { '38;5;220' } else { '38;5;196' }
    $bar = (Color $col ([string][char]0x2588 * $cells)) + (Color '38;5;238' ([string][char]0x2592 * (15 - $cells)))
    return "$bar $(Color $col ([string]$c.hp_cur)) $(Dim "/$($c.hp_max)")"
}

function Take-Turn($attacker, $defender) {
    $r = Compute-Damage $attacker $defender
    $effTag = ''
    if     ($r.typeMul -eq 0)    { $effTag = Color '38;5;245' '   (沒有效果...)' }
    elseif ($r.typeMul -ge 2)    { $effTag = Color '1;38;5;226' '   (效果絕佳!)' }
    elseif ($r.typeMul -le 0.5)  { $effTag = Color '38;5;245' '   (效果不太好)' }
    $attName = Format-Combatant $attacker
    $atkStyle = if ($r.isSpecial) { '特殊招式' } else { '物理招式' }
    Print "  $attName 使出 $(Color $attacker.glyphCol $attacker.type1.ToUpper())系$atkStyle！$effTag"
    Start-Sleep -Milliseconds 600
    if ($r.typeMul -eq 0) {
        Print (Dim "  → 但是 #$('{0:D3}' -f $defender.id) $($defender.name_zh) 不受影響.")
    } else {
        $defender.hp_cur = [int][Math]::Max(0, [int]$defender.hp_cur - [int]$r.damage)
        Print "  $(Color '38;5;196' "→ 對 #$('{0:D3}' -f $defender.id) $($defender.name_zh) 造成 $($r.damage) 傷害.") $(Format-HPBar $defender)"
    }
    Start-Sleep -Milliseconds 700
    return $r.damage
}

function Resolve-Battle($teamA, $teamB, [string]$nameA, [string]$nameB) {
    # Both arrays = combatants built via Build-Combatant.
    # Speed-priority turn order; on KO, next pokemon comes in from same side.
    $idxA = 0; $idxB = 0
    $round = 1
    Print ''
    Print (Bold "=== Battle: $nameA  vs  $nameB ===")
    Print ''
    Start-Sleep -Milliseconds 600
    while ($idxA -lt $teamA.Count -and $idxB -lt $teamB.Count) {
        $a = $teamA[$idxA]
        $b = $teamB[$idxB]
        Print (Color '38;5;111' "[Round $round]")
        Print ''
        $aSpd = [int]$a.stats.spe + (Get-Random -Maximum 5)
        $bSpd = [int]$b.stats.spe + (Get-Random -Maximum 5)
        $first = if ($aSpd -ge $bSpd) { 'A' } else { 'B' }
        if ($first -eq 'A') {
            [void](Take-Turn $a $b)
            if ($b.hp_cur -gt 0) { [void](Take-Turn $b $a) }
        } else {
            [void](Take-Turn $b $a)
            if ($a.hp_cur -gt 0) { [void](Take-Turn $a $b) }
        }
        Print ''
        if ($a.hp_cur -le 0) {
            Print "$(Color '38;5;196' "→ $($a.name_zh) 倒下了！")"
            $idxA++
            Start-Sleep -Milliseconds 800
            if ($idxA -lt $teamA.Count) {
                Print "$(Color $nameA "$nameA 派出 $(Format-Combatant $teamA[$idxA])！")"
                Print ''
                Start-Sleep -Milliseconds 700
            }
        }
        if ($b.hp_cur -le 0) {
            Print "$(Color '38;5;196' "→ $($b.name_zh) 倒下了！")"
            $idxB++
            Start-Sleep -Milliseconds 800
            if ($idxB -lt $teamB.Count) {
                Print "$(Color $nameB "$nameB 派出 $(Format-Combatant $teamB[$idxB])！")"
                Print ''
                Start-Sleep -Milliseconds 700
            }
        }
        Start-Sleep -Milliseconds 400
        $round++
        if ($round -gt 30) { break }   # safety cap on infinite stalemate
    }
    Print ''
    if ($idxB -ge $teamB.Count) { return 'A' }
    if ($idxA -ge $teamA.Count) { return 'B' }
    return 'STALEMATE'
}

function Build-User-Team($state) {
    # User's combatants from $state.team, all sharing buddy.level
    $buddyLvl = if ($state.buddy -and $state.buddy.exp -ne $null) { Get-Level ([int]$state.buddy.exp) } else { 1 }
    $arr = @()
    foreach ($t in $state.team) {
        $id = [int]$t
        if (-not $Dex.ContainsKey([string]$id)) { continue }
        $isShiny = (Get-OwnedShinyCount $state $id) -gt 0
        $arr += , (Build-Combatant $id $buddyLvl $isShiny)
    }
    if ($arr.Count -eq 0) { return ,$arr }   # empty
    return , $arr
}

function Show-Gyms($state) {
    $beaten = @{}
    if ($state.gyms_beaten) {
        foreach ($g in $state.gyms_beaten) { $beaten[[int]$g] = $true }
    }
    Print ''
    Print (Bold "=== Gen 1 Gym Challenge ===")
    Print ''
    foreach ($gym in $GymLeaders) {
        $key = [int]$gym.idx
        $p = $Dex[[string]$gym.poke_id]
        $glyph = if ($p) { Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])" } else { '?' }
        $pname = if ($p) { $p.name_zh } else { "#$($gym.poke_id)" }
        $status = if ($beaten[$key]) { Color '1;38;5;82' '[CLEAR]' } else { Color '38;5;245' '[ open ]' }
        $badge = if ($beaten[$key]) { Color '1;38;5;220' "+$($gym.badge)" } else { Dim "(尚未拿到 $($gym.badge))" }
        Print "  $status Gym #$($gym.idx) $($gym.city) (leader $($gym.leader_name))"
        Print "         挑戰：$glyph #$('{0:D3}' -f $gym.poke_id) $(Color '38;5;255' $pname) LV. $($gym.level)   $badge"
    }
    Print ''
    Print "  $(Dim '/gacha gym <N> 挑戰 (1-8); buddy.level + team 一起出戰; gym leader 等級越來越高.')"
    Print ''
}

function Challenge-Gym($state, [int]$gymIdx) {
    if ($gymIdx -lt 1 -or $gymIdx -gt 8) {
        Print (Color '38;5;196' "Gym index out of range (1-8).")
        return
    }
    $gym = $GymLeaders[$gymIdx - 1]
    if (-not $state.team -or $state.team.Count -eq 0) {
        Print (Color '38;5;196' "Team is empty. Use /gacha buddy <id> to start a team first.")
        return
    }
    $userTeam = Build-User-Team $state
    if ($userTeam.Count -eq 0) {
        Print (Color '38;5;196' "Team contains no valid pokemon.")
        return
    }
    $leaderTeam = @((Build-Combatant ([int]$gym.poke_id) ([int]$gym.level) $false))

    Print ''
    Print (Color '1;38;5;220' "你挑戰了 $($gym.city) (leader $($gym.leader_name))！")
    Print "  $(Dim '對手:') $(Format-Combatant $leaderTeam[0])  HP $($leaderTeam[0].hp_max)"
    Print ''
    Start-Sleep -Milliseconds 800

    $userLvl = $userTeam[0].level
    $result = Resolve-Battle $userTeam $leaderTeam ("$(Color '1;38;5;82' '你')") ("$(Color '1;38;5;196' "$($gym.leader_name)")")

    if ($result -eq 'A') {
        Print (Color '1;38;5;82' "★ 勝利！你打贏 $($gym.leader_name)，獲得 $($gym.badge)！")
        $coinReward = $gym.level * 2
        $expReward = $gym.level
        $state.coins = [int]$state.coins + $coinReward
        if ($state.buddy -and $state.buddy.id) {
            $state.buddy.exp = [int]$state.buddy.exp + $expReward
        }
        if (-not $state.gyms_beaten) { $state.gyms_beaten = @() }
        if (-not ($state.gyms_beaten -contains $gymIdx)) {
            $state.gyms_beaten += $gymIdx
        }
        $state.battle_streak_current = [int]$state.battle_streak_current + 1
        if ([int]$state.battle_streak_current -gt [int]$state.battle_streak_best) {
            $state.battle_streak_best = [int]$state.battle_streak_current
        }
        Print ""
        Print (Dim "  獎勵：+$coinReward coins (LV. * 2)  ·  +$expReward exp to buddy  ·  streak $($state.battle_streak_current) (best $($state.battle_streak_best))")
        Print (Dim "  進度：$($state.gyms_beaten.Count)/8 道館攻略")
    } elseif ($result -eq 'B') {
        Print (Color '1;38;5;196' "✕ 戰敗。隊伍全滅，下次再來。")
        Print (Dim "  Tips: 再 grind 一下 buddy 等級、或 trade 一隻 R/HR 來扛場.  streak 0 (best $($state.battle_streak_best)).")
        $state.battle_streak_current = 0
    } else {
        Print (Dim "  Stalemate — 戰鬥太久沒分出勝負，當作平手撤退。  streak 0 (best $($state.battle_streak_best)).")
        $state.battle_streak_current = 0
    }
    Print ''
}

function Show-Trainer($state) {
    # Pull trainer name from git config (user.name), fall back to "Trainer".
    $name = 'Trainer'
    try {
        $gn = git config --global user.name 2>$null
        if ($gn) { $name = [string]$gn }
    } catch {}

    # Aggregate stats
    $caught = 0
    $shinyTotal = 0
    $bagSpecies = 0
    $bagCards = 0
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught) { $caught++ }
        $shinyTotal += [int]$state.owned[$k].shiny_count
        $cnt = [int]$state.owned[$k].count
        if ($cnt -gt 0) { $bagSpecies++; $bagCards += $cnt }
    }
    $dexTotal = 151
    $dexPct = [Math]::Round(($caught / [double]$dexTotal) * 100, 1)
    $sessions = [int]$state.sessions_count
    $coins = [int]$state.coins
    $pulls = [int]$state.stats.pulls_total
    $evols = [int]$state.stats.evolutions_done
    $trades = [int]$state.stats.trades_done

    # Buddy line
    $buddyLine = '(no buddy set)'
    if ($state.buddy -and $state.buddy.id) {
        $bp = $Dex[[string]$state.buddy.id]
        $bg = Color $TypeColor[$bp.type1] "$($TypeGlyph[$bp.type1])"
        $bn = if ([bool]$state.buddy.shiny) { Gold $bp.name_zh } else { Color '38;5;255' $bp.name_zh }
        $blv = Get-Level ([int]$state.buddy.exp)
        $buddyLine = "$bg #$('{0:D3}' -f $bp.id) $bn LV. $blv"
    }

    # Team showcase line
    $teamLine = '(empty)'
    if ($state.team -and $state.team.Count -gt 0) {
        $glyphs = @()
        foreach ($t in $state.team) {
            $tid = [int]$t
            $tp = $Dex[[string]$tid]
            if (-not $tp) { continue }
            $tg = Color $TypeColor[$tp.type1] "$($TypeGlyph[$tp.type1])"
            $glyphs += "$tg$(Color '38;5;245' "#$('{0:D3}' -f $tid)")"
        }
        $teamLine = $glyphs -join ' '
    }

    # Frame
    $T_LT2 = [string][char]0x2554; $T_RT2 = [string][char]0x2557
    $T_LB2 = [string][char]0x255A; $T_RB2 = [string][char]0x255D
    $T_HZ2 = [string][char]0x2550; $T_VT2 = [string][char]0x2551
    $W = 60   # inner content width — accommodates full team (6 pokemon glyph+id)
    $fc = '38;5;220'
    $top = (Color $fc "$T_LT2$($T_HZ2 * 3)") + (Color '1;38;5;226' ' TRAINER ') + (Color $fc "$($T_HZ2 * ($W - 12))$T_RT2")
    $bot = Color $fc "$T_LB2$($T_HZ2 * $W)$T_RB2"
    $blank = (Color $fc $T_VT2) + (' ' * $W) + (Color $fc $T_VT2)

    function Frame-Row([string]$label, [string]$value, $W) {
        $labelCol = Color '38;5;111' $label.PadRight(14)
        $body = "  $labelCol $value"
        $bw = Get-VisibleWidth $body
        $pad = ' ' * [Math]::Max(0, $W - $bw)
        return (Color $fc $T_VT2) + $body + $pad + (Color $fc $T_VT2)
    }

    Print ''
    Print $top
    Print $blank
    Print (Frame-Row 'NAME' $name $W)
    Print (Frame-Row 'SESSIONS' "$sessions" $W)
    Print (Frame-Row 'COINS' "$(Color '1;38;5;220' "$coins")" $W)
    Print (Frame-Row 'DEX' "$caught/$dexTotal $(Dim "($dexPct%)")" $W)
    Print (Frame-Row 'BAG' "$bagSpecies species $DOT $bagCards cards" $W)
    Print (Frame-Row 'SHINIES' "$(Color '1;38;5;220' $shinyTotal)" $W)
    Print (Frame-Row 'PULLS' "$pulls" $W)
    Print (Frame-Row 'EVOLUTIONS' "$evols" $W)
    Print (Frame-Row 'TRADES' "$trades" $W)
    Print $blank
    Print (Frame-Row 'BUDDY' $buddyLine $W)
    Print (Frame-Row 'TEAM' $teamLine $W)
    Print $blank
    Print $bot
    Print ''
}

function Evolve-Pokemon($state, [int]$id) {
    $key = [string]$id
    if (-not $Dex.ContainsKey($key)) {
        Print (Color '38;5;196' "Unknown pokemon id: $id"); return
    }
    $poke = $Dex[$key]
    if ($null -eq $poke.evolves_to) {
        Print (Color '38;5;196' "$($poke.name_zh) (#$id) has no evolution in Gen 1."); return
    }
    if ((Get-OwnedCount $state $id) -lt 1) {
        Print (Color '38;5;196' "You don't own $($poke.name_zh) (#$id)."); return
    }
    # Level tracked only for active buddy; require this pokemon to be the buddy
    if (-not $state.buddy -or [int]$state.buddy.id -ne $id) {
        Print (Color '38;5;196' "Only the active buddy can evolve. Set $($poke.name_zh) as buddy first: /gacha buddy $id")
        return
    }
    # Level gate: canonical Gen 1 evolve_level. lvl follows triangular curve (Get-Level).
    if ($null -ne $poke.evolve_level) {
        $curLvl = Get-Level ([int]$state.buddy.exp)
        if ($curLvl -lt [int]$poke.evolve_level) {
            $needed = Get-ExpForLevel ([int]$poke.evolve_level)
            $haveExp = [int]$state.buddy.exp
            Print (Color '38;5;196' "$($poke.name_zh) evolves at LV. $([int]$poke.evolve_level) (currently LV. $curLvl, $haveExp/$needed exp). Keep using me as buddy.")
            return
        }
    }
    # Cost = evolve_level (Bulbasaur L16 -> 16 coin). Fallback to old 5/20 if level missing.
    $cost = if ($null -ne $poke.evolve_level) { [int]$poke.evolve_level } else { if ($poke.stage -eq 0) { 5 } else { 20 } }
    if ([int]$state.coins -lt $cost) {
        Print (Color '38;5;196' "Need $cost coins; have $([int]$state.coins)."); return
    }
    $hadShiny = (Get-OwnedShinyCount $state $id) -gt 0
    Remove-Owned $state $id 1 | Out-Null
    if ($hadShiny) { $state.owned[$key].shiny_count = [int]$state.owned[$key].shiny_count - 1 }
    Add-Owned $state ([int]$poke.evolves_to) $hadShiny
    $state.coins = [int]$state.coins - $cost
    $state.stats.evolutions_done = [int]$state.stats.evolutions_done + 1

    $next = $Dex[[string]$poke.evolves_to]

    # If buddy was the evolved pokemon, follow it forward (preserve exp)
    if ($state.buddy -and [int]$state.buddy.id -eq $id) {
        $state.buddy.id           = [int]$poke.evolves_to
        $state.buddy.shiny        = $hadShiny
        $state.buddy.name_zh      = $next.name_zh
        $state.buddy.type1        = $next.type1
        $state.buddy.stage        = [int]$next.stage
        $state.buddy.evolves_to   = $next.evolves_to
        $state.buddy.evolve_level = $next.evolve_level
    }
    $g1 = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
    $g2 = Color $TypeColor[$next.type1] "$($TypeGlyph[$next.type1])"
    $shinyTag = if ($hadShiny) { Gold ' *shiny preserved*' } else { '' }
    Print ''
    Print "  $g1 $($poke.name_zh) (#$id) $ARROW $g2 $($next.name_zh) (#$($next.id))  -$cost coin$shinyTag"
    Print (Dim "  Coins remaining: $([int]$state.coins)")
    Print ''
}

function Trade-Dupes($state) {
    $candidates = @()
    foreach ($k in $state.owned.Keys) {
        $c = [int]$state.owned[$k].count
        if ($c -ge 2) {
            for ($i = 0; $i -lt ($c - 1); $i++) { $candidates += [int]$k }
        }
    }
    if ($candidates.Count -lt 5) {
        Print (Color '38;5;196' "Need 5 spare duplicates (you have $($candidates.Count)). Spare = beyond the first of each species.")
        return
    }
    $picked = @()
    $pool = New-Object System.Collections.ArrayList
    foreach ($x in $candidates) { [void]$pool.Add([int]$x) }
    for ($i = 0; $i -lt 5; $i++) {
        $idx = Get-Random -Maximum $pool.Count
        $picked += [int]$pool[$idx]
        $pool.RemoveAt($idx)
    }
    $grouped = $picked | Group-Object
    foreach ($g in $grouped) {
        Remove-Owned $state ([int]$g.Name) ([int]$g.Count) | Out-Null
    }
    $rewardId = Get-RandomIdInRarity 'R'
    $isShiny = Roll-Shiny
    $wasZero = (Get-OwnedCount $state $rewardId) -eq 0
    Add-Owned $state $rewardId $isShiny
    if ($isShiny) { $state.stats.shinies_total = [int]$state.stats.shinies_total + 1 }
    $state.stats.trades_done = [int]$state.stats.trades_done + 1

    $reward = $Dex[[string]$rewardId]
    Print ''
    Print (Bold "=== Trade-in complete ===")
    Print ''
    $tradedNames = ($picked | ForEach-Object { $Dex[[string]$_].name_zh }) -join ', '
    Print "  Traded: $tradedNames"
    Print ''
    Print "  Reward:$(Format-CardLine $reward $isShiny 'R' $wasZero)"
    Print ''
}

function Show-Dex($state) {
    # Dex = ever-caught (first_caught != null). Independent of current bag count:
    # a pokemon evolved/traded away stays in the dex.
    $total = 151
    $caught = 0
    $byRar = @{
        'C'  = @{ caught = 0; total = $ByRarity['C'].Count }
        'U'  = @{ caught = 0; total = $ByRarity['U'].Count }
        'R'  = @{ caught = 0; total = $ByRarity['R'].Count }
        'HR' = @{ caught = 0; total = $ByRarity['HR'].Count }
    }
    $shinies = 0
    foreach ($k in $state.owned.Keys) {
        $isCaught = ($null -ne $state.owned[$k].first_caught)
        if ($isCaught) {
            $caught++
            $p = $Dex[$k]
            $byRar[$p.rarity].caught++
        }
        $shinies += [int]$state.owned[$k].shiny_count
    }
    $pct = [Math]::Round(($caught / [double]$total) * 100, 1)
    Print ''
    Print (Bold "=== Pokedex $caught/$total ($pct%) ===")
    Print ''
    Print "  C $(Color $RarityColor['C']  ("$($byRar['C'].caught)/$($byRar['C'].total)")) $DOT U $(Color $RarityColor['U']  ("$($byRar['U'].caught)/$($byRar['U'].total)")) $DOT R $(Color $RarityColor['R']  ("$($byRar['R'].caught)/$($byRar['R'].total)")) $DOT HR $(Color $RarityColor['HR'] ("$($byRar['HR'].caught)/$($byRar['HR'].total)")) $DOT Shinies $(Gold $shinies)"
    Print ''
    Print "  Caught (1-151):  $(Dim '(dim id = in dex but no copy left in bag)')"
    $line = '  '
    for ($i = 1; $i -le 151; $i++) {
        $k = [string]$i
        $hasEntry = $state.owned.Contains($k)
        $cnt = if ($hasEntry) { [int]$state.owned[$k].count } else { 0 }
        $sc  = if ($hasEntry) { [int]$state.owned[$k].shiny_count } else { 0 }
        $caughtFlag = $hasEntry -and ($null -ne $state.owned[$k].first_caught)
        $idStr = '{0:D3}' -f $i
        if ($caughtFlag -and $cnt -gt 0) {
            $col = if ($sc -gt 0) { '1;38;5;220' } else { $TypeColor[$Dex[$k].type1] }
            $marker = if ($cnt -gt 1) { "${idStr}x$cnt" } else { $idStr }
            $line += (Color $col $marker) + ' '
        } elseif ($caughtFlag) {
            # In dex but bag empty (evolved/traded away). Dim version of type color.
            $line += (Color '2;38;5;244' $idStr) + ' '
        } else {
            $line += (Color '38;5;236' '...') + ' '
        }
        if ($i % 10 -eq 0) {
            Print $line
            $line = '  '
        }
    }
    if ($line.Trim()) { Print $line }
    Print ''
}

function Show-Bag($state) {
    # Bag = current holdings (count > 0). Independent of dex (ever-caught).
    # Lists every species with at least one copy, with x-count, shiny tag,
    # and "*team" marker if any copy is currently slotted in the team.
    $rows = @()
    foreach ($k in $state.owned.Keys) {
        $cnt = [int]$state.owned[$k].count
        if ($cnt -lt 1) { continue }
        $id = [int]$k
        if (-not $Dex.ContainsKey($k)) { continue }
        $rows += [pscustomobject]@{
            id          = $id
            count       = $cnt
            shiny_count = [int]$state.owned[$k].shiny_count
            poke        = $Dex[$k]
        }
    }
    if ($rows.Count -eq 0) {
        Print ''
        Print "  Bag is empty. Try /gacha pull."
        Print ''
        return
    }
    $rows = $rows | Sort-Object id
    # Count totals for the header
    $totalSpecies = $rows.Count
    $totalCopies  = ($rows | Measure-Object -Property count -Sum).Sum
    $totalShinies = ($rows | Measure-Object -Property shiny_count -Sum).Sum

    # Which dex ids are currently in team (for the *team marker)
    $teamSet = @{}
    if ($state.team) { foreach ($t in $state.team) { $teamSet[[int]$t] = $true } }

    Print ''
    Print (Bold "=== Bag ($totalSpecies species $DOT $totalCopies cards $DOT $totalShinies shiny) ===")
    Print ''
    foreach ($r in $rows) {
        $p = $r.poke
        $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
        $isShiny = $r.shiny_count -gt 0
        $nameTxt = if ($isShiny) { Gold $p.name_zh } else { Color '38;5;255' $p.name_zh }
        $cntTag  = if ($r.count -gt 1) { Color '1;38;5;255' " x$($r.count)" } else { '' }
        $shinyTag = if ($isShiny) {
            $sc = $r.shiny_count
            $tag = if ($sc -gt 1) { " (shiny x$sc)" } else { ' (shiny)' }
            Color '1;38;5;220' $tag
        } else { '' }
        $teamTag = if ($teamSet.ContainsKey($r.id)) { ' ' + (Color '38;5;141' '*team') } else { '' }
        $rarityTag = ' ' + (Color $RarityColor[$p.rarity] "[$($p.rarity)]")
        # Compact stat sparkline (6 chars) — full bars via /gacha stats <id>
        $statKey = [string]$r.id
        $statSpark = if ($Stats.ContainsKey($statKey)) { '  ' + (Stats-Compact $Stats[$statKey]) + '  ' + (Dim "BST $($Stats[$statKey].bst)") } else { '' }
        Print "  $glyph #$('{0:D3}' -f $r.id) $nameTxt$cntTag$shinyTag$rarityTag$teamTag$statSpark"
    }
    Print ''
    Print "  $(Dim 'Bag = current copies. /gacha stats <id> for full base-stat bars; /gacha dex for ever-caught view.')"
    Print ''
}

function Show-Help {
    Print ''
    Print (Bold "=== Pokemon Gacha - Commands ===")
    Print ''
    Print "  /gacha               status summary (coins, buddy, dex)"
    Print "  /gacha pull          open 1 pack (1 card, 1 coin)"
    Print "  /gacha pulls N       open N packs at once"
    Print "  /gacha buddy ID      set active leader (auto-adds to team)"
    Print "  /gacha team          show your team (up to 6 pokemon)"
    Print "  /gacha team add ID   add pokemon to team (max 6)"
    Print "  /gacha team remove ID  drop pokemon from team"
    Print "  /gacha team move ID POS  reorder team (POS 2..6; use /gacha buddy to swap leader)"
    Print "  /gacha evolve ID     evolve active leader (cost = Gen 1 evolve level e.g. 16 / 32 / 36)"
    Print "  /gacha trade         convert 5 duplicate spares -> 1 random Rare"
    Print "  /gacha catch         attempt to catch the wild pokemon (encounters trigger 1% / new session; HR/legendaries only available here)"
    Print "  /gacha trainer       trainer card summary (name / sessions / dex% / coins / shinies / buddy / team)"
    Print "  /gacha stats ID      full base-stat bars for a pokemon (HP/Atk/Def/SpA/SpD/Spd, 20-cell bars)"
    Print "  /gacha gyms          show all 8 Gen 1 gym leaders + your beat progress"
    Print "  /gacha gym N         challenge gym N (1-8); team fights at buddy LV, leader has fixed LV"
    Print "  /gacha achievements  show all 20 milestone achievements + earned dates"
    Print "  /gacha event         show today's themed pull bonus (rotates by weekday)"
    Print "  /gacha dex           Pokedex grid (every species ever caught)"
    Print "  /gacha bag           current bag (copies you still hold)"
    Print "  /gacha album         show sprite art for every species in bag"
    Print "  /gacha help          this help"
    Print ''
    Print "  $(Dim 'Coins auto-earn: 1 coin per `$1 USD of session cost (cost-only mode).')"
    Print "  $(Dim 'Shiny rate: 1/4096 per card. Pull rarities: C 90% / U 7% / R 2.5% / HR 0.5%.')"
    Print "  $(Dim 'Team: dupes allowed. Own N copies of #X = field up to N. Tagged [A]/[B]/[C] in team-order.')"
    Print "  $(Dim 'Pool: stage 0 pokemon only. Evolved forms obtainable via /gacha evolve.')"
    Print "  $(Dim 'Level: 1 session = 1 level. Evolve at canonical Gen 1 level (Bulbasaur L16 -> Ivysaur).')"
    Print ''
}

# --- Main dispatch ---
$state = Load-State

switch ($Cmd.ToLower()) {
    'status'  { Show-Status $state }
    ''        { Show-Status $state }
    'pull'    { [void](Pull-Pack $state $false) }
    'pulls'   {
        $n = 0
        if (-not [int]::TryParse($Arg, [ref]$n)) { Print "Usage: pulls <N>"; break }
        Pull-Multi $state $n
    }
    'buddy'   {
        $id = 0
        if (-not [int]::TryParse($Arg, [ref]$id)) { Print "Usage: buddy <pokemon-id>"; break }
        Set-Buddy $state $id
    }
    'team'    {
        if ([string]::IsNullOrWhiteSpace($Arg)) {
            Show-Team $state
        } elseif ($Arg -match '^\d+$') {
            Add-Team $state ([int]$Arg)
        } elseif ($Arg -eq 'add' -or $Arg -eq 'a') {
            $id = 0
            if (-not [int]::TryParse($Arg2, [ref]$id)) { Print "Usage: team add <pokemon-id>"; break }
            Add-Team $state $id
        } elseif ($Arg -eq 'remove' -or $Arg -eq 'rm' -or $Arg -eq 'r') {
            $id = 0
            if (-not [int]::TryParse($Arg2, [ref]$id)) { Print "Usage: team remove <pokemon-id>"; break }
            Remove-Team $state $id
        } elseif ($Arg -eq 'move' -or $Arg -eq 'mv' -or $Arg -eq 'm') {
            $mid = 0; $mpos = 0
            if (-not [int]::TryParse($Arg2, [ref]$mid) -or -not [int]::TryParse($Arg3, [ref]$mpos)) {
                Print "Usage: team move <pokemon-id> <position 2..6>"; break
            }
            Move-Team $state $mid $mpos
        } elseif ($Arg -eq 'show' -or $Arg -eq 'list') {
            Show-Team $state
        } else {
            Print (Color '38;5;196' "Unknown team subcommand: $Arg")
        }
    }
    'evolve'  {
        $id = 0
        if (-not [int]::TryParse($Arg, [ref]$id)) { Print "Usage: evolve <pokemon-id>"; break }
        Evolve-Pokemon $state $id
    }
    'trade'   { Trade-Dupes $state }
    'catch'   { Catch-Encounter $state }
    'trainer' { Show-Trainer $state }
    'card'    { Show-Trainer $state }
    'stats'   {
        $id = 0
        if (-not [int]::TryParse($Arg, [ref]$id)) { Print "Usage: stats <pokemon-id>"; break }
        Show-Stats $state $id
    }
    'achievements' { Show-Achievements $state }
    'achv'    { Show-Achievements $state }
    'event'   { Show-Event }
    'today'   { Show-Event }
    'gyms'    { Show-Gyms $state }
    'gym'     {
        if ([string]::IsNullOrWhiteSpace($Arg)) { Show-Gyms $state; break }
        $g = 0
        if (-not [int]::TryParse($Arg, [ref]$g)) { Print "Usage: gym <1..8>"; break }
        Challenge-Gym $state $g
    }
    'dex'     { Show-Dex $state }
    'bag'     { Show-Bag $state }
    'album'   { Show-Album $state }
    'gallery' { Show-Album $state }
    'help'    { Show-Help }
    default   {
        Print (Color '38;5;196' "Unknown command: $Cmd")
        Show-Help
    }
}

# Achievement check: any newly earned this command? Print toast lines then save.
$newAchv = Check-Achievements $state
if ($newAchv.Count -gt 0) {
    Print ''
    foreach ($slug in $newAchv) {
        $a = $Achievements | Where-Object { $_.slug -eq $slug } | Select-Object -First 1
        if ($a) {
            Print "$(Color '1;38;5;220' '★ 成就解鎖！')  $(Color '1;38;5;255' $a.name_zh)  $(Dim $a.desc)"
        }
    }
    Print ''
}
Save-State $state



