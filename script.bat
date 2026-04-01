# =============================================================================
#  restore_402.ps1  -  402 Wasteland PR Restorer  (merge-file edition)
#
#  USAGE:
#    .\restore_402.ps1              Normal run
#    .\restore_402.ps1 -DryRun      Preview only - no files are modified
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

# Conflict marker strings stored in variables to avoid PowerShell parser issues
$markerConflict = "CONFLICT MARKERS"
$markerOpen     = "<<< CONFLICT"
$markerSep      = "=== SEPARATOR"
$markerClose    = ">>> END"

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Ok   { param($t) Write-Host "  [OK]  $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "  [!!]  $t" -ForegroundColor Yellow }
function Write-Err  { param($t) Write-Host "  [XX]  $t" -ForegroundColor Red }
function Write-Info { param($t) Write-Host "  [ ]   $t" -ForegroundColor DarkGray }
function Write-Step { param($t) Write-Host "`n[ $t ]" -ForegroundColor Magenta }

# ── Banner ────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |      402 Wasteland  -  PR Restorer  v3       |" -ForegroundColor Cyan
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
    Write-Warn "Continuing on '$currentBranch' at user request."
} else {
    Write-Ok "Branch: 402  (confirmed)"
}

# ── 1d. Clean working tree ────────────────────────────────────────────────────
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
Write-Host "  PR #$prNum" -ForegroundColor White
Write-Host "  Title  : $prTitle" -ForegroundColor White
Write-Host "  Author : $prAuthor   Branch: $prBranch   State: $prState" -ForegroundColor DarkGray

if ($prState -eq "MERGED") {
    Write-Warn "This PR is already MERGED - its changes may already be in 402."
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

if (Test-Path $patchFile) {
    Write-Warn "Stale patch file found from a previous run - removing."
    Remove-Item $patchFile
}

Write-Info "Downloading diff for PR #$prNum ..."
cmd.exe /c "gh pr diff $prNum > `"$patchFile`""

if (-not (Test-Path $patchFile) -or (Get-Item $patchFile).Length -eq 0) {
    Write-Err "Patch file is empty or missing. The PR may have no diff, or gh failed."
    exit 1
}

# Confirm it is a real diff and not a gh error message written to stdout
$firstLine = Get-Content $patchFile -TotalCount 1
if ($firstLine -notlike "diff --git*") {
    Write-Err "Downloaded file does not look like a valid patch."
    Write-Host "     First line: '$firstLine'" -ForegroundColor DarkGray
    Write-Host "     gh may have returned an error message instead of a diff." -ForegroundColor Yellow
    Get-Content $patchFile | Select-Object -First 5 | ForEach-Object {
        Write-Host "     $_" -ForegroundColor DarkGray
    }
    Remove-Item $patchFile
    exit 1
}
Write-Ok "Valid patch downloaded."

# =============================================================================
#  SECTION 4 - PARSE PATCH FOR AFFECTED FILES
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
    Write-Warn "DRY RUN - no files were modified."
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
#  SECTION 5 - APPLY VIA git merge-file
#
#  For each file in the patch we perform a genuine 3-way text merge.
#  This bypasses git apply entirely and guarantees that conflicts produce
#  inline markers in the file rather than .rej sidecar files.
#
#  Three inputs to git merge-file:
#    OURS   = current file on disk in 402 (the freshly reset branch)
#    BASE   = file at FETCH_HEAD~1 (approximates where the PR author branched)
#             Falls back to OURS if unavailable.
#    THEIRS = file at FETCH_HEAD (tip of the PR branch)
#
#  git merge-file modifies the OURS file in place.
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

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($relPath in $affectedFiles) {

    $absPath = Join-Path $repoPath ($relPath -replace '/', '\')

    Write-Host ""
    Write-Host "  -- $relPath" -ForegroundColor White

    $theirsRaw    = git show "FETCH_HEAD:$relPath" 2>&1
    $theirsExists = ($LASTEXITCODE -eq 0)
    $oursExists   = (Test-Path $absPath)

    # ── New file added by the PR ──────────────────────────────────────────────
    if ((-not $oursExists) -and $theirsExists) {
        Write-Info "New file - writing directly from PR head."
        $dir = Split-Path $absPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $safeName   = $relPath -replace '[/\\:]', '_'
        $newFileTmp = Join-Path $tempDir "new_$safeName"
        $theirsRaw | Set-Content -Path $newFileTmp -Encoding UTF8 -NoNewline
        Copy-Item $newFileTmp $absPath -Force
        $newFiles += $relPath
        Write-Ok "Created: $relPath"
        continue
    }

    # ── File deleted by the PR ────────────────────────────────────────────────
    if ($oursExists -and (-not $theirsExists)) {
        Write-Info "File deleted by this PR - removing."
        Remove-Item $absPath -Force
        $deletedFiles += $relPath
        Write-Ok "Deleted: $relPath"
        continue
    }

    # ── Guard: missing from both sides ───────────────────────────────────────
    if ((-not $oursExists) -and (-not $theirsExists)) {
        Write-Warn "Cannot find '$relPath' in OURS or THEIRS - skipping."
        continue
    }

    # ── Modified file - 3-way merge ───────────────────────────────────────────
    $safeName   = $relPath -replace '[/\\:]', '_'
    $oursFile   = Join-Path $tempDir "ours_$safeName"
    $baseFile   = Join-Path $tempDir "base_$safeName"
    $theirsFile = Join-Path $tempDir "theirs_$safeName"

    Copy-Item $absPath $oursFile

    $theirsRaw | Set-Content -Path $theirsFile -Encoding UTF8 -NoNewline

    $baseRaw = git show "FETCH_HEAD~1:$relPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $baseRaw | Set-Content -Path $baseFile -Encoding UTF8 -NoNewline
        Write-Info "Base: FETCH_HEAD~1"
    } else {
        Copy-Item $absPath $baseFile
        Write-Warn "FETCH_HEAD~1 has no copy of this file - using OURS as base (merge may be noisier)."
    }

    # Build args array to avoid backtick line continuation bugs in PowerShell
    $mergeArgs = @(
        "-L", "402 (current)",
        "-L", "base",
        "-L", "PR #${prNum}: $prTitle",
        $oursFile,
        $baseFile,
        $theirsFile
    )

    git merge-file @mergeArgs 2>&1 | Out-Null
    $mergeExit = $LASTEXITCODE

    Copy-Item $oursFile $absPath -Force

    if ($mergeExit -eq 0) {
        $cleanFiles += $relPath
        Write-Ok "Clean merge."
    } elseif ($mergeExit -gt 0) {
        $conflictFiles += $relPath
        Write-Warn "$mergeExit conflict block(s) - markers written into file."
    } else {
        Write-Err "git merge-file error on '$relPath' (exit $mergeExit) - may be binary."
        Write-Host "     You will need to restore this file manually." -ForegroundColor Yellow
        $conflictFiles += $relPath
    }
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
#  SECTION 6 - COMMIT OR HAND OFF
# =============================================================================
$elapsed   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$commitMsg = "Restore PR #${prNum}: $prTitle`n`nSource: $url"

Write-Step "Summary"
Write-Host ""
Write-Host "  Files processed  : $($affectedFiles.Count)" -ForegroundColor White

if ($cleanFiles.Count   -gt 0) { Write-Ok   "Clean merges  : $($cleanFiles.Count)  ($($cleanFiles -join ', '))" }
if ($newFiles.Count     -gt 0) { Write-Ok   "New files     : $($newFiles.Count)  ($($newFiles -join ', '))" }
if ($deletedFiles.Count -gt 0) { Write-Ok   "Deleted files : $($deletedFiles.Count)  ($($deletedFiles -join ', '))" }
if ($conflictFiles.Count -gt 0){ Write-Warn "Conflicts     : $($conflictFiles.Count)  ($($conflictFiles -join ', '))" }

Write-Host "  Elapsed          : ${elapsed}s" -ForegroundColor DarkGray
Write-Host ""

# ── All clean - auto commit ───────────────────────────────────────────────────
if ($conflictFiles.Count -eq 0) {
    git add .
    git commit -m $commitMsg

    Write-Host "  +----------------------------------------------+" -ForegroundColor Green
    Write-Host "  |   PR #$prNum restored and committed!           |" -ForegroundColor Green
    Write-Host "  +----------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  When ready to push:" -ForegroundColor Cyan
    Write-Host "    git push origin 402" -ForegroundColor White
    Write-Host ""

# ── Conflicts need manual resolution ─────────────────────────────────────────
} else {
    Write-Host "  These files contain conflict markers that need manual resolution:" -ForegroundColor Yellow
    $conflictFiles | ForEach-Object { Write-Host "     -> $_" -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  Steps to resolve:" -ForegroundColor Cyan
    Write-Host "    1. Open each file above in your IDE"
    Write-Host "    2. Search for and resolve all conflict marker blocks"
    Write-Host "    3. git add ."
    Write-Host "    4. git commit -m `"Restore PR #${prNum}: $prTitle`""
    Write-Host "    5. git push origin 402"
    Write-Host ""

    Read-Host "  Press ENTER once you have committed all resolved conflicts..."

    git diff-index --quiet HEAD -- 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Uncommitted changes still detected - please commit before continuing."
    } else {
        $markerCheck = git diff --check 2>&1
        if ($markerCheck) {
            Write-Warn "Possible leftover conflict markers detected:"
            $markerCheck | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        } else {
            Write-Ok "All conflicts resolved. PR #$prNum restored successfully!"
            Write-Host ""
            Write-Host "  When ready to push:" -ForegroundColor Cyan
            Write-Host "    git push origin 402" -ForegroundColor White
            Write-Host ""
        }
    }
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
if (Test-Path $patchFile) { Remove-Item $patchFile -ErrorAction SilentlyContinue }
