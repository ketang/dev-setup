#!/usr/bin/env bash
set -euo pipefail

# --- GitHub CLI authentication ---
if gh auth status &>/dev/null; then
    echo "GitHub CLI: already authenticated."
else
    echo "Authenticating with GitHub CLI..."
    gh auth login -p ssh -w
fi

# --- Clone recently-active repos ---
gh_user=$(gh api user --jq '.login')
echo ""
echo "Finding recently-active repos for $gh_user..."

repos=$(gh api search/commits \
    --method GET \
    -f "q=author:$gh_user committer-date:>$(date -d '60 days ago' +%Y-%m-%d)" \
    -f "sort=committer-date" \
    -f "per_page=100" \
    --jq '[.items[].repository.full_name] | unique | .[]' 2>/dev/null || true)

if [ -z "$repos" ]; then
    echo "No recently-active repos found."
else
    for full_name in $repos; do
        repo_name="${full_name##*/}"
        dest="$HOME/project/$repo_name"
        if [ -d "$dest" ]; then
            echo "  $repo_name: already cloned, skipping."
        else
            echo "  Cloning $full_name..."
            git clone "git@github.com:$full_name.git" "$dest"
        fi
    done
fi

# --- NetBird VPN authentication ---
echo ""
echo "Starting NetBird VPN authentication..."
sudo netbird up
