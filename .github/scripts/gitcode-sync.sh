#!/usr/bin/env bash
# Mirror this repository's branches and tags to GitCode, and work out which
# releases have to be (re)made there.
#
# A GitHub release is mirrored when GitCode has no release for its tag, or
# when the files attached to the two differ: a file is missing or extra on
# GitCode, or its sha256 is not the same. Both sides report the sha256 of
# each file, so nothing is downloaded to compare them. Releases whose files
# are all identical are left alone, as are drafts and releases older than
# the newest 15 prereleases and 4 full releases (GitCode keeps no more).
#
# Branches and tags are force-updated to match GitHub; refs that exist only
# on GitCode are left alone (nothing is deleted). A rejected branch (for
# example a protected branch on GitCode) is reported as a warning.
#
# Run from a full clone (actions/checkout with fetch-depth: 0).
#
# Required env: GH_TOKEN, GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO,
#               GITHUB_REPOSITORY
# Optional env: GITCODE_MAX_PRERELEASES, GITCODE_MAX_RELEASES  as in
#                              gitcode-mirror.sh (0 = no limit)
#               EXPLICIT_TAG   mirror this tag's release even if its files
#                              are identical
#               GITHUB_OUTPUT  receives tags=<JSON array of tags to mirror>
set -euo pipefail

# shellcheck source=.github/scripts/gitcode-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/gitcode-lib.sh"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

gitcode_git_init

# --- Push branches and tags -----------------------------------------------
# Make sure every branch and tag from GitHub is present locally.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  retry 3 git fetch --unshallow --tags --force origin
fi
retry 3 git fetch --prune --tags --force origin '+refs/heads/*:refs/remotes/origin/*'
# origin/HEAD is a pointer, not a branch; keep it from becoming refs/heads/HEAD.
git remote set-head origin --delete 2>/dev/null || true

echo "Pushing tags to $GITCODE_REMOTE"
if ! retry 3 git_gitcode push --force "$GITCODE_REMOTE" 'refs/tags/*:refs/tags/*'; then
  echo "::error::Could not push tags to GitCode. Check that the GITEEPAT token has write access to $GITCODE_OWNER/$GITCODE_REPO, and that the repository is not a read-only pull mirror."
  exit 1
fi

echo "Pushing branches to $GITCODE_REMOTE"
if ! retry 3 git_gitcode push --force "$GITCODE_REMOTE" 'refs/remotes/origin/*:refs/heads/*'; then
  echo "::warning::Some branches could not be pushed to GitCode (protected branch?); tags were synced."
fi

# --- Compare the releases' files ------------------------------------------
# gitcode-mirror.sh keeps at most this many prereleases and full releases on
# GitCode, deleting the oldest. Only the newest that many on GitHub are
# compared, or a pruned release would be mirrored again on every run.
MAX_PRERELEASES=${GITCODE_MAX_PRERELEASES:-15}
MAX_RELEASES=${GITCODE_MAX_RELEASES:-4}

# Kept in files rather than variables: the GitHub list is too large to pass
# to jq on its command line.
gh_releases() {
  gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" >"$workdir/github.json"
}
if ! retry 3 gh_releases; then
  echo "::error::Could not list the releases on GitHub"
  exit 1
fi
if ! gitcode_releases >"$workdir/gitcode.json"; then
  echo "::error::Could not list the releases on GitCode"
  exit 1
fi

# Prints "<tag>\t<reason>" for every release that has to be mirrored.
# $github holds one array per page of the GitHub list; $gitcode holds the one
# GitCode array. GitCode also lists generated source archives as assets (type
# "source"); only uploaded files count. Where either side reports no digest
# for a file, its size is compared instead.
needed=$(jq -rn --slurpfile github "$workdir/github.json" \
  --argjson maxpre "$MAX_PRERELEASES" --argjson maxrel "$MAX_RELEASES" \
  --slurpfile gitcode "$workdir/gitcode.json" '
  def files:
    map({key: .name,
         value: {digest: ((.digest // "") | ascii_downcase), size: .size}})
    | from_entries;
  def newest($n):
    if $n > 0 then sort_by(.created_at) | reverse | .[:$n] else . end;
  def same_file($a; $b):
    if $a.digest != "" and $b.digest != ""
    then $a.digest == $b.digest
    else $a.size == $b.size end;
  ($gitcode[0]
    | map({key: .tag_name,
           value: ([.assets[]? | select(.type != "source")] | files)})
    | from_entries) as $mirror
  | ($github | add // [] | map(select(.draft | not))) as $all
  | ( ($all | map(select(.prerelease)) | newest($maxpre))
    + ($all | map(select(.prerelease | not)) | newest($maxrel)) )[]
  | .tag_name as $tag
  | (.assets | files) as $want
  | if ($mirror | has($tag) | not) then
      "\($tag)\tno release on GitCode"
    else
      $mirror[$tag] as $have
      | [ ($want | keys[] | select(. as $n | $have | has($n) | not)
            | "\(.) is missing on GitCode"),
          ($have | keys[] | select(. as $n | $want | has($n) | not)
            | "\(.) is not on GitHub"),
          ($want | keys[] | select(. as $n | $have | has($n))
            | select(. as $n | same_file($want[$n]; $have[$n]) | not)
            | "\(.) differs") ] as $why
      | if ($why | length) > 0 then "\($tag)\t\($why | join(", "))" else empty end
    end')

if [ -z "$needed" ]; then
  echo "Every release on GitHub has identical files on GitCode"
else
  echo "Releases whose files differ:"
  sed 's/^/  /; s/\t/: /' <<<"$needed"
fi

# --- Decide which releases to mirror --------------------------------------
if [ -n "${EXPLICIT_TAG:-}" ] && ! jq -e --arg t "$EXPLICIT_TAG" -n \
  --slurpfile github "$workdir/github.json" \
  'any(($github | add // [])[]; .tag_name == $t and (.draft | not))' >/dev/null; then
  echo "::error::GitHub has no published release for tag $EXPLICIT_TAG"
  exit 1
fi

release_tags=$(
  {
    [ -n "$needed" ] && cut -f1 <<<"$needed" || true
    [ -n "${EXPLICIT_TAG:-}" ] && printf '%s\n' "$EXPLICIT_TAG" || true
  } | sort -u
)
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
