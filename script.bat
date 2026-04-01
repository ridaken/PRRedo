Write-Host "================================================" -ForegroundColor Cyan
Write-Host "    402 Single PR Restorer (Diff Mode)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# 1. Prompt for the repository location and actively strip any accidental quotes
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
    Write-Host "❌ Error: '$repoPath' is not a valid Git repository (no .git folder found)." -ForegroundColor Red
    exit
}

# 4. Change PowerShell's directory AND explicitly force the underlying Windows process directory to match
Set-Location -Path $repoPath
[Environment]::CurrentDirectory = $PWD.Path
Write-Host "✅ Set working directory to: $repoPath" -ForegroundColor Green

# ---------------------------------------------------------
# Repository set. Begin PR Restoration.
# ---------------------------------------------------------

$url = Read-Host "`nPaste the URL of the PR you want to restore"

if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Host "No URL provided. Exiting." -ForegroundColor Yellow
    exit
}

# Extract PR number from the URL
$prNum = ($url -split '/')[-1]

Write-Host "Fetching PR details and isolated diff from GitHub..." -ForegroundColor DarkGray

# Grab the PR Title
$ghOutput = gh pr view $prNum --json title 2>&1

# Check if the GitHub CLI command actually succeeded
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch PR details. The GitHub CLI reported the following error:" -ForegroundColor Red
    Write-Host "$ghOutput" -ForegroundColor Yellow
    Write-Host "`nPlease ensure you are authenticated by running 'gh auth login' in your terminal." -ForegroundColor Cyan
    exit
}

# Parse the JSON for the title
$prData = $ghOutput | ConvertFrom-Json
$prTitle = $prData.title

Write-Host "------------------------------------------------"
Write-Host "Restoring PR #${prNum}: $prTitle" -ForegroundColor Yellow

# Fetch the PR head silently. We don't merge this, but git apply --3way 
# needs the file blobs downloaded locally to calculate the conflict markers.
git fetch origin pull/$prNum/head --quiet

# Download the exact, isolated diff of the PR.
# We use cmd.exe to bypass PowerShell's default UTF-16 encoding, 
# which injects NULL bytes and completely breaks 'git apply'.
cmd.exe /c "gh pr diff $prNum > pr_diff.patch"

# Apply the diff directly over the current code
$applyOutput = git apply --3way pr_diff.patch 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Diff applied cleanly." -ForegroundColor Green
    
    # Stage the applied files and commit
    git add .
    git commit -m "Restore PR #${prNum}: $prTitle"
    
    Write-Host "🎉 PR #${prNum} successfully committed to your local 402 branch!" -ForegroundColor Cyan
} else {
    Write-Host "❌ CONFLICT OR ERROR DETECTED!" -ForegroundColor Red
    Write-Host "Git reported the following:" -ForegroundColor Yellow
    Write-Host $applyOutput -ForegroundColor DarkGray
    Write-Host "`nGit's 3-way merge may have injected conflict markers into the files."
    Write-Host "1. Open your IDE and resolve any conflicts."
    Write-Host "2. Add the resolved files (git add .)"
    Write-Host "3. Commit using: git commit -m `"Restore PR #${prNum}: $prTitle`""
    Write-Host "4. Come back here and press [ENTER] to finish."

    Read-Host "`nPress [ENTER] when resolved and committed..."

    # Safety check: Ensure the user actually committed their fixes
    git diff-index --quiet HEAD --
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠️ Uncommitted changes detected! You'll need to commit them manually." -ForegroundColor Red
    } else {
        Write-Host "✅ Conflict resolved. PR #${prNum} restored!" -ForegroundColor Green
    }
}

# Clean up the temporary patch file
if (Test-Path pr_diff.patch) {
    Remove-Item pr_diff.patch
}
