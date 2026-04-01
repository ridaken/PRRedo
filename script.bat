Write-Host "================================================" -ForegroundColor Cyan
Write-Host "    402 Single PR Restorer (Diff Mode) v2" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# 1. Prompt for the repository location and strip accidental quotes
$rawInput = Read-Host "Enter the full path to your local git repository (e.g., C:\dev\monolith)"
$repoPath = $rawInput.Trim('"').Trim("'")

# 2. Validate the directory exists
if (-Not (Test-Path -Path $repoPath)) {
    Write-Host "❌ Error: The directory '$repoPath' does not exist." -ForegroundColor Red
    exit
}

# 3. Validate it is actually a Git repository
$gitPath = Join-Path -Path $repoPath -ChildPath ".git"
if (-Not (Test-Path -Path $gitPath)) {
    Write-Host "❌ Error: '$repoPath' is not a valid Git repository." -ForegroundColor Red
    exit
}

# 4. Set working directory (PowerShell + underlying process)
Set-Location -Path $repoPath
[Environment]::CurrentDirectory = $PWD.Path
Write-Host "✅ Working directory: $repoPath" -ForegroundColor Green

# ---------------------------------------------------------
# Repository set. Begin PR Restoration.
# ---------------------------------------------------------

$url = Read-Host "`nPaste the URL of the PR you want to restore"
if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Host "No URL provided. Exiting." -ForegroundColor Yellow
    exit
}

$prNum = ($url -split '/')[-1]
Write-Host "Fetching PR details from GitHub..." -ForegroundColor DarkGray

$ghOutput = gh pr view $prNum --json title 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch PR details:" -ForegroundColor Red
    Write-Host "$ghOutput" -ForegroundColor Yellow
    Write-Host "Run 'gh auth login' if not authenticated." -ForegroundColor Cyan
    exit
}

$prData    = $ghOutput | ConvertFrom-Json
$prTitle   = $prData.title
$patchFile = "pr_$prNum.patch"

Write-Host "------------------------------------------------"
Write-Host "Restoring PR #${prNum}: $prTitle" -ForegroundColor Yellow

# Fetch the PR head blobs so --3way has what it needs for object lookup
Write-Host "Fetching PR head ref..." -ForegroundColor DarkGray
git fetch origin "pull/$prNum/head" --quiet

# Download the isolated diff via cmd.exe to guarantee UTF-8 (not PowerShell's UTF-16)
Write-Host "Downloading patch..." -ForegroundColor DarkGray
cmd.exe /c "gh pr diff $prNum > $patchFile"

if (-Not (Test-Path $patchFile) -or (Get-Item $patchFile).Length -eq 0) {
    Write-Host "❌ Patch file is empty or missing. The PR may have no diff or gh failed." -ForegroundColor Red
    exit
}

# ---------------------------------------------------------
# ATTEMPT 1: Clean apply with context tolerance
#   --3way          : fall back to 3-way merge on context mismatch
#   --recount       : recount hunk lengths in case line counts drifted
#   --whitespace=fix: silently fix whitespace issues instead of erroring
# ---------------------------------------------------------
Write-Host "`nAttempting clean apply (with context tolerance)..." -ForegroundColor DarkGray
$applyOutput = git apply --3way --recount --whitespace=fix $patchFile 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Diff applied cleanly!" -ForegroundColor Green
    git add .
    git commit -m "Restore PR #${prNum}: $prTitle"
    Write-Host "🎉 PR #${prNum} successfully committed to local 402!" -ForegroundColor Cyan
    if (Test-Path $patchFile) { Remove-Item $patchFile }
    exit
}

Write-Host "⚠️  Clean apply failed. Conflict details:" -ForegroundColor Yellow
Write-Host $applyOutput -ForegroundColor DarkGray

# ---------------------------------------------------------
# ATTEMPT 2: --reject mode
#   Instead of aborting entirely, git writes .rej files for hunks
#   that can't apply, and DOES apply everything else cleanly.
#   This gives the developer a surgical list of what needs manual work.
# ---------------------------------------------------------
Write-Host "`nFalling back to --reject mode (applies what it can, writes .rej for the rest)..." -ForegroundColor Yellow
git apply --reject --recount --whitespace=fix $patchFile 2>&1 | Out-Null

# Find all .rej files so we can tell the developer exactly what needs attention
$rejFiles = Get-ChildItem -Path $repoPath -Filter "*.rej" -Recurse | Select-Object -ExpandProperty FullName

Write-Host "`n❌ Some hunks could not be applied automatically." -ForegroundColor Red

if ($rejFiles.Count -gt 0) {
    Write-Host "`nThe following .rej files show the exact lines that need manual merging:" -ForegroundColor Yellow
    $rejFiles | ForEach-Object { Write-Host "  → $_" -ForegroundColor DarkYellow }
    Write-Host "`nFor each .rej file:" -ForegroundColor Cyan
    Write-Host "  1. Open the corresponding source file in your IDE"
    Write-Host "  2. The .rej file shows the hunk Git couldn't place — find where it belongs and apply it manually"
    Write-Host "  3. Delete the .rej file when done"
} else {
    Write-Host "No .rej files found — the conflict may be tracked as standard Git conflict markers." -ForegroundColor Yellow
    Write-Host "Open your IDE and look for <<<<<<< markers." -ForegroundColor Cyan
}

Write-Host "`nOnce all conflicts are resolved:"
Write-Host "  git add ."
Write-Host "  git commit -m `"Restore PR #${prNum}: $prTitle`""
Read-Host "`nPress [ENTER] when you have committed the resolved changes..."

# Safety check: confirm the user actually committed
git diff-index --quiet HEAD --
if ($LASTEXITCODE -ne 0) {
    Write-Host "⚠️  Uncommitted changes still detected. Commit them manually before continuing." -ForegroundColor Red
} else {
    Write-Host "✅ All clean. PR #${prNum} restored!" -ForegroundColor Green
}

# Cleanup
if (Test-Path $patchFile) { Remove-Item $patchFile }
