# =============================================================================
#  restore_402.ps1  -  402 Wasteland PR Restorer  (merge-file edition)
#
#  USAGE:
#    .\restore_402.ps1              Normal run
#    .\restore_402.ps1 -DryRun      Preview only - no files are modified
#
#  REQUIREMENTS:
#    - Run AFTER you have already done: git fetch && git checkout environment/402
#    - A portable gh.exe must be on your PATH (or next to this script)
# =============================================================================
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$startTime = Get-Date

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Ok   { param($t) Write-Host "  [OK]  $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "  [!!]  $t" -ForegroundColor Yellow }
function Write-Err  { param($t) Write-Host "  [XX]  $t" -ForegroundColor Red }
function Write-Info { param($t) Write-Host "  [ ]   $t" -ForegroundColor DarkGray }
function Write-Step { param($t) Write-Host "`n[ $t ]" -ForegroundColor Magenta }

# ── Helper: invoke git/cmd safely without PowerShell mutating output ──────────
function Quote-CmdArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-CmdCommand {
    param([string]$Command)

    cmd.exe /d /c $Command
    return $LASTEXITCODE
}

function Get-SafeTempName {
    param([string]$Value)

    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Value)
        )
    ).Replace('-', '').Substring(0, 16)
}

function Get-GitContentEncoding {
    param([string]$FilePath)

    $attrOutput = git check-attr --cached --all -- "$FilePath" 2>$null
    foreach ($line in $attrOutput) {
        if ($line -match ':\s*working-tree-encoding:\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Normalize-LineEndings {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

# ── Helper: write a git object to a file safely without PowerShell line mangling ──
# [`git show`](prredo.ps1:106) output must preserve original newlines. Instead of shell
# redirection, capture stdout as raw bytes and write them directly to disk so
# [`git merge-file`](prredo.ps1:475) sees the true file structure.
function Write-GitObjectToFile {
    param(
        [string]$GitRef,
        [string]$OutPath,
        [string]$EncodingName = $null
    )

    $stdoutFile = Join-Path ([System.IO.Path]::GetDirectoryName($OutPath)) ("stdout_$(Get-SafeTempName $GitRef).tmp")
    $stderrFile = Join-Path ([System.IO.Path]::GetDirectoryName($OutPath)) ("stderr_$(Get-SafeTempName $GitRef).tmp")

    Remove-PathIfExists $stdoutFile
    Remove-PathIfExists $stderrFile

    try {
        $process = Start-Process -FilePath "git.exe" `
            -ArgumentList @("show", "--no-textconv", $GitRef) `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        if ($process.ExitCode -ne 0) {
            return $process.ExitCode
        }

        $bytes = if (Test-Path -LiteralPath $stdoutFile) {
            [System.IO.File]::ReadAllBytes($stdoutFile)
        } else {
            [byte[]]@()
        }

        if ($EncodingName) {
            $encoding = [System.Text.Encoding]::GetEncoding($EncodingName)
            $text = $encoding.GetString($bytes)
            $normalized = Normalize-LineEndings $text
            [System.IO.File]::WriteAllText($OutPath, $normalized, $encoding)
        } else {
            [System.IO.File]::WriteAllBytes($OutPath, $bytes)
        }

        return 0
    }
    finally {
        Remove-PathIfExists $stdoutFile
        Remove-PathIfExists $stderrFile
    }
}

function Get-GitObjectExists {
    param([string]$GitRef)

    git cat-file -e -- "$GitRef" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-ParentDirectory {
    param([string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Remove-PathIfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |      402 Wasteland  -  PR Restorer  v5       |" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  |           *** DRY RUN MODE ***               |" -ForegroundColor Yellow
}
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
#  SECTION 1 - PRE-FLIGHT CHECKS
# =============================================================================
Write-Step "Pre-flight Checks"

# ── 1a. gh CLI reachable? ─────────────────────────────────────────────────────
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    $portableGh = Join-Path $PSScriptRoot "gh.exe"
    if (Test-Path -LiteralPath $portableGh) {
        $env:PATH = "$PSScriptRoot;$env:PATH"
        Write-Ok "Found portable gh.exe next to script."
    } else {
        Write-Err "GitHub CLI (gh) not found on PATH or next to this script."
        Write-Host "     Place a portable gh.exe in: $PSScriptRoot" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Ok "GitHub CLI found: $($ghCmd.Source)"
}

# ── 1b. Repo path ─────────────────────────────────────────────────────────────
$rawInput = Read-Host "`n  Enter the full path to your local git repository"
$repoPath = $rawInput.Trim('"').Trim("'")

if (-not (Test-Path -LiteralPath $repoPath)) {
    Write-Err "Directory not found: '$repoPath'"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $repoPath ".git"))) {
    Write-Err "'$repoPath' is not a Git repository (no .git folder found)."
    exit 1
}

Set-Location -LiteralPath $repoPath
[Environment]::CurrentDirectory = $PWD.Path
Write-Ok "Repository: $repoPath"

# ── 1c. Clean working tree ────────────────────────────────────────────────────
$dirty = git status --porcelain 2>&1
if ($dirty) {
    Write-Err "Working tree has uncommitted changes:"
    $dirty | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
    Write-Host "     Stash or commit these before running the restorer." -ForegroundColor Yellow
    exit 1
} else {
    Write-Ok "Working tree is clean."
}

# =============================================================================
#  SECTION 2 - PR DETAILS
# =============================================================================
Write-Step "PR Details"

$url = Read-Host "`n  Paste the GitHub PR URL (or bare PR number)"
if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Err "No input provided."
    exit 1
}

if ($url -match '^\d+$') {
    $prNum = $url
} else {
    $prNum = ($url.TrimEnd('/') -split '/')[(-1)]
}

if ($prNum -notmatch '^\d+$') {
    Write-Err "Could not extract a PR number from: $url"
    exit 1
}

Write-Info "Fetching PR #$prNum metadata from GitHub..."
$ghViewOutput = gh pr view $prNum --json title,state,author,headRefName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "GitHub CLI failed:"
    Write-Host "     $ghViewOutput" -ForegroundColor Yellow
    Write-Host "     Run 'gh auth login' if not authenticated." -ForegroundColor Cyan
    exit 1
}

$prData   = $ghViewOutput | ConvertFrom-Json
$prTitle  = $prData.title
$prState  = $prData.state
$prAuthor = $prData.author.login
$prBranch = $prData.headRefName

Write-Host ""
Write-Host "  PR #$prNum" -ForegroundColor White
Write-Host "  Title  : $prTitle" -ForegroundColor White
Write-Host "  Author : $prAuthor   Branch: $prBranch   State: $prState" -ForegroundColor DarkGray

if ($prState -eq "MERGED") {
    Write-Warn "This PR is already MERGED - its changes may already be in the branch."
    $confirm = Read-Host "  Type YES to restore it anyway"
    if ($confirm -ne "YES") { exit 0 }
}

# =============================================================================
#  SECTION 3 - FETCH AND PATCH DOWNLOAD
# =============================================================================
Write-Step "Fetching PR Head and Diff"

Write-Info "Fetching refs/pull/$prNum/head ..."
git fetch origin "pull/$prNum/head" --quiet 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "git fetch failed. Check your remote and network connection."
    exit 1
}
Write-Ok "PR head fetched into FETCH_HEAD."

$patchFile = Join-Path $repoPath "pr_$prNum.patch"
Remove-PathIfExists $patchFile

Write-Info "Downloading diff for PR #$prNum ..."
$diffExit = Invoke-CmdCommand "gh pr diff $prNum > $(Quote-CmdArgument $patchFile)"
if ($diffExit -ne 0) {
    Write-Err "gh pr diff failed."
    Remove-PathIfExists $patchFile
    exit 1
}

if (-not (Test-Path -LiteralPath $patchFile) -or (Get-Item -LiteralPath $patchFile).Length -eq 0) {
    Write-Err "Patch file is empty or missing. The PR may have no diff, or gh failed."
    exit 1
}

$firstLine = Get-Content -LiteralPath $patchFile -TotalCount 1 -Encoding UTF8
if ($firstLine -notlike "diff --git*") {
    Write-Err "Downloaded file does not look like a valid patch."
    Write-Host "     First line: '$firstLine'" -ForegroundColor DarkGray
    Write-Host "     gh may have returned an error message instead of a diff." -ForegroundColor Yellow
    Get-Content -LiteralPath $patchFile -Encoding UTF8 | Select-Object -First 5 | ForEach-Object {
        Write-Host "     $_" -ForegroundColor DarkGray
    }
    Remove-PathIfExists $patchFile
    exit 1
}
Write-Ok "Valid patch downloaded."

# =============================================================================
#  SECTION 4 - PARSE PATCH FOR AFFECTED FILES
# =============================================================================
Write-Step "Analysing Patch"

$patchContent  = Get-Content -LiteralPath $patchFile -Encoding UTF8
$affectedFiles = New-Object System.Collections.Generic.List[string]
foreach ($line in $patchContent) {
    if ($line -match '^diff --git a/(.+?) b/(.+)$') {
        $pathA = $Matches[1]
        $pathB = $Matches[2]
        $chosenPath = if ($pathB -eq '/dev/null') { $pathA } else { $pathB }

        if (-not $affectedFiles.Contains($chosenPath)) {
            $affectedFiles.Add($chosenPath)
        }
    }
}

if ($affectedFiles.Count -eq 0) {
    Write-Err "Could not find any changed files in the patch."
    Remove-PathIfExists $patchFile
    exit 1
}

Write-Host ""
Write-Host "  This patch touches $($affectedFiles.Count) file(s):" -ForegroundColor White
$affectedFiles | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkYellow }

if ($DryRun) {
    Write-Host ""
    Write-Warn "DRY RUN - no files were modified."
    Write-Host "  Re-run without -DryRun to apply." -ForegroundColor Cyan
    Remove-PathIfExists $patchFile
    exit 0
}

Write-Host ""
$proceed = Read-Host "  Proceed with restore? (Y/n)"
if ($proceed -eq 'n' -or $proceed -eq 'N') {
    Write-Info "Aborted by user."
    Remove-PathIfExists $patchFile
    exit 0
}

# =============================================================================
#  SECTION 5 - APPLY VIA git merge-file
#
#  For each file in the patch we perform a genuine 3-way text merge.
#  All temp files are written via cmd.exe redirection to guarantee correct
#  line endings - PowerShell pipeline encoding corrupts git show output
#  and causes git merge-file to see the entire file as one line, which
#  produces a single giant conflict block instead of surgical markers.
#
#  Three inputs to git merge-file:
#    OURS   = current file on disk (the reset branch)
#    BASE   = file at FETCH_HEAD~1 (where the PR author branched from)
#             Falls back to OURS if unavailable.
#    THEIRS = file at FETCH_HEAD (tip of the PR branch)
#
#  git merge-file modifies the OURS temp file in place, then we copy it
#  back over the working copy. No commits are made.
#    Exit  0  = clean merge
#    Exit >0  = N conflict blocks written as inline markers
#    Exit <0  = error (e.g. binary file)
# =============================================================================
Write-Step "Applying Changes"

$tempDir       = Join-Path $repoPath ".pr_restore_tmp"
$cleanFiles    = @()
$conflictFiles = @()
$newFiles      = @()
$deletedFiles  = @()
$skippedFiles  = @()
$binaryFiles   = @()

Remove-PathIfExists $tempDir
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    foreach ($relPath in $affectedFiles) {

        $normalizedRelPath = $relPath -replace '/', '\\'
        $absPath  = Join-Path $repoPath $normalizedRelPath
        $safeName = Get-SafeTempName $relPath

        Write-Host ""
        Write-Host "  -- $relPath" -ForegroundColor White

        $theirsExists = Get-GitObjectExists "FETCH_HEAD:$relPath"
        $oursExists   = Test-Path -LiteralPath $absPath

        # ── New file added by the PR ──────────────────────────────────────────
        if ((-not $oursExists) -and $theirsExists) {
            Write-Info "New file - writing directly from PR head."
            New-ParentDirectory $absPath
            $exitCode = Write-GitObjectToFile "FETCH_HEAD:$relPath" $absPath (Get-GitContentEncoding $relPath)
            if ($exitCode -eq 0) {
                $newFiles += $relPath
                Write-Ok "Created: $relPath"
            } else {
                Write-Err "Failed to write new file: $relPath"
                $skippedFiles += $relPath
            }
            continue
        }

        # ── File deleted by the PR ────────────────────────────────────────────
        if ($oursExists -and (-not $theirsExists)) {
            Write-Info "File deleted by this PR - removing."
            Remove-Item -LiteralPath $absPath -Force
            $deletedFiles += $relPath
            Write-Ok "Deleted: $relPath"
            continue
        }

        # ── Guard: missing from both sides ───────────────────────────────────
        if ((-not $oursExists) -and (-not $theirsExists)) {
            Write-Warn "Cannot find '$relPath' in working tree or PR head - skipping."
            $skippedFiles += $relPath
            continue
        }

        # ── Modified file - 3-way merge ───────────────────────────────────────
        $oursFile   = Join-Path $tempDir "ours_$safeName.tmp"
        $baseFile   = Join-Path $tempDir "base_$safeName.tmp"
        $theirsFile = Join-Path $tempDir "theirs_$safeName.tmp"

        Copy-Item -LiteralPath $absPath -Destination $oursFile -Force

        $fileEncoding = Get-GitContentEncoding $relPath

        $exitCode = Write-GitObjectToFile "FETCH_HEAD:$relPath" $theirsFile $fileEncoding
        if ($exitCode -ne 0) {
            Write-Err "Could not retrieve THEIRS for '$relPath' - skipping."
            $skippedFiles += $relPath
            continue
        }

        if (Get-GitObjectExists "FETCH_HEAD~1:$relPath") {
            $exitCode = Write-GitObjectToFile "FETCH_HEAD~1:$relPath" $baseFile $fileEncoding
            if ($exitCode -ne 0) {
                Copy-Item -LiteralPath $absPath -Destination $baseFile -Force
                Write-Warn "Could not write BASE from FETCH_HEAD~1 - using OURS as base."
            } else {
                Write-Info "Base: FETCH_HEAD~1"
            }
        } else {
            Copy-Item -LiteralPath $absPath -Destination $baseFile -Force
            Write-Warn "File not present at FETCH_HEAD~1 - using OURS as base (merge may be noisier)."
        }

        $mergeArgs = @(
            "merge-file",
            "-L", "Current branch",
            "-L", "Base",
            "-L", "PR #${prNum}: $prTitle",
            "--",
            $oursFile,
            $baseFile,
            $theirsFile
        )

        & git @mergeArgs 2>&1 | Out-Null
        $mergeExit = $LASTEXITCODE

        $hasConflictMarkers = $false
        if (Test-Path -LiteralPath $oursFile) {
            $hasConflictMarkers = Select-String -LiteralPath $oursFile -SimpleMatch "<<<<<<< Current branch", "=======", ">>>>>>> PR #${prNum}:" -Quiet
        }

        if ($mergeExit -ge 0 -and (Test-Path -LiteralPath $oursFile)) {
            New-ParentDirectory $absPath
            Copy-Item -LiteralPath $oursFile -Destination $absPath -Force
        }

        if ($mergeExit -eq 0 -and -not $hasConflictMarkers) {
            $cleanFiles += $relPath
            Write-Ok "Clean merge."
        } elseif ($mergeExit -gt 0 -or $hasConflictMarkers) {
            $conflictFiles += $relPath
            if ($hasConflictMarkers -and $mergeExit -eq 0) {
                Write-Warn "Conflict markers detected even though git returned 0 - file flagged for manual review."
            } else {
                Write-Warn "$mergeExit conflict block(s) - markers written into file."
            }
        } else {
            Write-Err "git merge-file error (exit $mergeExit) - file may be binary."
            Write-Host "     Restore this file manually from the PR." -ForegroundColor Yellow
            $conflictFiles += $relPath
            $binaryFiles += $relPath
        }
    }
}
finally {
    Remove-PathIfExists $tempDir
    Remove-PathIfExists $patchFile
}

# =============================================================================
#  SECTION 6 - FINAL SUMMARY
# =============================================================================
$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-Step "Summary"
Write-Host ""
Write-Host "  Files processed  : $($affectedFiles.Count)" -ForegroundColor White

if ($cleanFiles.Count    -gt 0) { Write-Ok   "Clean merges  : $($cleanFiles.Count)  ($($cleanFiles -join ', '))" }
if ($newFiles.Count      -gt 0) { Write-Ok   "New files     : $($newFiles.Count)  ($($newFiles -join ', '))" }
if ($deletedFiles.Count  -gt 0) { Write-Ok   "Deleted files : $($deletedFiles.Count)  ($($deletedFiles -join ', '))" }
if ($conflictFiles.Count -gt 0) { Write-Warn "Conflicts     : $($conflictFiles.Count)  ($($conflictFiles -join ', '))" }
if ($binaryFiles.Count   -gt 0) { Write-Warn "Binary/manual : $($binaryFiles.Count)  ($($binaryFiles -join ', '))" }
if ($skippedFiles.Count  -gt 0) { Write-Warn "Skipped files : $($skippedFiles.Count)  ($($skippedFiles -join ', '))" }

Write-Host "  Elapsed          : ${elapsed}s" -ForegroundColor DarkGray
Write-Host ""

if ($conflictFiles.Count -eq 0 -and $skippedFiles.Count -eq 0) {
    Write-Host "  +----------------------------------------------+" -ForegroundColor Green
    Write-Host "  |   All changes applied cleanly.               |" -ForegroundColor Green
    Write-Host "  |   Review in your IDE, then commit and push.  |" -ForegroundColor Green
    Write-Host "  +----------------------------------------------+" -ForegroundColor Green
} else {
    if ($conflictFiles.Count -gt 0) {
        Write-Host "  These files contain conflict markers to resolve:" -ForegroundColor Yellow
        $conflictFiles | ForEach-Object { Write-Host "     -> $_" -ForegroundColor DarkYellow }
        Write-Host ""
        Write-Host "  Open each file in your IDE and search for conflict marker blocks." -ForegroundColor Cyan
    }

    if ($binaryFiles.Count -gt 0) {
        Write-Host "  Binary files could not be merged automatically and need manual recovery." -ForegroundColor Yellow
    }

    if ($skippedFiles.Count -gt 0) {
        Write-Host "  Some files were skipped because the script could not retrieve or apply them safely." -ForegroundColor Yellow
    }

    Write-Host "  Once resolved, review all changes, then commit and push." -ForegroundColor Cyan
}

Write-Host ""
