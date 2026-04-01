# =============================================================================
#  restore_402.ps1  —  402 Wasteland PR Restorer  (merge-file edition)
#
#  USAGE:
#    .\restore_402.ps1              Normal run
#    .\restore_402.ps1 -DryRun      Preview only — no files are modified
#
#  REQUIREMENTS:
#    - Run AFTER you have already done: git fetch && git checkout 402
#    - A portable gh.exe must be on your PATH (or next to this script)
# =============================================================================
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$startTime = Get-Date

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Ok   { param($t) Write-Host "  ✅  $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "  ⚠️   $t" -ForegroundColor Yellow }
function Write-Err  { param($t) Write-Host "  ❌  $t" -ForegroundColor Red }
function Write-Info { param($t) Write-Host "  •   $t" -ForegroundColor DarkGray }
function Write-Step { param($t) Write-Host "`n[ $t ]" -ForegroundColor Magenta }

# ── Banner ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║      402 Wasteland  —  PR Restorer  v3       ║" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  ║           *** DRY RUN MODE ***               ║" -ForegroundColor Yellow
}
Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
#  SECTION 1 — PRE-FLIGHT CHECKS
# =============================================================================
Write-Step "Pre-flight Checks"

# ── 1a. gh CLI reachable? ─────────────────────────────────────────────────────
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    $portableGh = Join-Path $PSScriptRoot "gh.exe"
    if (Test-Path $portableGh) {
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

if (-not (Test-Path -Path $repoPath)) {
    Write-Err "Directory not found: '$repoPath'"
    exit 1
}
if (-not (Test-Path (Join-Path $repoPath ".git"))) {
    Write-Err "'$repoPath' is not a Git repository (no .git folder found)."
    exit 1
}

Set-Location -Path $repoPath
[Environment]::CurrentDirectory = $PWD.Path
Write-Ok "Repository: $repoPath"

# ── 1c. Must be on 402 ────────────────────────────────────────────────────────
$currentBranch = git branch --show-current 2>&1
if ($currentBranch -ne "402") {
    Write-Err "You are on branch '$currentBranch', not '402'."
    Write-Host "     Run: git checkout 402" -ForegroundColor Yellow
    $confirm = Read-Host "`n  Type YES to continue anyway (not recommended)"
    if ($confirm -ne "YES") { exit 1 }
    Write-Warn "Continuing on '$currentBranch' at user's request."
} else {
    Write-Ok "Branch: 402  ✓"
}

# ── 1d. Clean working tree ────────────────────────────────────────────────────
$dirty = git status --porcelain 2>&1
if ($dirty) {
    Write-Err "Working tree has uncommitted changes:"
    $dirty | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
    Write-Host "     Stash or commit these before running the restorer." -ForegroundColor Yellow
    exit 1
} else {
    Write-Ok "Working tree is clean  ✓"
}

# =============================================================================
#  SECTION 2 — PR DETAILS
# =============================================================================
Write-Step "PR Details"

$url = Read-Host "`n  Paste the GitHub PR URL (or bare PR number)"
if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Err "No input provided."
    exit 1
}

# Accept both a full URL and a bare number
if ($url -match '^\d+$') {
    $prNum = $url
} else {
    $prNum = ($url -split '/')[-1]
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
Write-Host "  ┌─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  │  PR #$prNum" -ForegroundColor White
Write-Host "  │  $prTitle" -ForegroundColor White
Write-Host "  │  Author: $prAuthor   Branch: $prBranch   State: $prState" -ForegroundColor DarkGray
Write-Host "  └─────────────────────────────────────────────────" -ForegroundColor DarkGray

if ($prState -eq "MERGED") {
    Write-Warn "This PR is already MERGED — its changes may already be in 402."
    $confirm = Read-Host "  Type YES to restore it anyway"
    if ($confirm -ne "YES") { exit 0 }
}

# =============================================================================
#  SECTION 3 — FETCH & PATCH DOWNLOAD
# =============================================================================
Write-Step "Fetching PR Head & Diff"

# Fetch the PR head ref — populates FETCH_HEAD and downloads all blobs
Write-Info "Fetching refs/pull/$prNum/head ..."
git fetch origin "pull/$prNum/head" --quiet 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "git fetch failed. Check your remote and network connection."
    exit 1
}
Write-Ok "PR head fetched → FETCH_HEAD"

# Download the patch via cmd.exe to avoid PowerShell's UTF-16 redirection
$patchFile = Join-Path $repoPath "pr_$prNum.patch"

if (Test-Path $patchFile) {
    Write-Warn "Stale patch file found from a previous run — removing."
    Remove-Item $patchFile
}

Write-Info "Downloading diff for PR #$prNum ..."
cmd.exe /c "gh pr diff $prNum > `"$patchFile`""

if (-not (Test-Path $patchFile) -or (Get-Item $patchFile).Length -eq 0) {
    Write-Err "Patch file is empty or missing. The PR may have no diff, or gh failed."
    exit 1
}

# Sanity-check: gh errors land in stdout too, so confirm it's a real diff
$firstLine = Get-Content $patchFile -TotalCount 1
if ($firstLine -notlike "diff --git*") {
    Write-Err "Downloaded file does not look like a valid patch."
    Write-Host "     First line: '$firstLine'" -ForegroundColor DarkGray
    Write-Host "     This usually means gh returned an error message instead of a diff." -ForegroundColor Yellow
    Get-Content $patchFile | Select-Object -First 5 |
        ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    Remove-Item $patchFile
    exit 1
}
Write-Ok "Valid patch downloaded."

# =============================================================================
#  SECTION 4 — PARSE PATCH FOR AFFECTED FILES
# =============================================================================
Write-Step "Analysing Patch"

$patchContent  = Get-Content $patchFile
$affectedFiles = @()
foreach ($line in $patchContent) {
    if ($line -match '^diff --git a/.+ b/(.+)$') {
        $affectedFiles += $Matches[1]
    }
}

if ($affectedFiles.Count -eq 0) {
    Write-Err "Could not find any changed files in the patch."
    Remove-Item $patchFile
    exit 1
}

Write-Host ""
Write-Host "  This patch touches $($affectedFiles.Count) file(s):" -ForegroundColor White
$affectedFiles | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkYellow }

# ── Dry-run exits here ────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host ""
    Write-Warn "DRY RUN — no files were modified."
    Write-Host "  Re-run without -DryRun to apply." -ForegroundColor Cyan
    Remove-Item $patchFile
    exit 0
}

Write-Host ""
$proceed = Read-Host "  Proceed with restore? (Y/n)"
if ($proceed -eq 'n' -or $proceed -eq 'N') {
    Write-Info "Aborted by user."
    Remove-Item $patchFile
    exit 0
}

# =============================================================================
#  SECTION 5 — APPLY VIA git merge-file
#
#  For each file in the patch we perform a genuine 3-way text merge using
#  git merge-file. This completely bypasses git apply's object-store lookup,
#  which is why --3way was silently falling back to --reject mode.
#
#  Three inputs:
#    OURS   = current file on disk in 402 (the freshly reset branch)
#    BASE   = file at FETCH_HEAD~1 (the commit the PR author branched from)
#             Falls back to OURS if the file wasn't present at that commit.
#    THEIRS = file at FETCH_HEAD (the tip of the PR branch)
#
#  git merge-file modifies OURS in place.
#    Exit 0        → clean merge, no conflicts
#    Exit > 0      → N conflict blocks were injected as <<<<<<< markers
#    Exit negative → error
# =============================================================================
Write-Step "Applying Changes (git merge-file)"

$tempDir       = Join-Path $repoPath ".pr_restore_tmp"
$cleanFiles    = @()
$conflictFiles = @()
$newFiles      = @()
$deletedFiles  = @()

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($relPath in $affectedFiles) {

    # Normalise path separators for the current OS
    $absPath = Join-Path $repoPath ($relPath -replace '/', '\')

    Write-Host ""
    Write-Host "  ── $relPath" -ForegroundColor White

    # Check existence in OURS (disk) and THEIRS (FETCH_HEAD)
    $theirsContent = git show "FETCH_HEAD:$relPath" 2>&1
    $theirsExists  = ($LASTEXITCODE -eq 0)
    $oursExists    = (Test-Path $absPath)

    # ── New file added by the PR ──────────────────────────────────────────────
    if (-not $oursExists -and $theirsExists) {
        Write-Info "New file — writing directly from PR head."
        $dir = Split-Path $absPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Write via temp to avoid pipeline encoding issues
        $newFileTmp = Join-Path $tempDir "new_$($relPath -replace '[/\\:]','_')"
        git show "FETCH_HEAD:$relPath" | Set-Content -Path $newFileTmp -Encoding UTF8 -NoNewline
        Copy-Item $newFileTmp $absPath -Force
        $newFiles += $relPath
        Write-Ok "Created: $relPath"
        continue
    }

    # ── File deleted by the PR ────────────────────────────────────────────────
    if ($oursExists -and -not $theirsExists) {
        Write-Info "File deleted by this PR — removing from working tree."
        Remove-Item $absPath -Force
        $deletedFiles += $relPath
        Write-Ok "Deleted: $relPath"
        continue
    }

    # ── Guard: file missing from both sides ───────────────────────────────────
    if (-not $oursExists -and -not $theirsExists) {
        Write-Warn "Cannot find '$relPath' in OURS or THEIRS — skipping."
        continue
    }

    # ── Modified file — 3-way merge ───────────────────────────────────────────

    # Use a flat filename in temp so we don't have to recreate directory trees
    $safeName    = $relPath -replace '[/\\:]', '_'
    $oursFile    = Join-Path $tempDir "ours_$safeName"
    $baseFile    = Join-Path $tempDir "base_$safeName"
    $theirsFile  = Join-Path $tempDir "theirs_$safeName"

    # OURS — copy the live file
    Copy-Item $absPath $oursFile

    # THEIRS — PR head
    git show "FETCH_HEAD:$relPath" | Set-Content -Path $theirsFile -Encoding UTF8 -NoNewline

    # BASE — try FETCH_HEAD~1 (parent of the PR tip, i.e. where the author branched from)
    $baseContent = git show "FETCH_HEAD~1:$relPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $baseContent | Set-Content -Path $baseFile -Encoding UTF8 -NoNewline
        Write-Info "Base: FETCH_HEAD~1"
    } else {
        # Fallback: use OURS as base. The merge will treat all of THEIRS'
        # changes as "new" relative to the base, which is noisier but still
        # produces usable conflict markers rather than .rej files.
        Copy-Item $absPath $baseFile
        Write-Warn "FETCH_HEAD~1 has no copy of this file — using OURS as base (noisier merge)."
    }

    # Run the merge — modifies $oursFile in place
    git merge-file `
        -L "402 (current)" `
        -L "base" `
        -L "PR #${prNum}: $prTitle" `
        $oursFile $baseFile $theirsFile 2>&1 | Out-Null

    $mergeExit = $LASTEXITCODE

    # Copy the result back over the live file
    Copy-Item $oursFile $absPath -Force

    if ($mergeExit -eq 0) {
        $cleanFiles += $relPath
        Write-Ok "Clean merge."
    } elseif ($mergeExit -gt 0) {
        $conflictFiles += $relPath
        Write-Warn "$mergeExit conflict block(s) — markers written to file."
    } else {
        # Negative exit = git merge-file error (e.g. binary file)
        Write-Err "git merge-file returned an error for '$relPath' (exit $mergeExit)."
        Write-Host "     This file may be binary. You will need to restore it manually." -ForegroundColor Yellow
        $conflictFiles += $relPath
    }
}

# Cleanup temp dir
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
#  SECTION 6 — COMMIT OR HAND OFF TO DEVELOPER
# =============================================================================
$elapsed   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$commitMsg = "Restore PR #${prNum}: $prTitle`n`nSource: $url"

Write-Step "Summary"
Write-Host ""
Write-Host "  Files processed  : $($affectedFiles.Count)" -ForegroundColor White
if ($cleanFiles.Count    -gt 0) { Write-Ok   "Clean merges  : $($cleanFiles.Count)  — $($cleanFiles -join ', ')" }
if ($newFiles.Count      -gt 0) { Write-Ok   "New files     : $($newFiles.Count)  — $($newFiles -join ', ')" }
if ($deletedFiles.Count  -gt 0) { Write-Ok   "Deleted files : $($deletedFiles.Count)  — $($deletedFiles -join ', ')" }
if ($conflictFiles.Count -gt 0) { Write-Warn "Conflicts     : $($conflictFiles.Count)  — $($conflictFiles -join ', ')" }
Write-Host "  Elapsed          : ${elapsed}s" -ForegroundColor DarkGray
Write-Host ""

# ── All clean ─────────────────────────────────────────────────────────────────
if ($conflictFiles.Count -eq 0) {
    git add .
    git commit -m $commitMsg

    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║   🎉  PR #$prNum restored and committed!       ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  When you're ready to push:" -ForegroundColor Cyan
    Write-Host "    git push origin 402" -ForegroundColor White
    Write-Host ""

# ── Conflicts to resolve ───────────────────────────────────────────────────────
} else {
    Write-Host "  The following files contain conflict markers ( <<<<<<< / ======= / >>>>>>> ):" -ForegroundColor Yellow
    $conflictFiles | ForEach-Object { Write-Host "     → $_" -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Steps to resolve:" -ForegroundColor Cyan
    Write-Host "    1. Open each file above in your IDE"
    Write-Host "    2. Resolve all <<<<<<< conflict markers"
    Write-Host "    3. git add ."
    Write-Host "    4. git commit -m `"Restore PR #${prNum}: $prTitle`""
    Write-Host "    5. git push origin 402"
    Write-Host ""

    Read-Host "  Press [ENTER] once you have committed all resolved conflicts..."

    # Confirm the user actually committed
    git diff-index --quiet HEAD -- 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Uncommitted changes still detected — please commit before continuing."
    } else {
        # Double-check for leftover conflict markers
        $markerCheck = git diff --check 2>&1
        if ($markerCheck) {
            Write-Warn "Possible leftover conflict markers detected:"
            $markerCheck | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        } else {
            Write-Ok "All conflicts resolved. PR #$prNum restored successfully!"
            Write-Host ""
            Write-Host "  When you're ready to push:" -ForegroundColor Cyan
            Write-Host "    git push origin 402" -ForegroundColor White
            Write-Host ""
        }
    }
}

# ── Final cleanup ─────────────────────────────────────────────────────────────
if (Test-Path $patchFile) { Remove-Item $patchFile -ErrorAction SilentlyContinue }
