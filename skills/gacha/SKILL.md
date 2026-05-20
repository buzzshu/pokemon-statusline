---
name: gacha
description: Pokemon-themed gacha mini-game tied to session cost; pull packs, build a dex, evolve, trade, set a buddy that lives in the status line
argument-hint: [pull | pulls N | buddy ID | evolve ID | team ... | trade | dex | help]
---

You are running the `/gacha` command. It's a Pokemon gacha system layered on Claude Code's status line: every `$1 USD` of session cost auto-earns 1 coin (handled by the status line script), and the user spends coins on booster packs and evolutions via this command.

The engine lives globally at `%USERPROFILE%\.claude\scripts\gacha.ps1` and reads/writes one shared state file at `%USERPROFILE%\.claude\gacha-state.json`. The same install handles every project.

## Procedure

Branch on what `$ARGUMENTS` starts with:

### A. New-tab class (`pull`, `pulls <N>`, `trade`, `catch`, `evolve <ID>`, `album`, `gallery`, `gym <N>`) → open a new Windows Terminal tab

All commands that **acquire / transform pokemon** spawn a tab so the reveal animation plays:
- `pull` / `pulls N` — Claude Code buffers stdout so the 90ms-per-line sprite reveal is invisible inline.
- `trade` — same reveal pattern (R reward sprite drops line-by-line after the 5 dupes are listed).
- `catch` — wild encounter resolution: shake animation + sprite reveal on GOTCHA.
- `evolve <ID>` — Evolving... → sprite of the evolved form drops line-by-line.
- `album` / `gallery` — 86+ lines of sprite art exceeds Claude Code's tool result preview.
- `gym N` — turn-by-turn battle animation, ~20-30s per fight.

Spawn the engine in a new Windows Terminal tab so the user sees the full output live.

1. **Sample the pre-spawn state** so you can detect when the engine wrote its mutation. Use the appropriate stats counter for the command type:
   - `pull` / `pulls N` → `state.stats.pulls_total`
   - `trade` → `state.stats.trades_done`
   - `album` / `gallery` / `gym N` → these don't mutate the same counter; just fixed-sleep ~3-6s for these (see step 2b)

   ```powershell
   $stateFile = "$env:USERPROFILE\.claude\gacha-state.json"
   $pre = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).stats.pulls_total
   ```

2. Spawn the new tab in a **named window** `gacha` so every animation lands in the same wt window — first call creates a window named `gacha`, subsequent calls add tabs to it instead of spawning fresh windows. Without `-w gacha`, repeated `/gacha pull` etc. each opened a brand-new wt window:

   ```powershell
   $wtArgs = @('-w', 'gacha', 'nt', '-d', "$env:USERPROFILE", 'powershell', '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "$env:USERPROFILE\.claude\scripts\gacha.ps1") + ($ARGUMENTS -split ' ')
   Start-Process wt.exe -ArgumentList $wtArgs
   ```

2a. **For commands with a stats counter** (poll up to 8s instead of fixed sleep — engine save-states immediately after mutation, so counter advances within ~200ms; the rest of the time is decorative animation):

   | command | counter to poll |
   |---|---|
   | `pull` / `pulls N` | `stats.pulls_total` |
   | `trade` | `stats.trades_done` |
   | `evolve <ID>` | `stats.evolutions_done` |
   | `catch` | `coins` (deducted by 1 on attempt) OR `encounter` going null on success/escape |

   ```powershell
   $deadline = [DateTime]::Now.AddSeconds(8)
   do {
       Start-Sleep -Milliseconds 300
       $now = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).stats.pulls_total
   } while ($now -le $pre -and [DateTime]::Now -lt $deadline)
   if ($now -le $pre) {
       # wt spawn likely failed silently — tell the user; do NOT retry inline
       # (that would double-charge if wt is just slow and eventually fires).
       Write-Warning "wt tab didn't fire within 8s. Retry the command if state still hasn't advanced."
   }
   ```

2b. **For `album`/`gallery`/`gym N`** (no easy counter to poll): fall back to a fixed sleep tuned to the command's runtime:
   - `album`/`gallery`: 3000ms (just sprite scrolling, no state mutation)
   - `gym N`: 35000ms (battle takes 20-30s with reveal animation)

3. Read the result from the shared state file and report inline (one or two short sentences) so the chat keeps context. The fields you care about live in `%USERPROFILE%\.claude\gacha-state.json`:

   - `state.last_pull` — `{id, name_zh, name_en, rarity, shiny}` for the most recent single card
   - `state.coins` — current balance
   - `state.stats.pulls` — total pulls counter
   - `state.owned[<id>].count` — increment indicates the card is now owned (was 0 → 1 means NEW)

   For `pulls N`, the engine only stores the last card in `last_pull`; the multi-pull summary line printed by the engine ("Pulls: X · Caught: Y · NEW: Z") is in the spawned tab, not in your stdout. Just report `state.coins` + the total `state.stats.pulls` and tell the user to glance at the tab for the per-card breakdown.

4. Followup tip (one line, only when natural):
   - First-ever pull / no buddy set yet → suggest `/gacha buddy <id>`.
   - HR or shiny pulled → small celebration line.
   - `Not enough coins` will surface in the tab; mirror it inline so the user notices without switching focus.

### B. Everything else (`status`, `buddy <ID>`, `team ...`, `dex`, `help`, `bag`, `items`, `shop`, `buy`, `use`, `moves`, `rename`, `daily`, `trainer`, `gyms`, `elite`, `champion`, `badges`, `theme`, `stats`, `achievements`, `event`) → run inline

These don't have an animation — they're one-shot prints. Just invoke the engine via the PowerShell tool:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\gacha.ps1" $ARGUMENTS
```

Show the script's stdout verbatim — it's already ANSI-colored and formatted for terminal display. Do NOT re-summarize or re-format.

If `$ARGUMENTS` is empty, run with no args (engine defaults to `status`).

## Important

- Never modify `%USERPROFILE%\.claude\gacha-state.json` directly. The engine owns it.
- If `wt.exe` is unavailable for some reason, fall back to `Start-Process powershell.exe -ArgumentList @('-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File',"$env:USERPROFILE\.claude\scripts\gacha.ps1") + ($ARGUMENTS -split ' ')` so the user still gets a separate window. 24-bit colors will be flatter under conhost but the reveal works.
- The Pokedex dataset is Gen 1 only (151 species). If the user asks about Gen 2+, say it's not in the current dex.
- The state lives in `%USERPROFILE%\.claude\` not the current project — collection follows the user across all Claude Code sessions.
