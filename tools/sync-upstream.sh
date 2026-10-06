#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 jtomchak
# Keep fork main pristine and merge upstream into the current feature branch.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
branch=$(git symbolic-ref --quiet --short HEAD) || {
    echo "Check out main or a feature branch before syncing." >&2; exit 1;
}
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash local changes before syncing." >&2; exit 1
fi
git fetch origin
git fetch upstream main
if ! git merge-base --is-ancestor origin/main upstream/main; then
    echo "Fork main has diverged. Keep custom work on a feature branch; no refs were overwritten." >&2
    exit 1
fi
# No force: a concurrent change on GitHub is rejected rather than overwritten.
git push origin refs/remotes/upstream/main:refs/heads/main
if [ "$branch" = main ]; then
    git merge --ff-only upstream/main
else
    # Merge preserves the history of already-published feature branches.
    # Conflicts stay visible for normal resolution; never reset or force-push.
    git merge --no-edit upstream/main
fi
echo "Synced upstream into $branch. Run tests before pushing your feature branch."
