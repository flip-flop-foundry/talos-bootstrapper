#!/usr/bin/env sh
set -euo pipefail




if [ -z "$GIT_AUTHOR_NAME" ] || [ -z "$GIT_AUTHOR_EMAIL" ] || [ -z "$GIT_BRANCH_NAME" ] || [ -z "$GIT_REMOTE_URL" ] || [ -z "$GIT_COMMIT_MSG" ] || [ -z "$GIT_SOURCE_DIR" ]; then
  echo "Missing one or more required environment variables: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_BRANCH_NAME, GIT_REMOTE_URL, GIT_COMMIT_MSG, GIT_SOURCE_DIR"
  exit 2
fi


# # Fill defaults from git config if not provided
# if [ -z "$GIT_AUTHOR_NAME" ]; then
#   GIT_AUTHOR_NAME="$(git config user.name || true)"
# fi
# if [ -z "$GIT_AUTHOR_EMAIL" ]; then
#   GIT_AUTHOR_EMAIL="$(git config user.email || true)"
# fi

# # Default commit message
# if [ -z "$GIT_COMMIT_MSG" ]; then
#   GIT_COMMIT_MSG="Commit on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
# fi

cd "$GIT_SOURCE_DIR" || {
  echo "Failed to change directory to GIT_SOURCE_DIR: $GIT_SOURCE_DIR"
  exit 3
}

echo "Staging all changes..."
git add -A -f -- . ':(exclude)adminTasks/pxe/assets/**' ':(exclude).vscode/current/**'


# Ensure branch does not already exist
if git show-ref --verify --quiet refs/heads/"$GIT_BRANCH_NAME"; then
  echo "Branch '$GIT_BRANCH_NAME' already exists locally. Aborting to avoid overwriting." 
  exit 5
fi

echo "Creating and switching to branch '$GIT_BRANCH_NAME'..."
git checkout -b "$GIT_BRANCH_NAME"

# Commit with configured committer (local to this invocation)
echo "Committing with author: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"

#git commit -m "$GIT_COMMIT_MSG"
git -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" commit -m "$GIT_COMMIT_MSG"

# Push directly to provided remote URL
echo "Pushing branch '$GIT_BRANCH_NAME' to remote URL..."
if git push --set-upstream "$GIT_REMOTE_URL" HEAD:refs/heads/"$GIT_BRANCH_NAME"; then
  echo "Push successful. Branch $GIT_BRANCH_NAME is pushed and tracking $GIT_REMOTE_URL/$GIT_BRANCH_NAME"
  exit 0
else
  echo "Push failed." >&2
  exit 6
fi
