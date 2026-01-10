#!/bin/bash

# ============================================================
# ARO Website Deploy Script
# ============================================================
# Deploys the dist/ folder to the gh-pages branch
# Must be run from the Website/ directory
# ============================================================

set -e

# Ensure we're in the Website directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Deploying ARO Website to gh-pages..."

# Build first
./build.sh

# Get the repo root
REPO_ROOT="$(cd .. && pwd)"

# Create a temporary directory
TEMP_DIR=$(mktemp -d)

# Copy dist contents to temp directory
cp -r dist/* "$TEMP_DIR/"

# Go to repo root for git operations
cd "$REPO_ROOT"

# Save current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Stash any uncommitted changes
STASH_RESULT=$(git stash push -m "deploy-temp" 2>&1) || true

# Check if gh-pages branch exists remotely or locally
if git show-ref --quiet refs/heads/gh-pages || git show-ref --quiet refs/remotes/origin/gh-pages; then
    echo "📦 Switching to existing gh-pages branch..."
    git checkout gh-pages 2>/dev/null || git checkout -b gh-pages origin/gh-pages
    # Clean existing files (except .git)
    find . -maxdepth 1 ! -name '.git' ! -name '.' -exec rm -rf {} +
else
    echo "📦 Creating new gh-pages branch..."
    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true
fi

# Copy new files from temp directory
cp -r "$TEMP_DIR"/* .

# Add all files
git add -A

# Check if there are changes to commit
if git diff --staged --quiet; then
    echo "ℹ️  No changes to deploy."
else
    # Commit
    git commit -m "Deploy website - $(date '+%Y-%m-%d %H:%M:%S')"

    echo "📤 Pushing to gh-pages..."
    git push origin gh-pages --force

    echo "✅ Deployed successfully!"
fi

# Clean up
rm -rf "$TEMP_DIR"

# Return to original branch
git checkout "$CURRENT_BRANCH"

# Restore stashed changes if any
if [[ "$STASH_RESULT" != *"No local changes"* ]]; then
    git stash pop 2>/dev/null || true
fi

echo ""
echo "🎉 Website deployed to gh-pages branch!"
echo "   Site will be available at: https://arolang.github.io/aro/"
