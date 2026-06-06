param(
    [string]$ClaudeSkills = "$env:USERPROFILE\.claude\skills",
    [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
    [string]$StateFile = "",
    [ValidateSet("Claude", "Codex")]
    [string]$Prefer = "Claude",
    [switch]$DryRun,
    [switch]$Quiet,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = Join-Path $PSScriptRoot "sync-skills.state.json"
}

function Write-Info {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Info "[dry-run] create directory: $Path"
        } else {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        }
    }
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($FullPath)
    return $full.Substring($base.Length)
}

function Get-StateKey {
    param(
        [string]$SkillName,
        [string]$RelativePath
    )

    return ($SkillName + "/" + ($RelativePath -replace "\\", "/"))
}

function Get-FileHashValue {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-SyncState {
    param([string]$Path)

    $state = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $state
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -ne $json.files) {
            $json.files.PSObject.Properties | ForEach-Object {
                if ($null -ne $_.Value.hash) {
                    $state[$_.Name] = [string]$_.Value.hash
                }
            }
        }
    } catch {
        Write-Info "Warning: could not read sync state, continuing without it: $Path"
    }

    return $state
}

function Write-SyncState {
    param(
        [string]$Path,
        [hashtable]$State
    )

    if ($DryRun) {
        Write-Info "[dry-run] update state file: $Path"
        return
    }

    $files = [ordered]@{}
    $State.Keys | Sort-Object | ForEach-Object {
        $files[$_] = @{ hash = $State[$_] }
    }

    $payload = [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
        files = $files
    }

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Copy-SkillFile {
    param(
        [string]$SourceFile,
        [string]$DestinationFile,
        [string]$Reason
    )

    $sourceItem = Get-Item -LiteralPath $SourceFile
    $destDir = Split-Path -Parent $DestinationFile

    if ($DryRun) {
        Write-Info "[dry-run] copy ($Reason): $SourceFile -> $DestinationFile"
    } else {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
        [System.IO.File]::SetLastWriteTimeUtc($DestinationFile, $sourceItem.LastWriteTimeUtc)
    }

    $script:FilesCopied += 1
    return $true
}

function Get-SkillFolders {
    param(
        [string]$Root,
        [switch]$SkipCodexSystem
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $Root -Directory -Force |
        Where-Object {
            if ($SkipCodexSystem -and $_.Name -eq ".system") {
                return $false
            }
            return Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md")
        }
}

function Get-RelativeFiles {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { Get-RelativePath -BasePath $Root -FullPath $_.FullName }
}

function Sync-OneSkill {
    param(
        [string]$SkillName,
        [hashtable]$PreviousState
    )

    $claudeSkill = Join-Path $ClaudeSkills $SkillName
    $codexSkill = Join-Path $CodexSkills $SkillName
    $claudeFiles = @(Get-RelativeFiles -Root $claudeSkill)
    $codexFiles = @(Get-RelativeFiles -Root $codexSkill)
    $relativeFiles = @($claudeFiles + $codexFiles) | Sort-Object -Unique
    $changed = 0

    foreach ($relative in $relativeFiles) {
        $claudeFile = Join-Path $claudeSkill $relative
        $codexFile = Join-Path $codexSkill $relative
        $claudeExists = Test-Path -LiteralPath $claudeFile
        $codexExists = Test-Path -LiteralPath $codexFile

        if ($claudeExists -and -not $codexExists) {
            Ensure-Directory -Path $codexSkill
            if (Copy-SkillFile -SourceFile $claudeFile -DestinationFile $codexFile -Reason "Claude new") {
                $changed += 1
            }
            continue
        }

        if ($codexExists -and -not $claudeExists) {
            Ensure-Directory -Path $claudeSkill
            if (Copy-SkillFile -SourceFile $codexFile -DestinationFile $claudeFile -Reason "Codex new") {
                $changed += 1
            }
            continue
        }

        if (-not ($claudeExists -and $codexExists)) {
            continue
        }

        $claudeHash = Get-FileHashValue -Path $claudeFile
        $codexHash = Get-FileHashValue -Path $codexFile
        if ($claudeHash -eq $codexHash) {
            continue
        }

        $key = Get-StateKey -SkillName $SkillName -RelativePath $relative
        $hasPrevious = $PreviousState.ContainsKey($key)
        $claudeChangedSinceLastSync = $hasPrevious -and ($claudeHash -ne $PreviousState[$key])
        $codexChangedSinceLastSync = $hasPrevious -and ($codexHash -ne $PreviousState[$key])
        $claudeItem = Get-Item -LiteralPath $claudeFile
        $codexItem = Get-Item -LiteralPath $codexFile
        $sameTimestamp = $claudeItem.LastWriteTimeUtc -eq $codexItem.LastWriteTimeUtc
        $isConflict = ($claudeChangedSinceLastSync -and $codexChangedSinceLastSync) -or ((-not $hasPrevious) -and $sameTimestamp)

        if ($isConflict -and -not $Force) {
            $script:Conflicts += 1
            Write-Info "[conflict] skipped: $SkillName/$relative"
            Write-Info "           use -Force -Prefer Claude or -Force -Prefer Codex to choose a side"
            continue
        }

        if ($isConflict -and $Force) {
            if ($Prefer -eq "Claude") {
                if (Copy-SkillFile -SourceFile $claudeFile -DestinationFile $codexFile -Reason "conflict forced from Claude") {
                    $changed += 1
                }
            } else {
                if (Copy-SkillFile -SourceFile $codexFile -DestinationFile $claudeFile -Reason "conflict forced from Codex") {
                    $changed += 1
                }
            }
            continue
        }

        if ($claudeItem.LastWriteTimeUtc -gt $codexItem.LastWriteTimeUtc) {
            if (Copy-SkillFile -SourceFile $claudeFile -DestinationFile $codexFile -Reason "Claude newer") {
                $changed += 1
            }
        } elseif ($codexItem.LastWriteTimeUtc -gt $claudeItem.LastWriteTimeUtc) {
            if (Copy-SkillFile -SourceFile $codexFile -DestinationFile $claudeFile -Reason "Codex newer") {
                $changed += 1
            }
        } else {
            $script:Conflicts += 1
            Write-Info "[conflict] skipped: $SkillName/$relative"
            Write-Info "           same timestamp but different content; use -Force -Prefer Claude or -Force -Prefer Codex"
        }
    }

    return $changed
}

function Build-SyncState {
    $state = @{}
    $claudeFolders = @(Get-SkillFolders -Root $ClaudeSkills)
    $codexFolders = @(Get-SkillFolders -Root $CodexSkills -SkipCodexSystem)
    $skillNames = @($claudeFolders.Name + $codexFolders.Name) | Sort-Object -Unique

    foreach ($skillName in $skillNames) {
        $claudeSkill = Join-Path $ClaudeSkills $skillName
        $codexSkill = Join-Path $CodexSkills $skillName
        $relativeFiles = @(Get-RelativeFiles -Root $claudeSkill)

        foreach ($relative in $relativeFiles) {
            $claudeFile = Join-Path $claudeSkill $relative
            $codexFile = Join-Path $codexSkill $relative
            if ((Test-Path -LiteralPath $claudeFile) -and (Test-Path -LiteralPath $codexFile)) {
                $claudeHash = Get-FileHashValue -Path $claudeFile
                $codexHash = Get-FileHashValue -Path $codexFile
                if ($claudeHash -eq $codexHash) {
                    $key = Get-StateKey -SkillName $skillName -RelativePath $relative
                    $state[$key] = $claudeHash
                }
            }
        }
    }

    return $state
}

Ensure-Directory -Path $ClaudeSkills
Ensure-Directory -Path $CodexSkills

$FilesCopied = 0
$Conflicts = 0
$SkillsTouched = New-Object System.Collections.Generic.HashSet[string]
$PreviousState = Read-SyncState -Path $StateFile

Write-Info "Syncing skills:"
Write-Info "  Claude: $ClaudeSkills"
Write-Info "  Codex : $CodexSkills"
Write-Info "  State : $StateFile"
if ($Force) {
    Write-Info "  Mode  : Force, prefer $Prefer on conflicts"
}
Write-Info ""

$claudeFolders = @(Get-SkillFolders -Root $ClaudeSkills)
$codexFolders = @(Get-SkillFolders -Root $CodexSkills -SkipCodexSystem)
$skillNames = @($claudeFolders.Name + $codexFolders.Name) | Sort-Object -Unique

foreach ($skillName in $skillNames) {
    $changed = Sync-OneSkill -SkillName $skillName -PreviousState $PreviousState
    if ($changed -gt 0) {
        [void]$SkillsTouched.Add($skillName)
        Write-Info "Synced: $skillName ($changed files)"
    }
}

$NewState = Build-SyncState
Write-SyncState -Path $StateFile -State $NewState

Write-Info ""
if ($FilesCopied -eq 0) {
    Write-Info "Done. No files needed syncing."
} else {
    $skillCount = $SkillsTouched.Count
    Write-Info "Done. Synced $FilesCopied file(s) across $skillCount skill(s)."
}

if ($Conflicts -gt 0) {
    Write-Info "Skipped $Conflicts conflict(s). Re-run with -Force -Prefer Claude or -Force -Prefer Codex after reviewing."
}
Write-Info "Restart Claude Code or Codex if you need newly added skills to be picked up."
