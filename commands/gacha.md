---
description: Pokemon-themed gacha mini-game tied to session cost; pull packs, build a dex, evolve, trade, set a buddy that lives in the status line
argument-hint: [pull | pulls N | buddy ID | evolve ID | team ... | trade | dex | help]
---

You are running the `/gacha` command. It's a Pokemon gacha system layered on Claude Code's status line: every `$1 USD` of session cost auto-earns 1 coin (handled by the status line script), and the user spends coins on booster packs and evolutions via this command.

The engine lives globally at `%USERPROFILE%\.claude\scripts\gacha.ps1` and reads/writes one shared state file at `%USERPROFILE%\.claude\gacha-state.json`. The same install handles every project.

## Procedure

Branch on what `$ARGUMENTS` starts with:

### A. New-tab class (`pull`, `pulls <N>`, `album`, `gallery`, `gym <N>`) → open a new Windows Terminal tab

Three reasons to spawn a new tab instead of running inline:
- `pull` / `pulls N` — Claude Code buffers stdout so the 90ms-per-line reveal animation is invisible inline.
- `album` / `gallery` — 86+ lines of sprite art exceeds Claude Code's tool result preview and gets truncated.
- `gym N` — turn-by-turn battle animation has 600-800ms per line; full battle is many seconds of reveal which gets buffered/truncated inline.

Spawn the engine in a new Windows Terminal tab so the user sees the full output live.

1. Spawn the new tab (use the PowerShell tool). Build the argv as an array so it survives Windows command-line quoting:

   ```powershell
   $wtArgs = @('new-tab', '-d', "$env:USERPROFILE", 'powershell', '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "$env:USERPROFILE\.claude\scripts\gacha.ps1") + ($ARGUMENTS -split ' ')
   Start-Process wt.exe -ArgumentList $wtArgs
   ```

2. Wait ~2.5s for the reveal animation + state writeback to finish:

   ```powershell
   Start-Sleep -Milliseconds 2500
   ```

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

### B. Everything else (`status`, `buddy <ID>`, `team ...`, `evolve <ID>`, `trade`, `dex`, `help`) → run inline

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
