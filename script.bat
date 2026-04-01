# Ensure working environment is clean
git fetch origin
git checkout 402
git reset --hard origin/402

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "    402 Wasteland Reconstruction Toolkit" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Paste the URLs of the PRs you want to restore (one per line)."
Write-Host "Press [ENTER] on a blank line when you are finished.`n"

$prUrls = @()
while ($true) {
    $url = Read-Host ">"
    # Break the loop if the user just hits enter
    if ([string]::IsNullOrWhiteSpace($url)) {
        break
    }
    $prUrls += $url
}

if ($prUrls.Count -eq 0) {
    Write-Host "No PRs entered. Exiting." -ForegroundColor Yellow
    exit
}

Write-Host "`nStarting Reconstruction..." -ForegroundColor Green

foreach ($url in $prUrls) {
    # Extract PR number from the URL (gets the text after the final slash)
    $prNum = ($url -split '/')[-1]
    
    # Grab the PR title using the GitHub CLI
    $prTitle = gh pr view $prNum --json title -q .title
    
    Write-Host "------------------------------------------------"
    Write-Host "Restoring PR #$prNum: $prTitle" -ForegroundColor Yellow

    # Fetch the hidden PR reference
    git fetch origin pull/$prNum/head
    
    # Attempt native squash merge. 
    # (2>&1 prevents PowerShell from panicking and stopping if Git outputs to stderr)
    $mergeOutput = git merge --squash FETCH_HEAD 2>&1
    
    # $LASTEXITCODE checks if the previous Git command succeeded (0) or failed
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Merged cleanly using native Git logic." -ForegroundColor Green
        git commit -m "Restore PR #$prNum: $prTitle"
    } else {
        Write-Host "❌ CONFLICT DETECTED!" -ForegroundColor Red
        Write-Host "Git's native conflict markers have been injected."
        Write-Host "1. Open your IDE and resolve the conflicts."
        Write-Host "2. Add the resolved files (git add .)"
        Write-Host "3. Commit using: git commit -m `"Restore PR #$prNum: $prTitle`""
        Write-Host "4. Come back here and press [ENTER] to continue."

        Read-Host "Press [ENTER] when resolved and committed..."

        # Safety check: Ensure the user committed their fixes
        git diff-index --quiet HEAD --
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️ Uncommitted changes detected! Aborting script to prevent a cascade failure." -ForegroundColor Red
            exit
        }
        Write-Host "✅ Conflict resolved. Moving to next PR..." -ForegroundColor Green
    }
}

Write-Host "------------------------------------------------"
Write-Host "🎉 402 branch has been successfully reconstructed!" -ForegroundColor Cyan
Write-Host "Run 'git push origin 402' to deploy to the wasteland."
