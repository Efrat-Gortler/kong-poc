#!/usr/bin/env bash
# Takes the commits Claude prepared (a git bundle saved into your Windows folder),
# fast-forwards your clone, and pushes to GitHub with YOUR credentials (gh auth login).
#   scripts/sync-from-claude.sh /mnt/c/Users/<you>/Desktop/<folder>/kong-poc.bundle
source "$(dirname "$0")/lib.sh"
need git
bundle="${1:?usage: $0 <path to kong-poc.bundle>}"
[[ -f "$bundle" ]] || die "no such file: $bundle"
git -C "$REPO_ROOT" bundle verify -q "$bundle" >/dev/null || die "not a valid bundle (or it needs commits you don't have)"
git -C "$REPO_ROOT" fetch -q origin main
git -C "$REPO_ROOT" fetch -q "$bundle" main:refs/claude/main
git -C "$REPO_ROOT" merge-base --is-ancestor origin/main refs/claude/main \
  || die "GitHub has commits Claude's bundle does not include - tell Claude, don't force anything"
git -C "$REPO_ROOT" checkout -q main
git -C "$REPO_ROOT" merge -q --ff-only refs/claude/main
git -C "$REPO_ROOT" --no-pager log --oneline origin/main..main
git -C "$REPO_ROOT" push -q origin main
log "pushed $(git -C "$REPO_ROOT" rev-parse --short main) to GitHub"
