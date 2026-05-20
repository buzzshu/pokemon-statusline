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
    # Exact inverse of L*(L-1)/2 = exp. The naive floor(sqrt(2*exp))+1 overshoots
    # by 1 in the middle of a level band (correct only at exact thresholds), which
    # caused statusline progress to render as "exp - exp_for_level(L) = -N/L".
    return [int][Math]::Floor((1 + [Math]::Sqrt(1 + 8.0 * $exp)) / 2)
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

# --- Move system (hybrid: shared type pool + per-pokemon signature kits) ---
# $TypeMoves: each type has a weak (~50 power) and strong (~90 power) entry.
# Get-Moveset uses these to build a default kit from stage + type1/type2.
# $SignatureMoves overrides for flagship pokemon (Gen 1 starter finals, legendaries,
# fan favorites) so they feel distinct instead of "another fire mon spamming fire".
$TypeMoves = @{
    'normal'   = @(@{name='撞擊';power=50}, @{name='體當';power=90})
    'fire'     = @(@{name='火花';power=50}, @{name='噴射火焰';power=90})
    'water'    = @(@{name='水槍';power=50}, @{name='水炮';power=90})
    'electric' = @(@{name='電擊';power=50}, @{name='十萬伏特';power=90})
    'grass'    = @(@{name='飛葉快刀';power=50}, @{name='花瓣舞';power=90})
    'ice'      = @(@{name='冰光線';power=50}, @{name='急凍光線';power=90})
    'fighting' = @(@{name='空手劈';power=50}, @{name='飛膝踢';power=90})
    'poison'   = @(@{name='毒拳';power=50}, @{name='毒擊';power=90})
    'ground'   = @(@{name='挖洞';power=50}, @{name='地震';power=90})
    'flying'   = @(@{name='翅膀攻擊';power=50}, @{name='飛行';power=90})
    'psychic'  = @(@{name='念力';power=50}, @{name='精神強念';power=90})
    'bug'      = @(@{name='蟲咬';power=50}, @{name='蟲鳴';power=90})
    'rock'     = @(@{name='落石';power=50}, @{name='岩崩';power=90})
    'ghost'    = @(@{name='詛咒一擊';power=50}, @{name='暗影球';power=90})
    'dragon'   = @(@{name='龍之怒';power=50}, @{name='逆鱗';power=90})
}
# Signature kits: dex_id -> array of {name, type, power}. Caps at power 110 to keep
# battle balance (no 150-power "destruction" without recharge mechanic).
$SignatureMoves = @{
    3   = @(@{name='花瓣舞';type='grass';power=90},     @{name='日光束';type='grass';power=110},   @{name='毒拳';type='poison';power=50})
    6   = @(@{name='噴射火焰';type='fire';power=90},    @{name='大字爆';type='fire';power=110},   @{name='翅膀攻擊';type='flying';power=60})
    9   = @(@{name='水炮';type='water';power=90},       @{name='高壓水泵';type='water';power=110}, @{name='急凍光線';type='ice';power=90})
    25  = @(@{name='十萬伏特';type='electric';power=90}, @{name='電光一閃';type='normal';power=40}, @{name='打雷';type='electric';power=110})
    26  = @(@{name='打雷';type='electric';power=110},   @{name='十萬伏特';type='electric';power=90}, @{name='電光一閃';type='normal';power=40})
    65  = @(@{name='精神強念';type='psychic';power=90}, @{name='念力';type='psychic';power=50},   @{name='高速移動';type='psychic';power=0})  # 高速移動 0 power = utility, AI deprioritizes
    68  = @(@{name='飛膝踢';type='fighting';power=90},  @{name='地震';type='ground';power=90},     @{name='岩崩';type='rock';power=90})
    94  = @(@{name='暗影球';type='ghost';power=90},     @{name='毒擊';type='poison';power=90},     @{name='精神強念';type='psychic';power=90})
    121 = @(@{name='急凍光線';type='ice';power=90},     @{name='精神強念';type='psychic';power=90}, @{name='高壓水泵';type='water';power=110})
    130 = @(@{name='高壓水泵';type='water';power=110}, @{name='龍之怒';type='dragon';power=50},  @{name='啃咬';type='normal';power=60})
    142 = @(@{name='飛行';type='flying';power=90},      @{name='岩崩';type='rock';power=90},       @{name='超音波';type='normal';power=55})
    143 = @(@{name='體當';type='normal';power=90},      @{name='地震';type='ground';power=90},     @{name='啃咬';type='normal';power=60})
    144 = @(@{name='暴風雪';type='ice';power=110},     @{name='飛行';type='flying';power=90},     @{name='急凍光線';type='ice';power=90})
    145 = @(@{name='打雷';type='electric';power=110}, @{name='鑽嘴啄';type='flying';power=80},   @{name='十萬伏特';type='electric';power=90})
    146 = @(@{name='大字爆';type='fire';power=110},   @{name='飛行';type='flying';power=90},     @{name='噴射火焰';type='fire';power=90})
    149 = @(@{name='逆鱗';type='dragon';power=90},     @{name='急凍光線';type='ice';power=90},    @{name='翅膀攻擊';type='flying';power=60})
    150 = @(@{name='精神強念';type='psychic';power=90}, @{name='暗影球';type='ghost';power=90},  @{name='念力';type='psychic';power=50})
    151 = @(@{name='精神強念';type='psychic';power=90}, @{name='高壓水泵';type='water';power=110}, @{name='打雷';type='electric';power=110})
}

# --- 8 Gen 1 gym leaders (canonical RBY) ---
# Each row carries a `badge_idx` into $BadgeGlyphs below; statusline.ps1 keeps an
# independent copy of the glyph/color table — see CLAUDE.md "Sprite rendering +
# visible-width math" note for the duplication convention.
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

# --- Elite Four + Champion (gated behind all 8 gym badges) ---
# Each leader fields 2-3 pokemon (not just 1 like gyms). Levels mirror RBY canon
# (Lorelei L52-54, Bruno L53-56, Agatha L54-58, Lance L56-62, Champion L59-65).
$EliteFour = @(
    @{ idx=1; title='四大天王 1';    leader_name='科拿';     theme='ice';      poke_ids=@(87, 91, 80, 124, 131);    levels=@(52, 53, 54, 56, 54) }    # Lorelei: Dewgong/Cloyster/Slowbro/Jynx/Lapras
    @{ idx=2; title='四大天王 2';    leader_name='希巴';     theme='fighting'; poke_ids=@(95, 107, 106, 95, 68);    levels=@(53, 55, 55, 56, 58) }    # Bruno: Onix/Hitmonchan/Hitmonlee/Onix/Machamp
    @{ idx=3; title='四大天王 3';    leader_name='菊子';     theme='ghost';    poke_ids=@(94, 42, 93, 24, 94);      levels=@(56, 56, 55, 58, 60) }    # Agatha: Gengar/Golbat/Haunter/Arbok/Gengar
    @{ idx=4; title='四大天王 4';    leader_name='阿渡';     theme='dragon';   poke_ids=@(130, 148, 148, 142, 149); levels=@(58, 56, 56, 60, 62) }    # Lance: Gyarados/Dragonair/Dragonair/Aerodactyl/Dragonite
    @{ idx=5; title='冠軍';          leader_name='青綠';     theme='mixed';    poke_ids=@(18, 65, 112, 59, 103, 6); levels=@(59, 59, 61, 61, 61, 65) } # Blue (Charizard route): Pidgeot/Alakazam/Rhydon/Arcanine/Exeggutor/Charizard
)
# Badge visual table — keyed by gym idx 1..8.
# Glyph picks loosely echo canonical badge shape (◆ Boulder / ◇ Cascade water-drop /
# ✦ Thunder / ❀ Rainbow flower / ★ Marsh psychic / ♥ Soul / ▲ Volcano flame /
# ● Earth). All BMP-only per CLAUDE.md glyph rule (no supplementary-plane emoji).
$BadgeGlyphs = @{
    1 = @{ glyph=[char]0x25C6; color='38;5;138' }   # ◆ brown/grey
    2 = @{ glyph=[char]0x25C7; color='38;5;39'  }   # ◇ blue
    3 = @{ glyph=[char]0x2726; color='38;5;226' }   # ✦ yellow
    4 = @{ glyph=[char]0x2740; color='38;5;213' }   # ❀ pink
    5 = @{ glyph=[char]0x2605; color='38;5;220' }   # ★ gold
    6 = @{ glyph=[char]0x2665; color='38;5;141' }   # ♥ purple
    7 = @{ glyph=[char]0x25B2; color='38;5;196' }   # ▲ red
    8 = @{ glyph=[char]0x25CF; color='38;5;76'  }   # ● green/brown
}
$BadgeEmptyGlyph = [char]0x00B7   # · placeholder for unearned slots

# --- Statusline themes (3 palettes). state.theme picks; statusline.ps1 holds a duplicate. ---
$Themes = @{
    'gba'     = @{ outer='38;5;220'; outerTitle='1;38;5;226'; frame='38;5;111'; label='38;5;220'; desc='Game Boy Advance gold cartridge (預設)' }
    'crystal' = @{ outer='38;5;251'; outerTitle='1;38;5;255'; frame='38;5;87';  label='38;5;87';  desc='Gen 2 Crystal silver + cyan' }
    'dark'    = @{ outer='38;5;240'; outerTitle='38;5;247';   frame='38;5;60';  label='38;5;245'; desc='Low-contrast dark mode' }
}

# --- Item catalog ---
# slug -> {name_zh, cost, glyph, desc, use}
#   use = 'buddy-exp' (rare-candy)   immediate +10 exp to team[0]
#       = 'catch-boost' (great-ball) auto-consumed in Catch-Encounter, +50% rate
# Bag lives at state.items as @{ slug: count }. Empty by default; first /gacha buy
# materializes the key. Pricing intent: 1 day of active CC cost (~5-15 coin) buys
# roughly half a rare-candy, so candies feel earned but not unattainable.
$Items = [ordered]@{
    'rare-candy'    = @{ name_zh='稀有糖果';     cost=25;  glyph='♥'; color='38;5;213'; desc='+10 exp 給 buddy (team[0])';                                 use='buddy-exp' }
    'great-ball'    = @{ name_zh='高級球';       cost=15;  glyph='◎'; color='38;5;39';  desc='下次 /gacha catch 抓取機率 ×1.5 (自動消耗)';                use='catch-boost' }
    'ultra-ball'    = @{ name_zh='超級球';       cost=30;  glyph='◉'; color='38;5;220'; desc='下次 /gacha catch 抓取機率 ×2 (自動消耗，優先於高級球)';  use='catch-boost' }
    'master-ball'   = @{ name_zh='大師球';       cost=200; glyph='✦'; color='38;5;213'; desc='下次 /gacha catch 必中 100% (自動消耗，優先於所有球)';     use='catch-boost' }
    'repel'         = @{ name_zh='驅蟲噴霧';     cost=20;  glyph='⊘'; color='38;5;245'; desc='接下來 10 個 session 不會 spawn wild pokémon';              use='repel' }
    'fire-stone'    = @{ name_zh='火之石';       cost=50;  glyph='△'; color='38;5;202'; desc='跳過 LV gate 進化 Vulpix / Growlithe';                       use='stone' }
    'water-stone'   = @{ name_zh='水之石';       cost=50;  glyph='◇'; color='38;5;39';  desc='跳過 LV gate 進化 Poliwhirl / Shellder / Staryu / Eevee';   use='stone' }
    'thunder-stone' = @{ name_zh='雷之石';       cost=50;  glyph='✦'; color='38;5;226'; desc='跳過 LV gate 進化 Pikachu / Eevee';                          use='stone' }
    'leaf-stone'    = @{ name_zh='葉之石';       cost=50;  glyph='❀'; color='38;5;46';  desc='跳過 LV gate 進化 Gloom / Weepinbell / Exeggcute';           use='stone' }
    'moon-stone'    = @{ name_zh='月之石';       cost=50;  glyph='☽'; color='38;5;141'; desc='跳過 LV gate 進化 Clefairy / Jigglypuff / Nidorina / Nidorino'; use='stone' }
}

# Stone evolution mapping. Only pokemon listed here can use the stone path.
# Each entry: dex_id -> required stone slug. The stone use-flow finds the team
# slot with this id (highest exp wins on ties) and evolves it bypassing the
# canonical LV gate. Eevee defaults to whichever stone the user holds.
$StoneEvolutions = @{
    37  = 'fire-stone'     # Vulpix → Ninetales
    58  = 'fire-stone'     # Growlithe → Arcanine
    35  = 'moon-stone'     # Clefairy → Clefable
    39  = 'moon-stone'     # Jigglypuff → Wigglytuff
    30  = 'moon-stone'     # Nidorina → Nidoqueen
    33  = 'moon-stone'     # Nidorino → Nidoking
    25  = 'thunder-stone'  # Pikachu → Raichu
    44  = 'leaf-stone'     # Gloom → Vileplume
    70  = 'leaf-stone'     # Weepinbell → Victreebel
    102 = 'leaf-stone'     # Exeggcute → Exeggutor
    90  = 'water-stone'    # Shellder → Cloyster
    61  = 'water-stone'    # Poliwhirl → Poliwrath
    120 = 'water-stone'    # Staryu → Starmie
    133 = 'water-stone'    # Eevee → Vaporeon (default; thunder-stone path = same dest since dex only lists one)
}

# --- Achievement definitions (40 milestones) ---
# Each entry: slug (unique key in state.achievements), name_zh (display), desc (hint),
# kind (group for display ordering).
$Achievements = @(
    @{ slug='first-pull';     name_zh='初次見面';   desc='完成你的第一次 pull';                       kind='pull' }
    @{ slug='pull-10';        name_zh='十抽達人';   desc='累計 10 次 pull';                          kind='pull' }
    @{ slug='pull-50';        name_zh='五十抽達人'; desc='累計 50 次 pull';                          kind='pull' }
    @{ slug='pull-100';       name_zh='百抽達人';   desc='累計 100 次 pull';                         kind='pull' }
    @{ slug='first-hr';       name_zh='首見傳說';   desc='收集到第一隻 HR (神獸)';                   kind='collection' }
    @{ slug='first-shiny';    name_zh='首見閃光';   desc='抓到第一隻 shiny 寶可夢';                  kind='collection' }
    @{ slug='shiny-5';        name_zh='閃閃發亮';   desc='累計 5 隻 shiny';                          kind='collection' }
    @{ slug='shiny-10';       name_zh='閃光獵人';   desc='累計 10 隻 shiny';                         kind='collection' }
    @{ slug='dex-10';         name_zh='入門訓練家'; desc='圖鑑完成度 10% (15/151)';                  kind='dex' }
    @{ slug='dex-25';         name_zh='新手訓練家'; desc='圖鑑完成度 25% (38/151)';                  kind='dex' }
    @{ slug='dex-50';         name_zh='資深訓練家'; desc='圖鑑完成度 50% (76/151)';                  kind='dex' }
    @{ slug='dex-100';        name_zh='大師訓練家'; desc='圖鑑完成度 100% (151/151)';                kind='dex' }
    @{ slug='type-collector-5'; name_zh='屬性收集家'; desc='圖鑑涵蓋至少 5 個不同屬性';              kind='dex' }
    @{ slug='type-collector-9'; name_zh='屬性大師';   desc='圖鑑涵蓋至少 9 個不同屬性';              kind='dex' }
    @{ slug='all-starters';   name_zh='御三家齊全'; desc='同時擁有妙蛙種子 / 小火龍 / 傑尼龜';       kind='collection' }
    @{ slug='all-fossils';    name_zh='化石獵人';   desc='擁有菊石獸 / 化石盔 / 化石翼龍';           kind='collection' }
    @{ slug='all-legendary';  name_zh='神話收藏家'; desc='集滿急凍鳥 / 閃電鳥 / 火焰鳥 / 超夢 / 夢幻'; kind='collection' }
    @{ slug='first-evolve';   name_zh='初次進化';   desc='第一次 /gacha evolve 成功';                kind='train' }
    @{ slug='evolve-5';       name_zh='進化達人';   desc='累計 5 次 evolve';                          kind='train' }
    @{ slug='evolve-stone';   name_zh='石頭達人';   desc='第一次用 stone 進化';                       kind='train' }
    @{ slug='buddy-l10';      name_zh='牽絆 LV 10'; desc='Buddy 練到 LV. 10';                          kind='train' }
    @{ slug='buddy-l25';      name_zh='培育達人';   desc='Buddy 練到 LV. 25 (exp 300)';              kind='train' }
    @{ slug='buddy-l36';      name_zh='進化達標';   desc='Buddy 練到 LV. 36 (大多數第二進化條件)';   kind='train' }
    @{ slug='buddy-l50';      name_zh='培育大師';   desc='Buddy 練到 LV. 50 (exp 1225)';             kind='train' }
    @{ slug='triple-clone';   name_zh='複製戰隊';   desc='Team 同時有 3 隻同 dex 寶可夢 [A][B][C]';  kind='team' }
    @{ slug='team-full';      name_zh='滿員出擊';   desc='Team 達到 6/6 員';                          kind='team' }
    @{ slug='team-types-3';   name_zh='多元戰隊';   desc='Team 同時涵蓋至少 3 種屬性';                kind='team' }
    @{ slug='first-trade';    name_zh='首次交易';   desc='第一次 /gacha trade 完成';                  kind='train' }
    @{ slug='trade-5';        name_zh='交易達人';   desc='累計 5 次 trade';                           kind='train' }
    @{ slug='gym-1';          name_zh='道館初勝';   desc='打贏第一個道館';                            kind='battle' }
    @{ slug='gym-2';          name_zh='雙冠';       desc='打贏 2 個道館';                             kind='battle' }
    @{ slug='gym-4';          name_zh='半冠王';     desc='打贏 4 個道館';                             kind='battle' }
    @{ slug='gym-6';          name_zh='六冠';       desc='打贏 6 個道館';                             kind='battle' }
    @{ slug='gym-all';        name_zh='全道館征服'; desc='打贏全部 8 個 Gen 1 道館';                  kind='battle' }
    @{ slug='streak-5';       name_zh='連勝起步';   desc='戰鬥最高連勝 5 場';                          kind='battle' }
    @{ slug='streak-10';      name_zh='戰鬥不敗';   desc='戰鬥最高連勝 10 場';                        kind='battle' }
    @{ slug='streak-20';      name_zh='不敗傳說';   desc='戰鬥最高連勝 20 場';                        kind='battle' }
    @{ slug='shop-first';     name_zh='初次採購';   desc='第一次 /gacha buy 完成';                    kind='item' }
    @{ slug='master-ball-use'; name_zh='大師球使用者'; desc='用過 1 顆 master ball 抓寶可夢';         kind='item' }
    @{ slug='wallet-500';     name_zh='富甲一方';   desc='累積過 500 coin (歷史最高)';                kind='item' }
    @{ slug='elite-1';        name_zh='天王挑戰';   desc='擊敗第一位四大天王';                        kind='battle' }
    @{ slug='elite-4';        name_zh='四大天王';   desc='擊敗全部 4 位天王';                         kind='battle' }
    @{ slug='champion';       name_zh='冠軍之路';   desc='擊敗冠軍';                                  kind='battle' }
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
        $k = [string][int]$t.id
        if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 } else { $counts[$k] = 1 }
    }
    foreach ($k in $counts.Keys) { if ($counts[$k] -ge 3) { return $true } }
    return $false
}
function Count-DexTypes($state) {
    # How many distinct type1 across ever-caught species
    $set = @{}
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught -and $Dex.ContainsKey($k)) {
            $set[$Dex[$k].type1] = $true
        }
    }
    return $set.Count
}
function Count-TeamTypes($state) {
    if (-not $state.team) { return 0 }
    $set = @{}
    foreach ($t in $state.team) {
        $tid = [int]$t.id
        if ($Dex.ContainsKey([string]$tid)) { $set[$Dex[[string]$tid].type1] = $true }
    }
    return $set.Count
}
function Test-Achievement-Earned($state, [string]$slug) {
    switch ($slug) {
        'first-pull'        { return ([int]$state.stats.pulls_total -ge 1) }
        'pull-10'           { return ([int]$state.stats.pulls_total -ge 10) }
        'pull-50'           { return ([int]$state.stats.pulls_total -ge 50) }
        'pull-100'          { return ([int]$state.stats.pulls_total -ge 100) }
        'first-hr'          { return (Check-AnyOwnedHR $state) }
        'first-shiny'       { return ([int]$state.stats.shinies_total -ge 1) }
        'shiny-5'           { return ([int]$state.stats.shinies_total -ge 5) }
        'shiny-10'          { return ([int]$state.stats.shinies_total -ge 10) }
        'dex-10'            { return ((Count-Caught $state) -ge 15) }
        'dex-25'            { return ((Count-Caught $state) -ge 38) }
        'dex-50'            { return ((Count-Caught $state) -ge 76) }
        'dex-100'           { return ((Count-Caught $state) -ge 151) }
        'type-collector-5'  { return ((Count-DexTypes $state) -ge 5) }
        'type-collector-9'  { return ((Count-DexTypes $state) -ge 9) }
        'all-starters'      { return ((Has-CaughtEver $state 1) -and (Has-CaughtEver $state 4) -and (Has-CaughtEver $state 7)) }
        'all-fossils'       { return ((Has-CaughtEver $state 138) -and (Has-CaughtEver $state 140) -and (Has-CaughtEver $state 142)) }
        'all-legendary'     { return ((Has-CaughtEver $state 144) -and (Has-CaughtEver $state 145) -and (Has-CaughtEver $state 146) -and (Has-CaughtEver $state 150) -and (Has-CaughtEver $state 151)) }
        'first-evolve'      { return ([int]$state.stats.evolutions_done -ge 1) }
        'evolve-5'          { return ([int]$state.stats.evolutions_done -ge 5) }
        'evolve-stone'      { return ([int]$state.stats.stones_used -ge 1) }
        'buddy-l10'         { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 10) }
        'buddy-l25'         { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 25) }
        'buddy-l36'         { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 36) }
        'buddy-l50'         { return ($state.buddy -and (Get-Level ([int]$state.buddy.exp)) -ge 50) }
        'triple-clone'      { return (Check-TripleClone $state) }
        'team-full'         { return ($state.team -and $state.team.Count -ge 6) }
        'team-types-3'      { return ((Count-TeamTypes $state) -ge 3) }
        'first-trade'       { return ([int]$state.stats.trades_done -ge 1) }
        'trade-5'           { return ([int]$state.stats.trades_done -ge 5) }
        'gym-1'             { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 1) }
        'gym-2'             { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 2) }
        'gym-4'             { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 4) }
        'gym-6'             { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 6) }
        'gym-all'           { return ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 8) }
        'streak-5'          { return ([int]$state.battle_streak_best -ge 5) }
        'streak-10'         { return ([int]$state.battle_streak_best -ge 10) }
        'streak-20'         { return ([int]$state.battle_streak_best -ge 20) }
        'shop-first'        { return ([int]$state.stats.items_bought -ge 1) }
        'master-ball-use'   { return ([int]$state.stats.master_balls_used -ge 1) }
        'wallet-500'        { return ([int]$state.stats.coins_peak -ge 500) }
        'elite-1'           { return ($state.elite_beaten -and $state.elite_beaten.Count -ge 1) }
        'elite-4'           { return ($state.elite_beaten -and ($state.elite_beaten | Where-Object { $_ -ge 1 -and $_ -le 4 }).Count -ge 4) }
        'champion'          { return ($state.elite_beaten -and ($state.elite_beaten -contains 5)) }
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
    $kindOrder = @('pull','collection','dex','train','team','battle','item')
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
            pulls_total       = 0
            shinies_total     = 0
            evolutions_done   = 0
            trades_done       = 0
            items_bought      = 0
            stones_used       = 0
            master_balls_used = 0
            coins_peak        = 0
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
    # Batch 4 (per-slot exp): team rows used to be ints, now @{id,exp,shiny}.
    # Migrate any legacy int / id-only-hashtable rows; team[0] inherits buddy.exp
    # if its id matches the legacy buddy, else starts at 0.
    if ($state.team -and $state.team.Count -gt 0) {
        $needsMigration = $false
        foreach ($t in $state.team) {
            if ($t -is [int] -or $t -is [long] -or $t -is [double]) { $needsMigration = $true; break }
            if ($t -is [hashtable] -or $t -is [System.Collections.Specialized.OrderedDictionary]) {
                if (-not $t.Contains('exp')) { $needsMigration = $true; break }
            } else { $needsMigration = $true; break }
        }
        if ($needsMigration) {
            $oldBuddyId = if ($state.buddy -and $null -ne $state.buddy.id) { [int]$state.buddy.id } else { 0 }
            $oldBuddyExp = if ($state.buddy -and $null -ne $state.buddy.exp) { [int]$state.buddy.exp } else { 0 }
            $migrated = @()
            for ($i = 0; $i -lt $state.team.Count; $i++) {
                $row = $state.team[$i]
                $rid = if ($row -is [hashtable] -or $row -is [System.Collections.Specialized.OrderedDictionary]) { [int]$row.id } else { [int]$row }
                $rshiny = (Get-OwnedShinyCount $state $rid) -gt 0
                $rexp = if ($i -eq 0 -and $rid -eq $oldBuddyId) { $oldBuddyExp } else { 0 }
                $migrated += , ([ordered]@{ id = $rid; exp = $rexp; shiny = $rshiny })
            }
            $state.team = $migrated
        }
    }
    # team[0] is source of truth for buddy. Re-sync on every load so any
    # drift (e.g., statusline tick that missed team[0], legacy state) auto-heals.
    if ($state.team -and $state.team.Count -gt 0) { Sync-Buddy-From-Team $state }
    # Batch 5: items bag. Lazy-init to empty; missing keys default to 0 on read.
    if (-not $state.Contains('items') -or $null -eq $state.items) { $state.items = [ordered]@{} }
    if (-not $state.Contains('repel_sessions')) { $state.repel_sessions = 0 }
    # Daily login bonus tracking (batch 7)
    if (-not $state.Contains('last_daily_ep')) { $state.last_daily_ep = 0 }
    if (-not $state.Contains('daily_streak'))  { $state.daily_streak = 0 }
    # Elite Four / Champion progress (batch 7)
    if (-not $state.Contains('elite_beaten') -or $null -eq $state.elite_beaten) { $state.elite_beaten = @() }
    # Stats counters added in batch 6 (achievements expansion). Lazy-add missing keys.
    if (-not $state.stats.Contains('items_bought'))      { $state.stats.items_bought = 0 }
    if (-not $state.stats.Contains('stones_used'))       { $state.stats.stones_used = 0 }
    if (-not $state.stats.Contains('master_balls_used')) { $state.stats.master_balls_used = 0 }
    if (-not $state.stats.Contains('coins_peak'))        { $state.stats.coins_peak = [int]$state.coins }
    # coins_peak high-water: bump whenever we see a higher current balance.
    if ([int]$state.coins -gt [int]$state.stats.coins_peak) { $state.stats.coins_peak = [int]$state.coins }
    return $state
}

# Rebuild state.buddy as a view of team[0]. Keep the existing buddy.* shape so
# statusline.ps1 and Show-Trainer continue reading buddy.id / .exp / .shiny /
# .evolves_to / .evolve_level without per-call lookups.
function Sync-Buddy-From-Team($state) {
    if (-not $state.team -or $state.team.Count -eq 0) { $state.buddy = $null; return }
    $slot = $state.team[0]
    if (-not $slot -or $null -eq $slot.id) { return }
    $id = [int]$slot.id
    if (-not $Dex.ContainsKey([string]$id)) { return }
    $poke = $Dex[[string]$id]
    $slotNick = $null
    if (($slot -is [hashtable] -or $slot -is [System.Collections.Specialized.OrderedDictionary]) -and $slot.Contains('nickname')) {
        $slotNick = $slot.nickname
    }
    $state.buddy = [ordered]@{
        id           = $id
        shiny        = [bool]$slot.shiny
        exp          = [int]$slot.exp
        nickname     = $slotNick
        name_zh      = $poke.name_zh
        type1        = $poke.type1
        stage        = [int]$poke.stage
        evolves_to   = $poke.evolves_to
        evolve_level = $poke.evolve_level
    }
}

# --- Cross-process lock around state read/write ---
# Named mutex prefixed with Global\ so it spans Claude Code sessions on Windows
# (Local namespace is per-terminal-session and wouldn't catch the race between
# gacha.ps1 and statusline.ps1 running in different CC sessions). statusline.ps1
# carries a duplicate of these helpers — keep in sync.
function New-StateLock {
    return New-Object System.Threading.Mutex($false, 'Global\PokemonGachaState')
}
function Acquire-StateLock($mutex, [int]$timeoutMs = 5000) {
    if ($null -eq $mutex) { return $false }
    try {
        return $mutex.WaitOne($timeoutMs)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous holder crashed without releasing. We now own the mutex —
        # treat as acquired. The state file's backup-on-write design means
        # we can recover from any partial write that crash left behind.
        return $true
    }
}
function Release-StateLock($mutex) {
    if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
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
    # Atomic write via .tmp + Move-Item so concurrent readers never see a
    # 0-byte truncate window (the issue that caused the state-wipe earlier).
    $tmpFile = "$StateFile.tmp"
    $state | ConvertTo-Json -Depth 12 | Out-File -FilePath $tmpFile -Encoding utf8 -Force
    Move-Item -Path $tmpFile -Destination $StateFile -Force
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
    # Ball priority: master > ultra > great > plain. Best one is auto-consumed.
    $ballUsed = 'plain'
    if ((Get-ItemCount $state 'master-ball') -gt 0) {
        Remove-BagItem $state 'master-ball' 1 | Out-Null
        $state.stats.master_balls_used = [int]$state.stats.master_balls_used + 1
        $rate = 1.0   # guaranteed
        $ballUsed = 'master'
    } elseif ((Get-ItemCount $state 'ultra-ball') -gt 0) {
        Remove-BagItem $state 'ultra-ball' 1 | Out-Null
        $rate = [Math]::Min(1.0, $rate * 2.0)
        $ballUsed = 'ultra'
    } elseif ((Get-ItemCount $state 'great-ball') -gt 0) {
        Remove-BagItem $state 'great-ball' 1 | Out-Null
        $rate = [Math]::Min(1.0, $rate * 1.5)
        $ballUsed = 'great'
    }
    $roll = (Get-Random -Maximum 10000) / 10000.0
    $caught = ($roll -lt $rate)
    $glyph = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
    $name = Color '38;5;255' $poke.name_zh
    # === STATE MUTATION (commit BEFORE animation, same pattern as Pull-Pack/Trade-Dupes) ===
    $shiny = $false
    $attemptsLeftAfter = 0
    if ($caught) {
        $shiny = Roll-Shiny
        Add-Owned $state $id $shiny
        if ($shiny) { $state.stats.shinies_total = [int]$state.stats.shinies_total + 1 }
        $state.encounter = $null
    } else {
        $state.encounter.attempts_left = [int]$state.encounter.attempts_left - 1
        $attemptsLeftAfter = [int]$state.encounter.attempts_left
        if ($attemptsLeftAfter -le 0) { $state.encounter = $null }
    }
    Save-State $state

    # === ANIMATION (purely cosmetic from here on) ===
    Print ''
    $ballTag = switch ($ballUsed) {
        'master' { Color '1;38;5;213' '>> MASTER BALL THROWN <<' }
        'ultra'  { Color '1;38;5;220' '>> ULTRA BALL THROWN <<' }
        'great'  { Color '1;38;5;39'  '>> GREAT BALL THROWN <<' }
        default  { Dim '>> POKE BALL THROWN <<' }
    }
    Print "  $ballTag"
    Start-Sleep -Milliseconds 400
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 350
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 350
    Print "  $(Dim '...shake...')"
    Start-Sleep -Milliseconds 400
    if ($caught) {
        # Reveal sprite line-by-line, same pacing as Pull-Pack
        Print ''
        $spritePath = Join-Path $ClaudeDir "sprites\regular\$id.txt"
        if (Test-Path $spritePath) {
            Get-Content $spritePath -Encoding UTF8 | ForEach-Object {
                Print $_
                Start-Sleep -Milliseconds 90
            }
        }
        Start-Sleep -Milliseconds 300
        $shinyTag = if ($shiny) { ' ' + (Gold "$SPARKLE SHINY $SPARKLE") } else { '' }
        $rarityBadge = Format-RarityBadge $rarity $shiny
        Print ''
        Print "  $(Color '1;38;5;82' 'GOTCHA!')  $rarityBadge  $glyph #$('{0:D3}' -f $id) $name$shinyTag"
        Print ''
        Print (Dim "  Catch rate was $([Math]::Round($rate * 100, 1))%. Coins: $([int]$state.coins).")
    } else {
        if ($attemptsLeftAfter -le 0) {
            Print "  $(Color '38;5;196' 'Oh no! The wild') $glyph #$('{0:D3}' -f $id) $name $(Color '38;5;196' 'broke free and fled!')"
            Print ''
            Print (Dim "  Catch rate was $([Math]::Round($rate * 100, 1))%. Coins: $([int]$state.coins).")
        } else {
            Print "  $(Color '38;5;208' 'The pokemon broke free!')  $glyph #$('{0:D3}' -f $id) $name $(Dim "(attempts left: $attemptsLeftAfter)")"
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
        # Persist state BEFORE the ~2s reveal animation. The /gacha skill polls
        # state.stats.pulls_total to know when the pull "completed"; without this
        # early save, the poll has to wait for the entire animation + dispatcher's
        # final Save-State, which is racy with the skill's fixed-sleep timeout.
        # Outer dispatch will still Save-State at end (cheap, idempotent under
        # the mutex we already hold).
        Save-State $state

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
    if (-not $state.team) { $state.team = @() }

    # If id already in team, promote that slot (preserves its exp). Otherwise
    # create a fresh slot with exp=0. Either way the chosen slot becomes team[0].
    $existing = $null
    $rest = @()
    foreach ($s in $state.team) {
        if ($null -eq $existing -and [int]$s.id -eq $id) { $existing = $s }
        else { $rest += , $s }
    }
    $leader = if ($existing) { $existing } else { [ordered]@{ id=$id; exp=0; shiny=$shiny } }
    $leader.shiny = $shiny   # keep shiny state fresh in case it changed since slot created
    $newTeam = @($leader)
    foreach ($s in $rest) { if ($newTeam.Count -lt 6) { $newTeam += , $s } }
    $state.team = $newTeam
    Sync-Buddy-From-Team $state

    $glyph = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
    $name = if ($shiny) { Gold $poke.name_zh } else { Color '38;5;255' $poke.name_zh }
    $shinyTag = if ($shiny) { Gold ' (shiny)' } else { '' }
    Print ''
    if ($existing) {
        $kept = Get-Level ([int]$leader.exp)
        Print "  Buddy switched: $glyph #$('{0:D3}' -f $id) $name$shinyTag $(Dim "(kept LV. $kept, exp $([int]$leader.exp))")"
    } else {
        Print "  Buddy set: $glyph #$('{0:D3}' -f $id) $name$shinyTag $(Dim '(fresh slot, exp 0)')"
    }
    Print ''
}

function Add-Team($state, [int]$id) {
    if (-not $Dex.ContainsKey([string]$id)) { Print (Color '38;5;196' "Unknown pokemon id: $id"); return }
    $owned = Get-OwnedCount $state $id
    if ($owned -lt 1) { Print (Color '38;5;196' "You don't own $($Dex[[string]$id].name_zh) (#$id)."); return }
    if (-not $state.team) { $state.team = @() }
    # Allow duplicates in team up to how many copies you actually own.
    $inTeam = @($state.team | Where-Object { [int]$_.id -eq [int]$id }).Count
    if ($inTeam -ge $owned) {
        Print (Color '38;5;196' "You only own $owned x $($Dex[[string]$id].name_zh) (#$id) and all are already in your team.")
        return
    }
    if ($state.team.Count -ge 6) { Print (Color '38;5;196' "Team is full (6/6). Remove someone first: /gacha team remove <id>"); return }
    $shiny = (Get-OwnedShinyCount $state $id) -gt 0
    $state.team += , ([ordered]@{ id=$id; exp=0; shiny=$shiny })
    Sync-Buddy-From-Team $state
    $newCount = @($state.team | Where-Object { [int]$_.id -eq [int]$id }).Count
    $copyTag = if ($newCount -gt 1) { " (copy $newCount of $owned)" } else { '' }
    Print ''
    Print "  Added $($Dex[[string]$id].name_zh) (#$id)$copyTag to team. Slot $([int]$state.team.Count)/6. $(Dim '(fresh slot, exp 0)')"
    Print ''
}

function Move-Team($state, [int]$id, [int]$newPos1) {
    if (-not $state.team -or $state.team.Count -eq 0) { Print (Color '38;5;196' "Team is empty."); return }
    $teamIds = @($state.team | ForEach-Object { [int]$_.id })
    if (-not ($teamIds -contains [int]$id)) { Print (Color '38;5;196' "Pokemon #$id not in team."); return }
    $newIdx = $newPos1 - 1
    if ($newIdx -lt 0 -or $newIdx -ge $state.team.Count) {
        Print (Color '38;5;196' "Position $newPos1 out of range (1..$($state.team.Count)).")
        return
    }
    if ($newIdx -eq 0) {
        Print (Color '38;5;196' "Position 1 is the LEADER slot. Use /gacha buddy $id to switch leader.")
        return
    }
    # Pull out the FIRST matching slot (preserves which copy moves under dupes A/B/C).
    $without = @()
    $picked = $null
    foreach ($s in $state.team) {
        if ($null -eq $picked -and [int]$s.id -eq [int]$id) { $picked = $s }
        else { $without += , $s }
    }
    $reordered = @()
    for ($i = 0; $i -lt $without.Count; $i++) {
        if ($i -eq $newIdx) { $reordered += , $picked }
        $reordered += , $without[$i]
    }
    if ($newIdx -ge $without.Count) { $reordered += , $picked }
    $state.team = $reordered
    Sync-Buddy-From-Team $state
    Print ''
    Print "  Moved $($Dex[[string]$id].name_zh) (#$id) to position $newPos1."
    Print ''
}

function Remove-Team($state, [int]$id) {
    if (-not $state.team -or $state.team.Count -eq 0) { Print (Color '38;5;196' "Team is empty."); return }
    $teamIds = @($state.team | ForEach-Object { [int]$_.id })
    if (-not ($teamIds -contains [int]$id)) { Print (Color '38;5;196' "Pokemon #$id not in team."); return }
    if ($state.team.Count -eq 1) {
        Print (Color '38;5;196' "Can't remove the only team member. Set a different buddy first.")
        return
    }
    # If multiple copies, remove the LAST occurrence (preserves leader at index 0).
    $occurrences = @()
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        if ([int]$state.team[$i].id -eq [int]$id) { $occurrences += $i }
    }
    $removeAt = $occurrences[-1]
    if ($removeAt -eq 0 -and $state.team.Count -gt 1) {
        Print (Color '38;5;196' "Can't remove the LEADER while team has others. Switch leader first: /gacha buddy <other-id>")
        return
    }
    $droppedExp = [int]$state.team[$removeAt].exp
    $newArr = @()
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        if ($i -ne $removeAt) { $newArr += , $state.team[$i] }
    }
    $state.team = $newArr
    Sync-Buddy-From-Team $state
    $remaining = @($state.team | Where-Object { [int]$_.id -eq [int]$id }).Count
    $remTag = if ($remaining -gt 0) { " ($remaining copy(s) still in team)" } else { '' }
    $expTag = if ($droppedExp -gt 0) { " $(Dim "(lost $droppedExp exp on that slot)")" } else { '' }
    Print ''
    Print "  Removed $($Dex[[string]$id].name_zh) (#$id) from team. Slot $([int]$state.team.Count)/6.$remTag$expTag"
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
        $k = [string][int]$t.id
        if ($dupTotals.ContainsKey($k)) { $dupTotals[$k] = $dupTotals[$k] + 1 } else { $dupTotals[$k] = 1 }
    }
    $dupSeen = @{}
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        $slot = $state.team[$i]
        $id = [int]$slot.id
        if (-not $Dex.ContainsKey([string]$id)) { continue }
        $p = $Dex[[string]$id]
        $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
        $shiny = [bool]$slot.shiny
        $nick = if (($slot -is [hashtable] -or $slot -is [System.Collections.Specialized.OrderedDictionary]) -and $slot.Contains('nickname') -and $slot.nickname) { [string]$slot.nickname } else { $null }
        $displayName = if ($nick) { "$nick $(Dim "($($p.name_zh))")" } else { $p.name_zh }
        $name = if ($shiny -and -not $nick) { Gold $displayName } else { Color '38;5;255' $displayName }
        $tag = if ($i -eq 0) { Color '1;38;5;226' '[LEADER]' } else { Dim "  team    " }
        $slotLvl = Get-Level ([int]$slot.exp)
        $lvlTag = "$(Color '1;38;5;82' "LV. $slotLvl") $(Dim "(exp $([int]$slot.exp))")"
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
# Returns array of moves for a combatant. Signature kit wins if defined; otherwise
# auto-derives from type1/type2 + stage (stage 0 mons get only type1-weak, stage 1+
# get type1-strong too, dual types always get type2-weak as coverage).
function Get-Moveset($c) {
    $id = [int]$c.id
    if ($SignatureMoves.ContainsKey($id)) { return $SignatureMoves[$id] }
    $moves = @()
    $t1 = $c.type1
    $t2 = $c.type2
    $stage = if ($Dex.ContainsKey([string]$id)) { [int]$Dex[[string]$id].stage } else { 0 }
    if ($TypeMoves.ContainsKey($t1)) {
        $w = $TypeMoves[$t1][0]
        $moves += @{name=$w.name; type=$t1; power=$w.power}
        if ($stage -ge 1) {
            $s = $TypeMoves[$t1][1]
            $moves += @{name=$s.name; type=$t1; power=$s.power}
        }
    }
    if ($t2 -and $TypeMoves.ContainsKey($t2)) {
        $w = $TypeMoves[$t2][0]
        $moves += @{name=$w.name; type=$t2; power=$w.power}
    }
    if ($moves.Count -eq 0) {
        $moves += @{name='掙扎'; type='normal'; power=30}   # fallback for missing type data
    }
    return ,$moves
}
# AI picks the move with highest power * typeMul against current defender.
# 0-power moves (status-like signature entries) get score 0, so they're chosen only
# when literally nothing else hits.
function Pick-Move($attacker, $defender) {
    $moves = Get-Moveset $attacker
    $best = $moves[0]
    $bestScore = -1.0
    foreach ($m in $moves) {
        $mul = Get-TypeMultiplier $m.type $defender.type1 $defender.type2
        $score = [double]$m.power * $mul
        if ($score -gt $bestScore) { $best = $m; $bestScore = $score }
    }
    return $best
}

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

function Compute-Damage($atk, $def, $move) {
    $moveType  = [string]$move.type
    $movePower = [int]$move.power
    $isSpecial = $SpecialTypes -contains $moveType
    $atkStat = if ($isSpecial) { [int]$atk.stats.spa } else { [int]$atk.stats.atk }
    $defStat = if ($isSpecial) { [int]$def.stats.spd } else { [int]$def.stats.def }
    $base = ((2.0 * $atk.level + 10) * $movePower * $atkStat / (250.0 * $defStat)) + 2
    # STAB only when move type matches one of the attacker's own types
    $stab = if ($moveType -eq $atk.type1 -or ($atk.type2 -and $moveType -eq $atk.type2)) { 1.5 } else { 1.0 }
    $typeMul = Get-TypeMultiplier $moveType $def.type1 $def.type2
    $variance = (Get-Random -Minimum 85 -Maximum 101) / 100.0
    # Critical hit: 1/16 base chance, x2 damage (no stat-stage interactions)
    $isCrit = ((Get-Random -Maximum 16) -eq 0)
    $critMul = if ($isCrit) { 2.0 } else { 1.0 }
    $dmg = [int][Math]::Floor($base * $stab * $typeMul * $variance * $critMul)
    if ($dmg -lt 1 -and $typeMul -gt 0 -and $movePower -gt 0) { $dmg = 1 }
    if ($typeMul -eq 0 -or $movePower -le 0) { $dmg = 0 }
    return @{ damage = $dmg; typeMul = $typeMul; isSpecial = $isSpecial; isCrit = $isCrit; move = $move }
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
    $move = Pick-Move $attacker $defender
    $r = Compute-Damage $attacker $defender $move
    $effTag = ''
    if     ($r.typeMul -eq 0)    { $effTag = Color '38;5;245' '   (沒有效果...)' }
    elseif ($r.typeMul -ge 2)    { $effTag = Color '1;38;5;226' '   (效果絕佳!)' }
    elseif ($r.typeMul -le 0.5)  { $effTag = Color '38;5;245' '   (效果不太好)' }
    $critTag = if ($r.isCrit -and $r.damage -gt 0) { '  ' + (Color '1;38;5;220' '★ 擊出要害！') } else { '' }
    $attName = Format-Combatant $attacker
    $moveCol = if ($TypeColor.ContainsKey($r.move.type)) { $TypeColor[$r.move.type] } else { '38;5;255' }
    $moveTxt = Color $moveCol $r.move.name
    Print "  $attName 使出 $moveTxt！$effTag$critTag"
    Start-Sleep -Milliseconds 600
    if ($r.typeMul -eq 0) {
        Print (Dim "  → 但是 #$('{0:D3}' -f $defender.id) $($defender.name_zh) 不受影響.")
    } elseif ($r.damage -le 0) {
        Print (Dim "  → 但是沒有造成傷害.")
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
    # Each slot fights at its own level (per-slot exp). Build-Combatant order
    # matches state.team order so Challenge-Gym can map combatant.hp_cur back
    # to the right slot when awarding exp.
    $arr = @()
    foreach ($slot in $state.team) {
        $id = [int]$slot.id
        if (-not $Dex.ContainsKey([string]$id)) { continue }
        $lvl = Get-Level ([int]$slot.exp)
        if ($lvl -lt 1) { $lvl = 1 }
        $arr += , (Build-Combatant $id $lvl ([bool]$slot.shiny))
    }
    if ($arr.Count -eq 0) { return ,$arr }
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

function Claim-Daily($state) {
    $nowEp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $lastEp = if ($state.last_daily_ep) { [int]$state.last_daily_ep } else { 0 }
    $hoursSince = if ($lastEp -gt 0) { [Math]::Floor(($nowEp - $lastEp) / 3600.0) } else { 99 }
    if ($hoursSince -lt 24) {
        $waitH = 24 - $hoursSince
        Print ''
        Print "  $(Color '38;5;245' '冷卻中。')再 $(Color '1;38;5;220' "$waitH 小時") 才能領下一次每日獎勵。"
        Print "  $(Dim "目前 daily streak: $([int]$state.daily_streak)")"
        Print ''
        return
    }
    # If user missed a day (>48h since last claim), streak resets to 1; otherwise +1
    $oldStreak = [int]$state.daily_streak
    $newStreak = if ($hoursSince -ge 48 -or $lastEp -eq 0) { 1 } else { $oldStreak + 1 }
    # Coin reward scales with streak: 5 base + min(streak, 7) bonus, so day 7+ gives 12 coin
    $coinReward = 5 + [Math]::Min($newStreak, 7)
    $state.coins = [int]$state.coins + $coinReward
    $state.last_daily_ep = $nowEp
    $state.daily_streak = $newStreak
    Print ''
    Print (Bold "=== Daily Login Bonus ===")
    Print ''
    Print "  $(Color '1;38;5;220' "+$coinReward coin")  $(Dim "(base 5 + streak bonus $([Math]::Min($newStreak, 7)))")"
    # On streak milestones, also drop a free item
    $bonusItem = $null
    if ($newStreak -eq 7)  { $bonusItem = 'great-ball' }
    if ($newStreak -eq 14) { $bonusItem = 'ultra-ball' }
    if ($newStreak -eq 30) { $bonusItem = 'master-ball' }
    if ($bonusItem) {
        Add-BagItem $state $bonusItem 1
        $it = $Items[$bonusItem]
        $g = Color $it.color "$($it.glyph)"
        Print "  $(Color '1;38;5;82' '★ Streak milestone:') $g $(Color '1;38;5;255' "$($it.name_zh) × 1") $(Dim '(免費獎勵)')"
    }
    Print "  $(Dim "Daily streak: $oldStreak → $newStreak.  Coins now: $([int]$state.coins).")"
    Print ''
}

function Rename-Pokemon($state, [int]$id, [string]$nickname) {
    if (-not $state.team -or $state.team.Count -eq 0) { Print (Color '38;5;196' "Team is empty."); return }
    if (-not $Dex.ContainsKey([string]$id)) { Print (Color '38;5;196' "Unknown pokemon id: $id"); return }
    # Pick the highest-exp slot for that id; ties → first.
    $bestIdx = -1
    $bestExp = -1
    for ($i = 0; $i -lt $state.team.Count; $i++) {
        if ([int]$state.team[$i].id -eq $id -and [int]$state.team[$i].exp -gt $bestExp) {
            $bestExp = [int]$state.team[$i].exp
            $bestIdx = $i
        }
    }
    if ($bestIdx -lt 0) { Print (Color '38;5;196' "#$id not in team. /gacha team add $id first."); return }
    # Strip dangerous chars; cap at 16 visible chars
    $nick = $nickname.Trim()
    if ($nick.Length -eq 0) {
        # Clear nickname
        if ($state.team[$bestIdx].PSObject.Properties.Name -contains 'nickname' -or $state.team[$bestIdx].Contains('nickname')) {
            $state.team[$bestIdx].nickname = $null
        }
        Sync-Buddy-From-Team $state
        Print "  Nickname cleared for #$id (slot $($bestIdx + 1))."
        return
    }
    if ($nick.Length -gt 16) { $nick = $nick.Substring(0, 16) }
    if ($state.team[$bestIdx] -is [hashtable] -or $state.team[$bestIdx] -is [System.Collections.Specialized.OrderedDictionary]) {
        $state.team[$bestIdx].nickname = $nick
    }
    Sync-Buddy-From-Team $state
    $p = $Dex[[string]$id]
    $g = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
    Print ''
    $nickQuoted = '「' + $nick + '」'
    Print "  $g #$('{0:D3}' -f $id) $(Color '38;5;255' $p.name_zh) (slot $($bestIdx + 1)) → 暱稱 $(Color '1;38;5;220' $nickQuoted)"
    Print ''
}

function Show-Moves([int]$id) {
    if (-not $Dex.ContainsKey([string]$id)) {
        Print (Color '38;5;196' "Unknown pokemon id: $id")
        return
    }
    $p = $Dex[[string]$id]
    # Build a fake combatant so Get-Moveset can do its thing
    $fake = @{ id = $id; type1 = $p.type1; type2 = $p.type2 }
    $moves = Get-Moveset $fake
    $isSig = $SignatureMoves.ContainsKey($id)

    $glyph = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
    $t2tag = if ($p.type2) { " / $($p.type2)" } else { '' }
    Print ''
    Print (Bold "=== Moveset: $glyph #$('{0:D3}' -f $id) $(Color '38;5;255' $p.name_zh) ===")
    Print "  $(Dim "$($p.type1)$t2tag · stage $($p.stage)") $(if ($isSig) { Color '1;38;5;220' '[signature kit]' } else { Dim '[auto-derived]' })"
    Print ''
    foreach ($m in $moves) {
        $mc = if ($TypeColor.ContainsKey($m.type)) { $TypeColor[$m.type] } else { '38;5;255' }
        $mg = if ($TypeGlyph.ContainsKey($m.type)) { $TypeGlyph[$m.type] } else { '?' }
        $stab = ($m.type -eq $p.type1 -or ($p.type2 -and $m.type -eq $p.type2))
        $stabTag = if ($stab) { Color '1;38;5;220' ' STAB' } else { '' }
        $power = [int]$m.power
        $powerTag = if ($power -eq 0) { Color '38;5;245' 'utility' } else { "pwr $power" }
        Print "  $(Color $mc "$mg") $(Color '38;5;255' $m.name)  $(Dim "($($m.type))")  $(Color '38;5;220' $powerTag)$stabTag"
    }
    Print ''
}

function Show-Theme($state) {
    $cur = if ($state.theme -and $Themes.ContainsKey([string]$state.theme)) { [string]$state.theme } else { 'gba' }
    Print ''
    Print (Bold '=== Statusline Theme ===')
    Print ''
    foreach ($k in @('gba','crystal','dark')) {
        $t = $Themes[$k]
        $marker = if ($k -eq $cur) { Color '1;38;5;82' '* ' } else { '  ' }
        $swatch = "$(Color $t.outer '████') $(Color $t.frame '╔══╗')"
        Print "  $marker$(Color '1;38;5;255' $k.PadRight(10)) $swatch  $(Dim $t.desc)"
    }
    Print ''
    Print "  $(Dim '/gacha theme <name> 切換 (gba / crystal / dark)')"
    Print ''
}

function Set-Theme($state, [string]$name) {
    $n = $name.ToLower()
    if (-not $Themes.ContainsKey($n)) {
        Print (Color '38;5;196' "Unknown theme: $name. Available: gba / crystal / dark")
        return
    }
    $state.theme = $n
    $t = $Themes[$n]
    Print ''
    Print "  $(Color '1;38;5;82' '✓') 主題已切換成 $(Color $t.outer $n) — $(Dim $t.desc)"
    Print "  $(Dim '開新 Claude Code session 即可看到生效。')"
    Print ''
}

function Get-ItemCount($state, [string]$slug) {
    if (-not $state.items -or -not $state.items.Contains($slug)) { return 0 }
    return [int]$state.items[$slug]
}
function Add-BagItem($state, [string]$slug, [int]$n = 1) {
    if (-not $state.items) { $state.items = [ordered]@{} }
    $cur = Get-ItemCount $state $slug
    $state.items[$slug] = $cur + $n
}
function Remove-BagItem($state, [string]$slug, [int]$n = 1) {
    $cur = Get-ItemCount $state $slug
    if ($cur -lt $n) { return $false }
    $new = $cur - $n
    if ($new -eq 0) { $state.items.Remove($slug) | Out-Null } else { $state.items[$slug] = $new }
    return $true
}

function Show-Shop($state) {
    Print ''
    Print (Bold '=== Shop ===')
    Print ''
    Print "  $(Dim 'Coins:') $(Color '1;38;5;220' "$([int]$state.coins)")"
    Print ''
    foreach ($slug in $Items.Keys) {
        $it = $Items[$slug]
        $g = Color $it.color "$($it.glyph)"
        $name = Color '1;38;5;255' $it.name_zh
        $costTag = Color '1;38;5;220' "$($it.cost) coin"
        $slugTag = Dim "($slug)"
        Print "  $g $name $slugTag"
        Print "    $costTag  $(Dim $it.desc)"
        Print ''
    }
    Print "  $(Dim '/gacha buy <slug> [N]   ·   /gacha items 看現有道具')"
    Print ''
}

function Show-Items($state) {
    Print ''
    Print (Bold '=== Bag (items) ===')
    Print ''
    if (-not $state.items -or $state.items.Count -eq 0) {
        Print "  $(Dim '(empty) — /gacha shop 看買什麼')"
        Print ''
        return
    }
    foreach ($slug in $state.items.Keys) {
        $cnt = [int]$state.items[$slug]
        if ($cnt -le 0) { continue }
        $it = $Items[$slug]
        if ($it) {
            $g = Color $it.color "$($it.glyph)"
            Print "  $g $(Color '1;38;5;255' $it.name_zh)  $(Color '1;38;5;220' "× $cnt")  $(Dim $it.desc)"
        } else {
            # Unknown slug (e.g. items added by future version) — render minimal
            Print "  $(Dim "$slug")  $(Color '1;38;5;220' "× $cnt")"
        }
    }
    Print ''
    Print "  $(Dim '/gacha use <slug>   ·   /gacha shop 補貨')"
    Print ''
}

function Buy-Item($state, [string]$slug, [int]$n) {
    if ($n -lt 1) { $n = 1 }
    $s = $slug.ToLower()
    if (-not $Items.Contains($s)) {
        Print (Color '38;5;196' "Unknown item: $slug. Available: $(($Items.Keys) -join ', ')")
        return
    }
    $it = $Items[$s]
    $total = [int]$it.cost * $n
    if ([int]$state.coins -lt $total) {
        Print (Color '38;5;196' "Need $total coin ($($it.cost) × $n); have $([int]$state.coins).")
        return
    }
    $state.coins = [int]$state.coins - $total
    Add-BagItem $state $s $n
    $state.stats.items_bought = [int]$state.stats.items_bought + $n
    $g = Color $it.color "$($it.glyph)"
    Print ''
    Print "  $g $(Color '1;38;5;255' "$($it.name_zh) × $n") 入手  $(Dim "(-$total coin, $(Get-ItemCount $state $s) total)")"
    Print "  $(Dim "Coins: $([int]$state.coins)")"
    Print ''
}

function Use-Item($state, [string]$slug) {
    $s = $slug.ToLower()
    if (-not $Items.Contains($s)) {
        Print (Color '38;5;196' "Unknown item: $slug")
        return
    }
    if ((Get-ItemCount $state $s) -lt 1) {
        Print (Color '38;5;196' "You don't have any $($Items[$s].name_zh).  /gacha shop 去買")
        return
    }
    $it = $Items[$s]
    switch ($it.use) {
        'buddy-exp' {
            if (-not $state.team -or $state.team.Count -eq 0) {
                Print (Color '38;5;196' 'No buddy set; use /gacha buddy <id> first.')
                return
            }
            Remove-BagItem $state $s 1 | Out-Null
            $oldExp = [int]$state.team[0].exp
            $oldLvl = Get-Level $oldExp
            $state.team[0].exp = $oldExp + 10
            $newLvl = Get-Level $state.team[0].exp
            Sync-Buddy-From-Team $state
            $g = Color $it.color "$($it.glyph)"
            $bp = $Dex[[string]([int]$state.team[0].id)]
            $bg = Color $TypeColor[$bp.type1] "$($TypeGlyph[$bp.type1])"
            Print ''
            $lvlDelta = if ($newLvl -gt $oldLvl) { ' ' + (Color '1;38;5;82' "(LV. $oldLvl → $newLvl !)") } else { '' }
            Print "  $g 使用 $(Color '1;38;5;255' $it.name_zh) — $bg #$('{0:D3}' -f $bp.id) $(Color '1;38;5;255' $bp.name_zh) +10 exp$lvlDelta"
            Print "  $(Dim "exp $oldExp → $($state.team[0].exp)  ·  剩 $(Get-ItemCount $state $s) 顆")"
            Print ''
        }
        'catch-boost' {
            Print "  $(Dim "$($it.name_zh) 會在下次 /gacha catch 時自動使用，不用手動 use。")"
            Print ''
        }
        'repel' {
            Remove-BagItem $state $s 1 | Out-Null
            $existing = if ($state.repel_sessions) { [int]$state.repel_sessions } else { 0 }
            $state.repel_sessions = $existing + 10
            $g = Color $it.color "$($it.glyph)"
            Print ''
            Print "  $g 使用 $(Color '1;38;5;255' $it.name_zh) — 接下來 $(Color '1;38;5;220' "$($state.repel_sessions) 個 session") 不會 spawn wild pokémon"
            Print "  $(Dim "剩 $(Get-ItemCount $state $s) 個。已 pending encounter 不受影響。")"
            Print ''
        }
        'stone' {
            # Find the team slot whose dex_id maps to THIS stone (StoneEvolutions),
            # take the one with highest exp; bypass LV gate; evolve in place.
            if (-not $state.team -or $state.team.Count -eq 0) {
                Print (Color '38;5;196' 'Team is empty.')
                return
            }
            $bestIdx = -1
            $bestExp = -1
            for ($i = 0; $i -lt $state.team.Count; $i++) {
                $tid = [int]$state.team[$i].id
                if ($StoneEvolutions.ContainsKey($tid) -and $StoneEvolutions[$tid] -eq $s) {
                    if ([int]$state.team[$i].exp -gt $bestExp) {
                        $bestExp = [int]$state.team[$i].exp
                        $bestIdx = $i
                    }
                }
            }
            if ($bestIdx -lt 0) {
                $eligible = ($StoneEvolutions.Keys | Where-Object { $StoneEvolutions[$_] -eq $s } | ForEach-Object { "#$('{0:D3}' -f $_) $($Dex[[string]$_].name_zh)" }) -join ', '
                Print (Color '38;5;196' "Team 裡沒有可以用 $($it.name_zh) 進化的寶可夢. 可用對象：$eligible")
                return
            }
            $slot = $state.team[$bestIdx]
            $tid = [int]$slot.id
            $poke = $Dex[[string]$tid]
            if ($null -eq $poke.evolves_to) {
                Print (Color '38;5;196' "$($poke.name_zh) 沒有可進化路徑 (dex 資料異常).")
                return
            }
            $hadShiny = [bool]$slot.shiny
            Remove-BagItem $state $s 1 | Out-Null
            $state.stats.stones_used = [int]$state.stats.stones_used + 1
            Remove-Owned $state $tid 1 | Out-Null
            if ($hadShiny -and $state.owned.Contains([string]$tid) -and [int]$state.owned[[string]$tid].shiny_count -gt 0) {
                $state.owned[[string]$tid].shiny_count = [int]$state.owned[[string]$tid].shiny_count - 1
            }
            Add-Owned $state ([int]$poke.evolves_to) $hadShiny
            $state.stats.evolutions_done = [int]$state.stats.evolutions_done + 1
            $state.team[$bestIdx].id = [int]$poke.evolves_to
            $state.team[$bestIdx].shiny = $hadShiny
            if ($bestIdx -eq 0) { Sync-Buddy-From-Team $state }

            $next = $Dex[[string]$poke.evolves_to]
            $g  = Color $it.color "$($it.glyph)"
            $g1 = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
            $g2 = Color $TypeColor[$next.type1] "$($TypeGlyph[$next.type1])"
            $shinyTag = if ($hadShiny) { Gold ' *shiny preserved*' } else { '' }
            $slotTag = "$(Dim "(slot $($bestIdx + 1), kept exp $([int]$slot.exp))")"
            Print ''
            Print "  $g 使用 $(Color '1;38;5;255' $it.name_zh)"
            Print "  $g1 $($poke.name_zh) (#$tid) $ARROW $g2 $(Color '1;38;5;255' $next.name_zh) (#$($next.id))$shinyTag  $slotTag"
            Print "  $(Dim "剩 $(Get-ItemCount $state $s) 個.  Note: 沒消耗 coin，這是石頭的優勢。")"
            Print ''
        }
        default {
            Print (Color '38;5;196' "Item $($it.name_zh) 沒有對應的 use 動作")
        }
    }
}
function Show-Badges($state) {
    $beaten = @{}
    if ($state.gyms_beaten) {
        foreach ($g in $state.gyms_beaten) { $beaten[[int]$g] = $true }
    }
    $earned = $beaten.Count
    $total = $GymLeaders.Count
    Print ''
    Print (Bold "=== Gym Badges ($earned/$total) ===")
    Print ''
    foreach ($gym in $GymLeaders) {
        $i = [int]$gym.idx
        $bg = $BadgeGlyphs[$i]
        $hasBadge = [bool]$beaten[$i]
        if ($hasBadge) {
            $check = Color '1;38;5;82' '✓'
            $badgeArt = Color $bg.color "$($bg.glyph)"
            $badgeName = Color '1;38;5;220' $gym.badge
            $cityLeader = Color '38;5;255' "$($gym.city) · $($gym.leader_name)"
            Print "  $check $badgeArt  $badgeName  $(Dim "Gym #$i") $cityLeader"
        } else {
            $check = Color '38;5;238' '☐'
            $badgeArt = Dim "$($bg.glyph)"
            $badgeName = Dim $gym.badge
            $cityLeader = Dim "$($gym.city) · $($gym.leader_name)"
            Print "  $check $badgeArt  $badgeName  $(Dim "Gym #$i") $cityLeader"
        }
    }
    Print ''
    Print "  $(Dim '/gacha gym <N> 挑戰; /gacha gyms 看 leader 屬性與等級.')"
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
        $leadExp = $gym.level
        $sideExp = [int][Math]::Floor($gym.level / 4)
        $state.coins = [int]$state.coins + $coinReward
        # Team[0] (buddy) gets full reward; other slots get the side-exp ONLY
        # if they survived (hp_cur > 0 in the userTeam combatant we built).
        $sideAwarded = 0
        if ($state.team -and $state.team.Count -gt 0) {
            $state.team[0].exp = [int]$state.team[0].exp + $leadExp
            for ($i = 1; $i -lt [Math]::Min($state.team.Count, $userTeam.Count); $i++) {
                if ([int]$userTeam[$i].hp_cur -gt 0) {
                    $state.team[$i].exp = [int]$state.team[$i].exp + $sideExp
                    $sideAwarded++
                }
            }
            Sync-Buddy-From-Team $state
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
        $sideTag = if ($sideAwarded -gt 0) { "  +$sideExp exp × $sideAwarded 倖存隊員" } else { '' }
        Print (Dim "  獎勵：+$coinReward coins (LV. * 2)  ·  +$leadExp exp to buddy$sideTag  ·  streak $($state.battle_streak_current) (best $($state.battle_streak_best))")
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

function Export-Trainer-PNG($state) {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    # Trainer name from git
    $trainerName = 'Trainer'
    try {
        $gn = git config --global user.name 2>$null
        if ($gn) { $trainerName = [string]$gn }
    } catch {}

    # Aggregate
    $caught = 0; $shinyTotal = 0
    foreach ($k in $state.owned.Keys) {
        if ($null -ne $state.owned[$k].first_caught) { $caught++ }
        $shinyTotal += [int]$state.owned[$k].shiny_count
    }
    $dexPct = [Math]::Round(($caught / 151.0) * 100, 1)
    $coins = [int]$state.coins
    $sessions = [int]$state.sessions_count
    $pulls = [int]$state.stats.pulls_total
    $beatGyms = if ($state.gyms_beaten) { $state.gyms_beaten.Count } else { 0 }
    $beatElite = if ($state.elite_beaten) { $state.elite_beaten.Count } else { 0 }

    # Buddy
    $buddyText = '(no buddy)'
    if ($state.buddy -and $state.buddy.id) {
        $bp = $Dex[[string]([int]$state.buddy.id)]
        $bnick = if ($state.buddy.nickname) { [string]$state.buddy.nickname } else { $null }
        $bname = if ($bnick) { "$bnick ($($bp.name_zh))" } else { $bp.name_zh }
        $blv = Get-Level ([int]$state.buddy.exp)
        $buddyText = "#$('{0:D3}' -f $bp.id) $bname  LV $blv  exp $([int]$state.buddy.exp)"
    }

    # Team line (glyphs as chars, 6 slots)
    $teamLineParts = @()
    if ($state.team) {
        foreach ($t in $state.team) {
            $tid = [int]$t.id
            $tp = $Dex[[string]$tid]
            if ($tp) {
                $tlv = Get-Level ([int]$t.exp)
                $teamLineParts += "#$('{0:D3}' -f $tid) L$tlv"
            }
        }
    }
    $teamText = if ($teamLineParts.Count -gt 0) { $teamLineParts -join ' / ' } else { '(empty)' }

    # Build the PNG
    $W = 760; $H = 460
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Background
    $g.Clear([System.Drawing.Color]::FromArgb(12, 12, 12))

    # Gold outer frame
    $gold = [System.Drawing.Color]::FromArgb(255, 216, 107)
    $blue = [System.Drawing.Color]::FromArgb(135, 170, 255)
    $white = [System.Drawing.Color]::White
    $dimGrey = [System.Drawing.Color]::FromArgb(136, 136, 136)
    $green = [System.Drawing.Color]::FromArgb(130, 255, 130)

    $framePen = New-Object System.Drawing.Pen($gold, 4)
    $g.DrawRectangle($framePen, 10, 10, $W - 20, $H - 20)
    $framePen.Dispose()

    # Fonts
    $titleFont = New-Object System.Drawing.Font('Consolas', 22, [System.Drawing.FontStyle]::Bold)
    $headFont  = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
    $bodyFont  = New-Object System.Drawing.Font('Consolas', 13)
    $smallFont = New-Object System.Drawing.Font('Consolas', 11)

    $goldBrush  = New-Object System.Drawing.SolidBrush($gold)
    $whiteBrush = New-Object System.Drawing.SolidBrush($white)
    $blueBrush  = New-Object System.Drawing.SolidBrush($blue)
    $dimBrush   = New-Object System.Drawing.SolidBrush($dimGrey)
    $greenBrush = New-Object System.Drawing.SolidBrush($green)

    # Header
    $g.DrawString('=== TRAINER CARD ===', $titleFont, $goldBrush, 220, 22)

    # Trainer name + sessions
    $g.DrawString("Trainer: $trainerName", $headFont, $whiteBrush, 40, 70)
    $g.DrawString("Sessions: $sessions", $smallFont, $dimBrush, 540, 76)

    # Divider
    $linePen = New-Object System.Drawing.Pen($blue, 2)
    $g.DrawLine($linePen, 30, 100, $W - 30, 100)

    # Stats grid (2 columns)
    $y = 120
    $col1 = 40; $col2 = 400
    $g.DrawString("COINS",       $headFont, $blueBrush, $col1, $y);  $g.DrawString("$coins", $bodyFont, $goldBrush, $col1 + 110, $y)
    $g.DrawString("DEX",         $headFont, $blueBrush, $col2, $y);  $g.DrawString("$caught/151  ($dexPct%)", $bodyFont, $whiteBrush, $col2 + 70, $y)
    $y += 32
    $g.DrawString("PULLS",       $headFont, $blueBrush, $col1, $y);  $g.DrawString("$pulls", $bodyFont, $whiteBrush, $col1 + 110, $y)
    $g.DrawString("SHINIES",     $headFont, $blueBrush, $col2, $y);  $g.DrawString("$shinyTotal", $bodyFont, $goldBrush, $col2 + 110, $y)
    $y += 32
    $g.DrawString("GYMS",        $headFont, $blueBrush, $col1, $y);  $g.DrawString("$beatGyms/8", $bodyFont, $whiteBrush, $col1 + 110, $y)
    $g.DrawString("ELITE 4",     $headFont, $blueBrush, $col2, $y);  $g.DrawString("$beatElite/5", $bodyFont, $whiteBrush, $col2 + 110, $y)

    # Divider
    $g.DrawLine($linePen, 30, $y + 32, $W - 30, $y + 32)
    $y += 50

    # Buddy
    $g.DrawString("BUDDY", $headFont, $blueBrush, 40, $y)
    $g.DrawString($buddyText, $bodyFont, $greenBrush, 130, $y)
    $y += 32

    # Team
    $g.DrawString("TEAM", $headFont, $blueBrush, 40, $y)
    $g.DrawString($teamText, $smallFont, $whiteBrush, 130, $y + 2)
    $y += 32

    # Badges (8 circles, filled if earned)
    $g.DrawString("BADGES", $headFont, $blueBrush, 40, $y)
    $badgeBeat = @{}
    if ($state.gyms_beaten) { foreach ($x in $state.gyms_beaten) { $badgeBeat[[int]$x] = $true } }
    for ($i = 1; $i -le 8; $i++) {
        $bx = 130 + ($i - 1) * 30
        $by = $y + 4
        if ($badgeBeat[$i]) {
            $g.FillEllipse($goldBrush, $bx, $by, 18, 18)
        } else {
            $outlinePen = New-Object System.Drawing.Pen($dimGrey, 2)
            $g.DrawEllipse($outlinePen, $bx, $by, 18, 18)
            $outlinePen.Dispose()
        }
    }
    $g.DrawString("$beatGyms/8", $smallFont, $whiteBrush, 380, $y + 4)

    # Footer
    $g.DrawString("github.com/buzzshu/pokemon-statusline", $smallFont, $dimBrush, 40, $H - 38)
    $g.DrawString((Get-Date -Format 'yyyy-MM-dd'), $smallFont, $dimBrush, $W - 130, $H - 38)

    # Save
    $exportDir = Join-Path $env:USERPROFILE '.claude\exports'
    if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
    $ts = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $outPath = Join-Path $exportDir "trainer-$ts.png"
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)

    # Cleanup
    $titleFont.Dispose(); $headFont.Dispose(); $bodyFont.Dispose(); $smallFont.Dispose()
    $goldBrush.Dispose(); $whiteBrush.Dispose(); $blueBrush.Dispose(); $dimBrush.Dispose(); $greenBrush.Dispose()
    $linePen.Dispose()
    $g.Dispose(); $bmp.Dispose()

    Print ''
    Print "  $(Color '1;38;5;82' '✓') Trainer card exported to $(Color '1;38;5;255' $outPath)"
    Print ''
}

function Show-Elite($state) {
    Print ''
    Print (Bold '=== Elite Four + 冠軍 ===')
    Print ''
    $beaten8 = ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 8)
    if (-not $beaten8) {
        Print "  $(Color '38;5;196' '需要先打贏全部 8 個道館才能挑戰天王。')"
        Print "  $(Dim "目前進度：$($state.gyms_beaten.Count)/8")"
        Print ''
        return
    }
    if (-not $state.elite_beaten) { $state.elite_beaten = @() }
    foreach ($e in $EliteFour) {
        $i = [int]$e.idx
        $hasBeaten = ($state.elite_beaten -contains $i)
        $tag = if ($hasBeaten) { Color '1;38;5;82' '✓' } else { Color '38;5;238' '☐' }
        $title = Color '1;38;5;220' $e.title
        $name = Color '1;38;5;255' $e.leader_name
        $themeCol = if ($TypeColor.ContainsKey($e.theme)) { $TypeColor[$e.theme] } else { '38;5;255' }
        $themeTag = Color $themeCol $e.theme.ToUpper()
        $sz = $e.poke_ids.Count
        $lvAvg = [int][Math]::Round((($e.levels | Measure-Object -Sum).Sum / $sz), 0)
        Print "  $tag $title  $name  $(Dim "$themeTag ·") $(Color '38;5;220' "$sz 隻 / 平均 LV $lvAvg")"
    }
    Print ''
    Print "  $(Dim '/gacha elite <1-4> 挑戰天王，/gacha champion 冠軍戰 (順序不強制)')"
    Print ''
}

function Challenge-Elite($state, [int]$idx) {
    if ($idx -lt 1 -or $idx -gt 5) {
        Print (Color '38;5;196' "Elite index out of range (1-4, or 5 = Champion).")
        return
    }
    $beaten8 = ($state.gyms_beaten -and $state.gyms_beaten.Count -ge 8)
    if (-not $beaten8) {
        Print (Color '38;5;196' "需要先打贏全部 8 個道館才能挑戰天王 (目前 $($state.gyms_beaten.Count)/8).")
        return
    }
    $e = $EliteFour[$idx - 1]
    if (-not $state.team -or $state.team.Count -eq 0) {
        Print (Color '38;5;196' 'Team is empty. Use /gacha buddy <id> to start a team first.')
        return
    }
    $userTeam = Build-User-Team $state
    if ($userTeam.Count -eq 0) {
        Print (Color '38;5;196' 'Team contains no valid pokemon.')
        return
    }
    $leaderTeam = @()
    for ($k = 0; $k -lt $e.poke_ids.Count; $k++) {
        $leaderTeam += , (Build-Combatant ([int]$e.poke_ids[$k]) ([int]$e.levels[$k]) $false)
    }

    Print ''
    Print (Color '1;38;5;220' "你挑戰了 $($e.title) — $($e.leader_name)！")
    Print "  $(Dim '對手隊伍:') $($e.poke_ids.Count) 隻 (LV $($e.levels -join '/'))"
    Print ''
    Start-Sleep -Milliseconds 800

    $result = Resolve-Battle $userTeam $leaderTeam ("$(Color '1;38;5;82' '你')") ("$(Color '1;38;5;196' $e.leader_name)")

    if ($result -eq 'A') {
        Print (Color '1;38;5;82' "★ 勝利！你打敗了 $($e.leader_name)！")
        $coinReward = ($e.levels | Measure-Object -Maximum).Maximum * 5
        $leadExp = ($e.levels | Measure-Object -Maximum).Maximum * 2
        $sideExp = [int][Math]::Floor($leadExp / 4)
        $state.coins = [int]$state.coins + $coinReward
        $sideAwarded = 0
        if ($state.team -and $state.team.Count -gt 0) {
            $state.team[0].exp = [int]$state.team[0].exp + $leadExp
            for ($i = 1; $i -lt [Math]::Min($state.team.Count, $userTeam.Count); $i++) {
                if ([int]$userTeam[$i].hp_cur -gt 0) {
                    $state.team[$i].exp = [int]$state.team[$i].exp + $sideExp
                    $sideAwarded++
                }
            }
            Sync-Buddy-From-Team $state
        }
        if (-not $state.elite_beaten) { $state.elite_beaten = @() }
        if (-not ($state.elite_beaten -contains $idx)) {
            $state.elite_beaten += $idx
        }
        $state.battle_streak_current = [int]$state.battle_streak_current + 1
        if ([int]$state.battle_streak_current -gt [int]$state.battle_streak_best) {
            $state.battle_streak_best = [int]$state.battle_streak_current
        }
        Print ''
        $sideTag = if ($sideAwarded -gt 0) { "  +$sideExp exp × $sideAwarded 倖存隊員" } else { '' }
        Print (Dim "  獎勵：+$coinReward coins  ·  +$leadExp exp to buddy$sideTag  ·  streak $($state.battle_streak_current) (best $($state.battle_streak_best))")
        Print (Dim "  進度：$($state.elite_beaten.Count)/5 天王/冠軍")
    } elseif ($result -eq 'B') {
        Print (Color '1;38;5;196' "✕ 戰敗。天王太強，回去再練吧。")
        Print (Dim "  Tips: 帶滿 6 隻、覆蓋多種屬性、用 Lucky Egg 加速練功. streak 0 (best $($state.battle_streak_best)).")
        $state.battle_streak_current = 0
    } else {
        Print (Dim "  Stalemate — 30 回合無分勝負，撤退. streak 0 (best $($state.battle_streak_best)).")
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

    # Team showcase line: glyph + id + per-slot LV
    $teamLine = '(empty)'
    if ($state.team -and $state.team.Count -gt 0) {
        $glyphs = @()
        foreach ($t in $state.team) {
            $tid = [int]$t.id
            $tp = $Dex[[string]$tid]
            if (-not $tp) { continue }
            $tg = Color $TypeColor[$tp.type1] "$($TypeGlyph[$tp.type1])"
            $tlv = Get-Level ([int]$t.exp)
            $glyphs += "$tg$(Color '38;5;245' "#$('{0:D3}' -f $tid)")$(Dim "L$tlv")"
        }
        $teamLine = $glyphs -join ' '
    }

    # Badges line — 8 glyph slots in gym order, earned colored / unearned dim
    $beatenSet = @{}
    if ($state.gyms_beaten) { foreach ($g in $state.gyms_beaten) { $beatenSet[[int]$g] = $true } }
    $badgeCount = $beatenSet.Count
    $badgeSlots = @()
    for ($i = 1; $i -le 8; $i++) {
        $bg = $BadgeGlyphs[$i]
        if ($beatenSet[$i]) { $badgeSlots += (Color $bg.color "$($bg.glyph)") }
        else { $badgeSlots += (Color '38;5;238' "$BadgeEmptyGlyph") }
    }
    $badgesLine = ($badgeSlots -join ' ') + '  ' + (Color '1;38;5;220' "$badgeCount/8")

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
    Print (Frame-Row 'BADGES' $badgesLine $W)
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
    # Per-slot evolve: find the team slot for $id with the HIGHEST exp. If $id
    # isn't currently in team, user has to /gacha buddy or /gacha team add first
    # (we don't grow exp on dex-only owned copies).
    $bestIdx = -1
    $bestExp = -1
    if ($state.team) {
        for ($i = 0; $i -lt $state.team.Count; $i++) {
            if ([int]$state.team[$i].id -eq $id -and [int]$state.team[$i].exp -gt $bestExp) {
                $bestExp = [int]$state.team[$i].exp
                $bestIdx = $i
            }
        }
    }
    if ($bestIdx -lt 0) {
        Print (Color '38;5;196' "$($poke.name_zh) (#$id) 不在隊伍裡 (only team members earn exp). 先 /gacha team add $id 或 /gacha buddy $id.")
        return
    }
    $slot = $state.team[$bestIdx]
    $slotLabel = if ($state.team.Count -gt 1) { " [slot $($bestIdx + 1)]" } else { '' }

    if ($null -ne $poke.evolve_level) {
        $curLvl = Get-Level ([int]$slot.exp)
        if ($curLvl -lt [int]$poke.evolve_level) {
            $needed = Get-ExpForLevel ([int]$poke.evolve_level)
            Print (Color '38;5;196' "$($poke.name_zh)$slotLabel evolves at LV. $([int]$poke.evolve_level) (currently LV. $curLvl, $([int]$slot.exp)/$needed exp). Keep training.")
            return
        }
    }
    $cost = if ($null -ne $poke.evolve_level) { [int]$poke.evolve_level } else { if ($poke.stage -eq 0) { 5 } else { 20 } }
    if ([int]$state.coins -lt $cost) {
        Print (Color '38;5;196' "Need $cost coins; have $([int]$state.coins)."); return
    }
    $hadShiny = [bool]$slot.shiny
    Remove-Owned $state $id 1 | Out-Null
    if ($hadShiny -and $state.owned.Contains($key) -and [int]$state.owned[$key].shiny_count -gt 0) {
        $state.owned[$key].shiny_count = [int]$state.owned[$key].shiny_count - 1
    }
    Add-Owned $state ([int]$poke.evolves_to) $hadShiny
    $state.coins = [int]$state.coins - $cost
    $state.stats.evolutions_done = [int]$state.stats.evolutions_done + 1

    # Slot follows forward in-place: id becomes the evolved form, exp preserved.
    $state.team[$bestIdx].id = [int]$poke.evolves_to
    $state.team[$bestIdx].shiny = $hadShiny
    if ($bestIdx -eq 0) { Sync-Buddy-From-Team $state }

    # Persist BEFORE animation, same pattern as Pull-Pack / Trade-Dupes / Catch.
    Save-State $state

    $next = $Dex[[string]$poke.evolves_to]
    $g1 = Color $TypeColor[$poke.type1] "$($TypeGlyph[$poke.type1])"
    $g2 = Color $TypeColor[$next.type1] "$($TypeGlyph[$next.type1])"
    $shinyTag = if ($hadShiny) { Gold ' *shiny preserved*' } else { '' }
    $expTag = "$(Dim "(slot $($bestIdx + 1), kept exp $([int]$slot.exp) → LV. $(Get-Level [int]$slot.exp))")"
    Print ''
    Print (Bold "=== Evolving... ===")
    Print "  $g1 $($poke.name_zh) (#$id) $ARROW ???"
    Start-Sleep -Milliseconds 600
    # Reveal evolved form sprite line-by-line
    Print ''
    $spritePath = Join-Path $ClaudeDir "sprites\regular\$([int]$next.id).txt"
    if (Test-Path $spritePath) {
        Get-Content $spritePath -Encoding UTF8 | ForEach-Object {
            Print $_
            Start-Sleep -Milliseconds 90
        }
    }
    Start-Sleep -Milliseconds 300
    Print ''
    Print "  $g2 $(Color '1;38;5;82' $next.name_zh) $(Color '38;5;245' "(#$($next.id))") 進化完成！$shinyTag  $expTag"
    Print (Dim "  -$cost coin · Coins remaining: $([int]$state.coins)")
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
    # Persist before the ~3s trade animation — same reason as Pull-Pack: skill
    # polls state.stats.trades_done and shouldn't wait for animation to finish.
    Save-State $state

    Print ''
    Print (Bold "=== Trading... ===")
    Print ''
    # List the 5 dupes being given up, one at a time, with a small pause so the
    # player feels the cost. Each name colored by its own type for flavor.
    foreach ($pid in $picked) {
        $p = $Dex[[string]$pid]
        $g = Color $TypeColor[$p.type1] "$($TypeGlyph[$p.type1])"
        Print "  $(Dim '↪') $g #$('{0:D3}' -f [int]$pid) $(Color '38;5;245' $p.name_zh)"
        Start-Sleep -Milliseconds 250
    }
    Print ''
    Print (Dim "  $SPARKLE  Transmuting $SPARKLE  ...")
    Start-Sleep -Milliseconds 600
    Print ''
    # Reveal reward sprite line-by-line (same pacing as Pull-Pack)
    $spritePath = Join-Path $ClaudeDir "sprites\regular\$([int]$rewardId).txt"
    if (Test-Path $spritePath) {
        Get-Content $spritePath -Encoding UTF8 | ForEach-Object {
            Print $_
            Start-Sleep -Milliseconds 90
        }
    }
    Start-Sleep -Milliseconds 300
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
    if ($state.team) { foreach ($t in $state.team) { $teamSet[[int]$t.id] = $true } }

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
    Print "  /gacha badges        show your earned gym badges (visual collection)"
    Print "  /gacha theme [name]  switch statusline palette (gba / crystal / dark); no arg = list"
    Print "  /gacha shop          list buyable items + their cost"
    Print "  /gacha buy <slug>    buy item (e.g. rare-candy = +10 exp; great-ball = catch boost)"
    Print "  /gacha items         show your item inventory"
    Print "  /gacha use <slug>    consume item (rare-candy bumps buddy exp; great-ball auto-uses in catch)"
    Print "  /gacha moves <id>    show a pokemon's moveset (signature kit or auto-derived from types/stage)"
    Print "  /gacha rename <id> <nick>  give the highest-exp team slot of <id> a nickname (empty = clear)"
    Print "  /gacha daily         claim 24h login bonus (5 coin + streak bonus; milestones at day 7/14/30 give balls)"
    Print "  /gacha elite [N]     show / challenge the Elite Four (1-4); requires all 8 gym badges"
    Print "  /gacha champion      final fight vs Blue (unlocked after Elite Four cleared, but not strictly gated)"
    Print "  /gacha trainer png   export trainer card to PNG at ~/.claude/exports/trainer-<ts>.png"
    Print "  /gacha achievements  show all 21 milestone achievements + earned dates"
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
# Hold a cross-process mutex for the whole load+mutate+save sequence. statusline.ps1
# races us when the user spams /gacha commands faster than the previous reveal
# animation completes; without the lock the next Load-State can read an empty file
# mid-truncate and reset progress to defaults (corrupt-backup recovery kicks in but
# the *current* command's state mutation is still on the lost-write side).
$__gachaMutex = New-StateLock
$__gachaLocked = Acquire-StateLock $__gachaMutex 10000
if (-not $__gachaLocked) {
    Write-Warning "Couldn't acquire gacha-state lock within 10s; another /gacha command may be hung. Try again."
    exit 1
}
try {
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
    'trainer' {
        if ($Arg -eq 'png' -or $Arg -eq 'export') {
            Export-Trainer-PNG $state
        } else {
            Show-Trainer $state
        }
    }
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
    'badges'  { Show-Badges $state }
    'badge'   { Show-Badges $state }
    'theme'   {
        if ([string]::IsNullOrWhiteSpace($Arg) -or $Arg -eq 'list' -or $Arg -eq 'show') {
            Show-Theme $state
        } else {
            Set-Theme $state $Arg
        }
    }
    'shop'    { Show-Shop $state }
    'items'   { Show-Items $state }
    'buy'     {
        if ([string]::IsNullOrWhiteSpace($Arg)) { Print "Usage: buy <item-slug> [N]"; Show-Shop $state; break }
        $n = 1
        if (-not [string]::IsNullOrWhiteSpace($Arg2)) {
            if (-not [int]::TryParse($Arg2, [ref]$n)) { Print "Usage: buy <item-slug> [N]"; break }
        }
        Buy-Item $state $Arg $n
    }
    'use'     {
        if ([string]::IsNullOrWhiteSpace($Arg)) { Print "Usage: use <item-slug>"; Show-Items $state; break }
        Use-Item $state $Arg
    }
    'moves'   {
        $id = 0
        if (-not [int]::TryParse($Arg, [ref]$id)) { Print "Usage: moves <pokemon-id>"; break }
        Show-Moves $id
    }
    'rename'  {
        $id = 0
        if (-not [int]::TryParse($Arg, [ref]$id)) { Print "Usage: rename <pokemon-id> <nickname>"; break }
        $nick = if ($null -ne $Arg2) { [string]$Arg2 } else { '' }
        if ($null -ne $Arg3) { $nick = "$nick $Arg3" }
        Rename-Pokemon $state $id $nick
    }
    'daily'   { Claim-Daily $state }
    'elite'   {
        if ([string]::IsNullOrWhiteSpace($Arg)) { Show-Elite $state; break }
        $n = 0
        if (-not [int]::TryParse($Arg, [ref]$n)) { Print "Usage: elite <1-4>"; break }
        Challenge-Elite $state $n
    }
    'champion' { Challenge-Elite $state 5 }
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
} finally {
    Release-StateLock $__gachaMutex
}
