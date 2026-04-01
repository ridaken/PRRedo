Write-Host "================================================" -ForegroundColor Cyan
Write-Host "    402 Single PR Restorer" -ForegroundColor Cyan
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

Write-Host "Fetching PR details from GitHub..." -ForegroundColor DarkGray

# Grab both the PR Title and the Source Branch Name in one call using the GH CLI
# We use 2>&1 to capture any error messages (like the auth warning)
$ghOutput = gh pr view $prNum --json title,headRefName 2>&1

# Check if the GitHub CLI command actually succeeded
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch PR details. The GitHub CLI reported the following error:" -ForegroundColor Red
    Write-Host "$ghOutput" -ForegroundColor Yellow
    Write-Host "`nPlease ensure you are authenticated by running 'gh auth login' in your terminal." -ForegroundColor Cyan
    exit
}

# If successful, parse the JSON
$prData = $ghOutput | ConvertFrom-Json
$prTitle = $prData.title
$branchName = $prData.headRefName

# Double-check that we actually got a branch name back
if ([string]::IsNullOrWhiteSpace($branchName)) {
    Write-Host "❌ Error: Could not determine the source branch name for PR #${prNum}." -ForegroundColor Red
    exit
}

Write-Host "------------------------------------------------"
Write-Host "Restoring PR #${prNum}: $prTitle" -ForegroundColor Yellow
Write-Host "Targeting branch: origin/$branchName" -ForegroundColor DarkGray

# Attempt native squash merge using your local, already-updated remote tracking branch
$mergeOutput = git merge --squash "origin/$branchName" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Merged cleanly using native Git logic." -ForegroundColor Green
    
    # Commit immediately
    git commit -m "Restore PR #${prNum}: $prTitle"
    
    Write-Host "🎉 PR #${prNum} successfully committed to your local 402 branch!" -ForegroundColor Cyan
} else {
    Write-Host "❌ CONFLICT DETECTED!" -ForegroundColor Red
    Write-Host "Git's native conflict markers have been injected."
    Write-Host "1. Open your IDE and resolve the conflicts."
    Write-Host "2. Add the resolved files (git add .)"
    Write-Host "3. Commit using: git commit -m `"Restore PR #${prNum}: $prTitle`""
    Write-Host "4. Come back here and press [ENTER] to finish."

    Read-Host "`nPress [ENTER] when resolved and committed..."

    # Safety check: Ensure the user committed their fixes
    git diff-index --quiet HEAD --
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠️ Uncommitted changes detected! You'll need to commit them manually." -ForegroundColor Red
        exit
    }
    Write-Host "✅ Conflict resolved. PR #${prNum} restored!" -ForegroundColor Green
}
