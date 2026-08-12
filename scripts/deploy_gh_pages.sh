#!/usr/bin/env bash
# Publish output/reports/ (built by the report_output_dir target) to the
# gh-pages branch, verbatim.
#
# Why this exists: GitHub Pages was configured to build from `main` itself
# (Jekyll, path "/"), which means its checkout step clones main's git
# submodules recursively — including external/runpod, a private repo the
# Pages deploy bot has no access to. Every deploy failed at checkout with
# "repository 'https://github.com/rkrug/runpod/' not found". Deploying only
# output/reports/ to a dedicated gh-pages branch sidesteps this entirely:
# that branch never references the submodule at all.
#
# Usage:
#   scripts/deploy_gh_pages.sh
#
# Prerequisite: output/reports/ must already exist and be current, i.e.
#   Rscript -e 'targets::tar_make(names = "report_output_dir")'
# (or a plain tar_make()). This script only publishes what's already on
# disk — it doesn't render or assemble anything itself.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

source_dir="output/reports"
branch="gh-pages"

if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir" 2>/dev/null)" ]; then
	echo "'$source_dir' is missing or empty — nothing to deploy." >&2
	echo "Build it first, e.g.: Rscript -e 'targets::tar_make(names = \"report_output_dir\")'" >&2
	exit 1
fi

worktree_dir="$(mktemp -d)"
cleanup() {
	git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
	rm -rf "$worktree_dir"
}
trap cleanup EXIT

if git show-ref --verify --quiet "refs/heads/$branch"; then
	git worktree add "$worktree_dir" "$branch"
elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
	git fetch origin "$branch"
	git worktree add -b "$branch" "$worktree_dir" "origin/$branch"
else
	echo "Branch '$branch' doesn't exist yet — creating it as an orphan branch."
	git worktree add --orphan -b "$branch" "$worktree_dir"
fi

# Clear everything except .git so pages removed/renamed on this side don't linger.
find "$worktree_dir" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +

cp -R "$source_dir"/. "$worktree_dir"/

cd "$worktree_dir"
git add -A
if git diff --cached --quiet; then
	echo "gh-pages already up to date with output/reports/ — nothing to commit."
	exit 0
fi

git commit -m "Deploy site from $(git -C "$repo_root" rev-parse --short HEAD)" >/dev/null
git push origin "$branch"
echo "Deployed to gh-pages."
