#!/bin/bash

# 1. Set working environment to a clean, up-to-date 402
git fetch origin
git checkout 402
git reset --hard origin/402

echo "================================================"
echo "    402 Wasteland Reconstruction Toolkit"
echo "================================================"
echo "Paste the URLs of the PRs you want to restore (one per line)."
echo "Press [ENTER] on a blank line when you are finished."
echo ""

PR_URLS=()
while true; do
  read -p "> " URL
  # Break the loop if the user just hits enter (blank line)
  if [ -z "$URL" ]; then
    break
  fi
  PR_URLS+=("$URL")
done

if [ ${#PR_URLS[@]} -eq 0 ]; then
  echo "No PRs entered. Exiting."
  exit 0
fi

echo ""
echo "Starting Reconstruction..."

# Loop through the array of URLs
for URL in "${PR_URLS[@]}"; do
  
  # Extract just the PR number from the end of the URL (e.g., /pull/123 -> 123)
  PR_NUM="${URL##*/}"
  
  # Use gh CLI to grab the title so we can use it as the commit message
  PR_TITLE=$(gh pr view "$PR_NUM" --json title -q .title)
  
  echo "------------------------------------------------"
  echo "Restoring PR #$PR_NUM: $PR_TITLE"

  # Fetch the underlying code exactly as it was in the PR, directly from GitHub
  git fetch origin pull/"$PR_NUM"/head
  
  # Use native Git tree-merging to squash all changes into the working directory
  if git merge --squash FETCH_HEAD; then
    echo "✅ Merged cleanly using native Git logic."
    
    # Commit the squashed changes as one single commit
    git commit -m "Restore PR #$PR_NUM: $PR_TITLE"
  else
    echo "❌ CONFLICT DETECTED!"
    echo "Git's native conflict markers have been injected."
    echo "1. Open your IDE and resolve the conflicts."
    echo "2. Add the resolved files (git add .)"
    echo "3. Commit using: git commit -m \"Restore PR #$PR_NUM: $PR_TITLE\""
    echo "4. Come back here and press [ENTER] to continue."

    # Pause execution until the user manually resolves the conflict
    read -p "Press [ENTER] when resolved and committed..."

    # Safety check: Ensure the user actually committed the changes before moving on
    if ! git diff-index --quiet HEAD --; then
         echo "⚠️ Uncommitted changes detected! Aborting script to prevent a cascade failure."
         exit 1
    fi
    echo "✅ Conflict resolved. Moving to next PR..."
  fi
done

echo "------------------------------------------------"
echo "🎉 402 branch has been successfully reconstructed!"
echo "Run 'git push origin 402' to deploy to the wasteland."
