# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Windows + PowerShell Claude Code extension with two surfaces:

- A **status-line script** (`statusline.ps1`) that Claude Code invokes on every render event, reading the `ctx` JSON from stdin and printing a GBA-cartridge frame with HP/MP/SP bars + a team-sprite block.
- A **`/gacha` slash command** (`commands/gacha.md` + `scripts/gacha.ps1`) — a full Gen 1 Pokémon mini-game (pulls, encounters, evolutions, 6-slot team, 8 gyms with a real type-chart battle engine, 20 achievements, daily themed events).

The two scripts share **one global state file** at `~/.claude/gacha-state.json`. The status-line script owns `coins`, `cost_usd_processed`, `last_render_cost`, `cost_log`, `sessions_count`, `last_session_id`, `buddy.exp`, and the wild `encounter`. The gacha engine owns `owned`, `team`, `last_pull`, `stats`, `achievements`, `gyms_beaten`, `battle_streak_*`.

## Install / dev / test loop

```powershell
# Deploy this repo's working tree to ~/.claude
powershell -ExecutionPolicy Bypass -File install.ps1

# Reset the install layout (engine + sprites + dex + settings.json patch)
# without nuking your collection — gacha-state.json is preserved on re-run.
powershell -ExecutionPolicy Bypass -File install.ps1
```

There is no test suite, lint, or CI. To exercise a change:

```powershell
# Run the gacha engine directly against your real state file.
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gacha.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gacha.ps1 pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gacha.ps1 gym 1

# Pipe a fake ctx into the status line to see one render.
'{"cost":{"total_cost_usd":0.0,"total_duration_ms":0,"total_api_duration_ms":0},"rate_limits":{"weekly":{"used_percentage":10},"five_hour":{"used_percentage":20}},"context_window":{"context_window_size":200000,"total_input_tokens":5000}}' `
  | powershell -NoProfile -ExecutionPolicy Bypass -File .\statusline.ps1
```

The engine and status-line both resolve `$ClaudeDir` from `$PSScriptRoot` so they work in BOTH the dev repo (running from `D:\Buzz\pokemon-statusline\`) and after install (running from `~/.claude\`). The **state file is hard-coded to `~/.claude\gacha-state.json` in both cases** — dev runs mutate your real collection. There is no fixture / sandbox mode; back up `gacha-state.json` before risky changes, or set `$StateFile` / `$gachaStateFile` to a throwaway path while iterating.

## Architecture notes that aren't obvious from one file

### Concurrent writes to `gacha-state.json`

`statusline.ps1` runs on every Claude Code event and `gacha.ps1` runs whenever the user types `/gacha`. They can race. The status-line script uses a **read-modify-write at save time** pattern: it computes its deltas against an in-memory snapshot, then **re-reads the file immediately before writing** and patches only the fields it owns (see the `$dirty` / `$fresh` block at `statusline.ps1:90-152`). Any new field added to the status line must follow the same pattern or it will stomp on concurrent `/gacha` writes.

The gacha engine does NOT re-read before saving — it assumes the user isn't pull-spamming faster than render rate. If you add long-running gacha subcommands, port the re-read pattern there too.

`Save-State` in `gacha.ps1` rotates the previous file into `~/.claude\backups\gacha-state.<ts>.bak.json` (keeps 5). Parse failures in `Load-State` are preserved as `backups\gacha-state.corrupt.<ts>.json` before falling back to defaults — never delete a corrupt state, it's evidence.

### Dex data is positional, not keyed

`pokemon-dex.json` and `pokemon-stats.json` store rows as **positional arrays**, with the column order declared in a `format` key. Indexes used in code:

- dex row `[id, name_en, name_zh, type1, type2, stage, evolves_to, rarity, pullable, evolve_level]` — see `gacha.ps1:148-160` and `statusline.ps1:239-247`
- stats row `[id, hp, atk, def, spa, spd, spe]` — see `gacha.ps1:383-388`

If you reorder columns, update **both** the `format` array AND every consumer. The `pullable` flag controls the pull pool: stage 0 = `true` (in packs), stage 1+ = `false` (only obtainable via `/gacha evolve`). Legendaries (HR) are `pullable: true` in data but excluded from `Get-RandomRarity` (`gacha.ps1:500-509`) — they only spawn in encounters.

### Sprite rendering + visible-width math

Sprites in `sprites/regular/<id>.txt` are vendored from `pokemon-colorscripts` and use ANSI 24-bit color escapes with `U+2580` (upper half block) for 2-pixels-per-character vertical density. Both scripts duplicate a `Get-VisibleWidth` helper that strips ANSI and double-counts CJK + a hand-curated `$WIDE_EMOJI_BMP` set. **Keep the two copies in sync** (`statusline.ps1:186-217` and `gacha.ps1:91-115`) — they're the source of alignment bugs in the framed layouts.

Glyphs are built at runtime via `[char]0xXXXX` so source files stay ASCII (avoid PS 5.1 encoding pitfalls). Stick to BMP code points; supplementary-plane emoji break in conhost fallback.

### `/gacha` subcommands run in two modes

`commands/gacha.md` is the slash-command spec Claude follows. It branches on the first arg:

- **Animation / large-output commands** (`pull`, `pulls N`, `album`, `gallery`, `gym N`) → spawn a new Windows Terminal tab via `wt.exe new-tab ... powershell -File scripts\gacha.ps1 ...`, sleep ~2.5s, then read `gacha-state.json` and report inline. Claude Code's stdout buffering would swallow the per-line reveal animations otherwise.
- **Everything else** (`status`, `buddy`, `team`, `evolve`, `trade`, `dex`, `bag`, `stats`, `trainer`, `gyms`, `event`, `achievements`, `help`) → run inline through the PowerShell tool, dump engine stdout verbatim.

Adding a new subcommand: implement it in `gacha.ps1`, add it to the `switch` at `gacha.ps1:1683`, then update `Show-Help` AND the README. If it has reveal animation or >40 lines of output, list it in the new-tab branch of `commands/gacha.md`.

### Battle engine (`Resolve-Battle`)

The Gen 1 type chart at `gacha.ps1:170-186` is canonical-intent (no Steel/Dark/Fairy). `$SpecialTypes` at line 189 splits attacker types between SpA/SpD and Atk/Def for damage. Battle resolves at `gacha.ps1:1193`: speed-priority turn order, STAB 1.5×, type stacking multiplicative (0 immunity sticks), 0.85–1.0 random variance. User team comes from `Build-User-Team` which mirrors `state.team` and uses buddy's actual level; gym leader's mon is built at the fixed level in `$GymLeaders` (`gacha.ps1:192-201`).

### EXP / level curve

Triangular: `exp_for_level(L) = L*(L-1)/2`; inverse is `level = floor((1 + sqrt(1 + 8*exp)) / 2)`. Both scripts duplicate `Get-Level` / `Get-ExpForLevel` (`gacha.ps1:71-78`, `statusline.ps1:221-228`). Buddy earns `+1 exp` per new session, attributed in the status-line's new-session branch. (Earlier `floor(sqrt(2*exp)) + 1` overshot by one in the middle of a level band and rendered negative within-level progress — fixed to the exact inverse.)

### Rate-limit / context-window stdin schema

`statusline.ps1` reads from `ctx.rate_limits.weekly.used_percentage` (HP / 7-day) and `ctx.rate_limits.five_hour.used_percentage` (MP / 5-hour), with a list of fallback key names (`Get-RateLimitObj`, `Get-RateLimitPct`) for schema drift across Claude Code versions. Falls back to a `cost_log`-derived estimate (`$500/week`, `$50/5h` budgets) if the field is missing. SP comes from `ctx.context_window.total_input_tokens` vs `context_window_size * 0.8`. If Claude Code changes that schema, fix it here first — there's no other consumer.

### Settings patching

`install.ps1` reads `~/.claude/settings.json`, sets/overwrites the `statusLine` block, and **idempotently appends** `Bash(*)` + `PowerShell(*)` to `permissions.allow`. It does not own any other keys. The `statusLine.command` is rewritten on every install to point at the target `statusline.ps1`, so changing the install target re-patches correctly.

## File layout cheat-sheet

| File                          | Owner / role                                                              |
| ----------------------------- | ------------------------------------------------------------------------- |
| `statusline.ps1`              | Render loop. Reads stdin ctx; mutates coins/encounter/sessions in state.  |
| `scripts/gacha.ps1`           | Slash-command engine. ~1.8k lines, single-file, no module imports.        |
| `commands/gacha.md`           | Slash-command spec Claude follows. Spawns new-tab for animated commands.  |
| `install.ps1`                 | Copies into `~/.claude`, patches `settings.json`, preserves user state.   |
| `pokemon-dex.json`            | 151 Gen 1 species (positional rows, `format` key declares column order).  |
| `pokemon-stats.json`          | Base stats keyed off the same ids.                                        |
| `sprites/regular/<id>.txt`    | Vendored from `pokemon-colorscripts`. See `sprites/NOTICE.txt` for terms. |
| `~/.claude/gacha-state.json`  | Runtime state. Gitignored. Concurrent-write protocol described above.     |
