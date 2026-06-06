# Agent Skill Sync

One-click Windows script for syncing skills between Claude Code and Codex.

## What It Syncs

- Claude Code skills: `%USERPROFILE%\.claude\skills`
- Codex skills: `%USERPROFILE%\.codex\skills`

The script copies new files both ways, keeps the newer version when only one side changed, skips Codex's built-in `.system` skills, and detects conflicts when both sides changed the same file since the previous sync.

## Usage

Double-click:

```bat
sync-skills.cmd
```

Or run from PowerShell:

```powershell
.\sync-skills.cmd
```

Preview changes without copying files:

```powershell
.\sync-skills.cmd -DryRun
```

Resolve conflicts by choosing one side:

```powershell
.\sync-skills.cmd -Force -Prefer Claude
.\sync-skills.cmd -Force -Prefer Codex
```

Restart Claude Code or Codex after syncing newly added skills so the app can load them.

## Files

- `sync-skills.ps1`: main PowerShell sync script
- `sync-skills.cmd`: Windows launcher for double-click usage
- `sync-skills.state.json`: generated locally after syncing; not committed
