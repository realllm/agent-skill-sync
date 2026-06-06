# Agent Skill Sync

One-click scripts for syncing skills between Claude Code and Codex.

## What It Syncs

- Claude Code skills:
  - Windows: `%USERPROFILE%\.claude\skills`
  - macOS: `$HOME/.claude/skills`
- Codex skills:
  - Windows: `%USERPROFILE%\.codex\skills`
  - macOS: `$HOME/.codex/skills`

The scripts copy new files both ways, keep the newer version when only one side changed, skip Codex's built-in `.system` skills, and detect conflicts when both sides changed the same file since the previous sync.

## Windows

Double-click:

```bat
windows\sync-skills.cmd
```

Or run from PowerShell:

```powershell
.\windows\sync-skills.cmd
```

Preview changes without copying files:

```powershell
.\windows\sync-skills.cmd -DryRun
```

Resolve conflicts by choosing one side:

```powershell
.\windows\sync-skills.cmd -Force -Prefer Claude
.\windows\sync-skills.cmd -Force -Prefer Codex
```

## macOS

Make the script executable once:

```bash
chmod +x macos/sync-skills.sh
```

Run:

```bash
./macos/sync-skills.sh
```

Preview changes without copying files:

```bash
./macos/sync-skills.sh --dry-run
```

Resolve conflicts by choosing one side:

```bash
./macos/sync-skills.sh --force --prefer claude
./macos/sync-skills.sh --force --prefer codex
```

If your skills live somewhere else:

```bash
./macos/sync-skills.sh --claude-skills "/path/to/.claude/skills" --codex-skills "/path/to/.codex/skills"
```

Restart Claude Code or Codex after syncing newly added skills so the app can load them.

## Files

- `windows/sync-skills.ps1`: Windows PowerShell sync script
- `windows/sync-skills.cmd`: Windows launcher for double-click usage
- `macos/sync-skills.sh`: macOS Bash sync script
- `sync-skills.state.json` / `sync-skills.state.tsv`: generated locally after syncing; not committed
