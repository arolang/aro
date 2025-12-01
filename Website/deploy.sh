#!/bin/bash

# ============================================================
# ARO Website Deploy Script
# ============================================================
# Deploys the dist/ folder to the gh-pages branch
# ============================================================

set -e

echo "🚀 Deploying ARO Website to gh-pages..."

# Build first
./build.sh

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository. Please initialize git first."
    exit 1
fi

# Save current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Create a temporary directory
TEMP_DIR=$(mktemp -d)

# Copy dist contents to temp directory
cp -r dist/* "$TEMP_DIR/"

# Check if gh-pages branch exists
if git show-ref --quiet refs/heads/gh-pages; then
    echo "📦 Switching to existing gh-pages branch..."
    git checkout gh-pages
else
    echo "📦 Creating new gh-pages branch..."
    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true
fi

# Remove old files
git rm -rf . 2>/dev/null || true

# Copy new files
cp -r "$TEMP_DIR"/* .

# Add all files
git add -A

# Check if there are changes to commit
if git diff --staged --quiet; then
    echo "ℹ️  No changes to deploy."
else
    # Commit
    git commit -m "Deploy website - $(date '+%Y-%m-%d %H:%M:%S')

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

    echo "📤 Pushing to gh-pages..."
    git push origin gh-pages --force

    echo "✅ Deployed successfully!"
fi

# Clean up
rm -rf "$TEMP_DIR"

# Return to original branch
git checkout "$CURRENT_BRANCH"

echo ""
echo "🎉 Website deployed to gh-pages branch!"
echo "   Enable GitHub Pages in repository settings to go live."
