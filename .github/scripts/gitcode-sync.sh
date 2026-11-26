#!/usr/bin/env bash
# Mirror this repository's branches and tags to GitCode, and work out which
# releases have to be (re)made there. Runs on every push.
#
# A release is needed for a tag when the tag is new on GitCode or points
# somewhere else there than on GitHub, and GitHub has a release for it. When
# every tag is at the same point on both sides, no release is needed.
#
# Tags that need a release are NOT pushed here. gitcode-mirror.sh pushes each
# one itself, right before it makes the release. Until then the tag still
# differs on GitCode, so a mirror that is cancelled or fails is picked up
# again by the next push instead of being forgotten.
#
# Everything else is force-updated to match GitHub; refs that exist only on
# GitCode are left alone (nothing is deleted). A rejected branch (for example
# a protected branch on GitCode) is reported as a warning.
#
# Run from a full clone (actions/checkout with fetch-depth: 0).
#
# Required env: GH_TOKEN, GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO,
#               GITHUB_REPOSITORY
# Optional env: EXPLICIT_TAG   always mirror this tag's release (release
#                              events and manual runs)
#               GITHUB_OUTPUT  receives tags=<JSON array of tags to mirror>
set -euo pipefail

# shellcheck source=.github/scripts/gitcode-git.sh
source "$(dirname "${BASH_SOURCE[0]}")/gitcode-git.sh"

# retry <attempts> <command...>, waiting 15 s, 30 s, 45 s... between tries.
retry() {
  local n=$1 i
  shift
  for ((i = 1; ; i++)); do
    "$@" && return 0
    (( i >= n )) && return 1
    echo "'$1' failed; retrying in $((i * 15))s ($i/$n)" >&2
    sleep $((i * 15))
  done
}

# changed_tags <github refs> <gitcode refs>: print the tags that are missing
# from the GitCode list or point somewhere else there. Each list has one
# "<sha> refs/tags/<name>" per line (space or tab separated).
changed_tags() {
  awk '
    FNR == 1 { file++ }
    NF < 2 { next }
    file == 1 { gitcode[$2] = $1; next }
    gitcode[$2] != $1 { sub("^refs/tags/", "", $2); print $2 }
  ' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# Self-test of the comparison, for use without any network access.
if [ "${1:-}" = "--self-test" ]; then
  got=$(changed_tags \
    $'aaa refs/tags/same\nbbb refs/tags/moved\nccc refs/tags/new' \
    $'aaa\trefs/tags/same\nxxx\trefs/tags/moved\nddd\trefs/tags/only-gitcode')
  [ "$got" = $'moved\nnew' ] || { echo "FAIL moved/new: $got"; exit 1; }
  [ -z "$(changed_tags $'aaa refs/tags/a' $'aaa\trefs/tags/a')" ] || { echo "FAIL identical"; exit 1; }
  [ "$(changed_tags $'aaa refs/tags/a' '')" = a ] || { echo "FAIL empty GitCode"; exit 1; }
  [ -z "$(changed_tags '' '')" ] || { echo "FAIL no tags"; exit 1; }
  echo "self-test ok"
  exit 0
fi

gitcode_git_init

# Make sure every branch and tag from GitHub is present locally.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  retry 3 git fetch --unshallow --tags --force origin
fi
retry 3 git fetch --prune --tags --force origin '+refs/heads/*:refs/remotes/origin/*'
# origin/HEAD is a pointer, not a branch; keep it from becoming refs/heads/HEAD.
git remote set-head origin --delete 2>/dev/null || true

# --- Compare tags ---------------------------------------------------------
github_tags=$(git for-each-ref --format='%(objectname) %(refname)' refs/tags)
if ! gitcode_tags=$(retry 3 git_gitcode ls-remote --refs --tags "$GITCODE_REMOTE"); then
  echo "::error::Could not list the tags on GitCode. Check that the GITEEPAT token can read $GITCODE_OWNER/$GITCODE_REPO."
  exit 1
fi
changed=$(changed_tags "$github_tags" "$gitcode_tags")
if [ -z "$changed" ]; then
  echo "All tags are at the same point on GitHub and GitCode"
else
  echo "Tags that are new or have moved:"
  sed 's/^/  /' <<<"$changed"
fi

# --- Decide which releases to mirror --------------------------------------
gh_release_tags() {
  gh release list -R "$GITHUB_REPOSITORY" --limit 1000 \
    --json tagName,isDraft -q '.[] | select(.isDraft | not) | .tagName'
}
if ! released=$(retry 3 gh_release_tags); then
  echo "::error::Could not list the releases on GitHub"
  exit 1
fi

# Changed tags that have a GitHub release, plus the explicitly named tag.
release_tags=$(
  {
    [ -n "$changed" ] && [ -n "$released" ] \
      && grep -Fxf <(printf '%s\n' "$released") <<<"$changed" || true
    [ -n "${EXPLICIT_TAG:-}" ] && printf '%s\n' "$EXPLICIT_TAG" || true
  } | sort -u
)
if [ -n "${EXPLICIT_TAG:-}" ] && ! grep -Fxq -e "$EXPLICIT_TAG" <<<"$released"; then
  echo "::error::GitHub has no published release for tag $EXPLICIT_TAG"
  exit 1
fi

tags_json=$(jq -Rnc '[inputs | select(length > 0)]' <<<"$release_tags")
if [ -z "$release_tags" ]; then
  echo "No release needs to be mirrored"
else
  echo "Releases to mirror:"
  sed 's/^/  /' <<<"$release_tags"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tags=$tags_json" >>"$GITHUB_OUTPUT"
fi

# --- Push branches --------------------------------------------------------
echo "Pushing branches to $GITCODE_REMOTE"
if ! retry 3 git_gitcode push --force "$GITCODE_REMOTE" 'refs/remotes/origin/*:refs/heads/*'; then
  echo "::warning::Some branches could not be pushed to GitCode (protected branch?)."
fi

# --- Push the changed tags that get no release ----------------------------
refspecs=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  grep -Fxq -e "$t" <<<"$release_tags" && continue
  refspecs+=("refs/tags/$t:refs/tags/$t")
done <<<"$changed"
if (( ${#refspecs[@]} > 0 )); then
  echo "Pushing ${#refspecs[@]} tag(s) without a release to $GITCODE_REMOTE"
  if ! retry 3 git_gitcode push --force "$GITCODE_REMOTE" "${refspecs[@]}"; then
    echo "::error::Could not push tags to GitCode. Check that the GITEEPAT token has write access to $GITCODE_OWNER/$GITCODE_REPO, and that the repository is not a read-only pull mirror."
    exit 1
  fi
fi
