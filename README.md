# pokemon-statusline

A Pokémon-themed status line and gacha mini-game for [Claude Code](https://claude.com/claude-code), built for Windows + PowerShell.

Coins auto-accrue from your session cost (1 coin per `$1` USD). Spend them on Gen 1 booster packs, raise a buddy, build a team of 6, challenge gym leaders, hunt legendaries, collect 8 gym badges, unlock 21 achievements.

```
  ╔═══ POKEMON ══════════════════════════════════════════════════════════════════╗
  ║                                                                              ║
  ║              [sprite 1]   [sprite 2]   [sprite 3]     ╔══ STATUS ════════╗   ║
  ║                                                       ║ HP ███▒▒ 64% 7d  ║   ║
  ║              ◈#008 卡咪龜  ✶#151 夢幻  ☆#039 胖丁     ║ MP ██▒▒▒ 34% 5h  ║   ║
  ║              LV. 22 ██▒▒▒ 12/22                       ║ SP ████▒ 83% 137k║   ║
  ║                                                       ╚══════════════════╝   ║
  ╚══════════════════════════════════════════════════════════════════════════════╝
```

## What it does

**Status line (auto-rendered on every Claude Code event):**
- GBA-cartridge outer frame, V/H centered
- HP = 7-day subscription quota remaining (from `$ctx.rate_limits.seven_day`)
- MP = 5-hour subscription quota remaining (from `$ctx.rate_limits.five_hour`)
- SP = compaction-target remaining for current context
- Leader sprite + 2 visible team members
- EXP bar showing buddy progress to next level (triangular curve)
- TEAM segment showing overflow companions
- Encounter banner above frame when a wild pokémon spawns

**`/gacha` slash command** (full subcommand list):

```
/gacha               status summary
/gacha pull          1 coin = 1 card (sprite reveal in new wt tab)
/gacha pulls N       N consecutive pulls (silent)
/gacha catch         throw a Poké Ball at the current wild encounter
/gacha buddy ID      set active leader (auto-adds to team)
/gacha team          list your team (1-6 pokémon, [A]/[B]/[C] tags on duplicates)
/gacha team add ID   add to team (allows duplicates up to copies you own)
/gacha team remove ID
/gacha team move ID POS
/gacha evolve ID     evolve buddy (cost = canonical Gen 1 evolve level)
/gacha trade         5 duplicate spares → 1 random R
/gacha dex           full 151-cell Pokédex grid
/gacha bag           current holdings with stat sparklines
/gacha album         sprite art for every caught pokémon (opens new wt tab)
/gacha stats ID      full base-stat bars (HP/Atk/Def/SpA/SpD/Spd, 20-cell)
/gacha trainer       trainer card (name / sessions / dex% / coins / buddy / team)
/gacha gyms          list 8 Gen 1 gym leaders + your clear progress
/gacha gym N         challenge gym N (1-8); battle plays in new wt tab
/gacha badges        gym badge collection (8 glyphs, earned vs. unearned)
/gacha achievements  21 milestone achievements + earned dates
/gacha event         today's themed pull bonus (rotates by weekday)
/gacha help
```

## Mechanics highlights

- **Rates**: C 90% · U 7% · R 3% in pulls. **HR (legendaries) only via encounters.**
- **Encounters**: 1% chance per new session; pyramid pool C 60 / U 25 / R 12 / HR 3. Three Poké Ball attempts before the wild pokémon flees.
- **Catch rates** (HR): Articuno/Zapdos/Moltres 20%, Mewtwo 10%, Mew 15%. Per-rarity flat rates for non-HR encounters.
- **Levels**: triangular EXP curve. `level = floor(sqrt(2 * exp)) + 1`. L5=10 exp, L16=120, L25=300, L50=1225. 1 session = +1 exp to buddy.
- **Battle engine**: Gen 1 canonical-intent type chart, special/physical split by attacker type, STAB 1.5×, type multipliers 0 / 0.5 / 1 / 2 / 4, 0.85-1.0 random variance. Speed-priority turn order.
- **Daily themed pulls**: Mon=Bug · Tue=Fire · Wed=Water · Thu=Electric · Fri=Grass · Sat=Psychic · Sun=Dragon. 30% chance to re-roll into the themed type's sub-pool within the rolled rarity.

## Requirements

- **Windows** + PowerShell 5.1+ (the engine and status line are PowerShell-only for now)
- **Claude Code 2.1+** (uses the `rate_limits` and `context_window` stdin fields exposed in 1.445+)
- **Windows Terminal** (`wt.exe`) for the pull / album / battle reveal animations. Falls back to conhost if missing.
- About **44 KB** for the engine + **1.4 MB** for the 151 sprites.

## Install

```powershell
git clone https://github.com/buzzshu/pokemon-statusline.git
cd pokemon-statusline
powershell -ExecutionPolicy Bypass -File install.ps1
```

That:
1. Copies the engine + sprites + dex data into `~/.claude/`
2. Patches `~/.claude/settings.json` with the `statusLine` block + `permissions.allow` so `/gacha` can invoke PowerShell.
3. Preserves any existing `~/.claude/gacha-state.json` (your collection survives reinstalls).

Open any new Claude Code session and the status line is live.

## Updating

```powershell
cd pokemon-statusline
git pull
powershell -ExecutionPolicy Bypass -File install.ps1
```

Your `gacha-state.json` is left alone.

## Uninstall

Delete the files manually:

```powershell
Remove-Item "$env:USERPROFILE\.claude\statusline.ps1"
Remove-Item "$env:USERPROFILE\.claude\pokemon-dex.json"
Remove-Item "$env:USERPROFILE\.claude\pokemon-stats.json"
Remove-Item "$env:USERPROFILE\.claude\scripts\gacha.ps1"
Remove-Item "$env:USERPROFILE\.claude\commands\gacha.md"
Remove-Item -Recurse "$env:USERPROFILE\.claude\sprites"
# To keep progress, leave gacha-state.json; to wipe it, remove that too.
# Then strip the statusLine block from ~/.claude/settings.json.
```

## State + backups

Progress lives at `~/.claude/gacha-state.json` (gitignored). Every save also drops a timestamped backup into `~/.claude/backups/gacha-state.<ts>.bak.json` (last 5 retained). If the file ever fails to parse, the corrupt copy is preserved at `~/.claude/backups/gacha-state.corrupt.<ts>.json` before the engine resets to defaults.

## Credits

- **Sprites**: vendored from [pokemon-colorscripts](https://gitlab.com/phoneybadger/pokemon-colorscripts) (MIT). See `sprites/NOTICE.txt`.
- **Pokémon, Pokédex, type chart**: trademarks of Nintendo / Game Freak / The Pokémon Company. This is a fan-made educational/personal tool, not affiliated with or endorsed by them.

## License

MIT. See `LICENSE`.
