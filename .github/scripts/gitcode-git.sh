#!/usr/bin/env bash
# Shared by gitcode-sync.sh and gitcode-mirror.sh (sourced, not run): git
# access to the GitCode copy of this repository over HTTPS.
#
# Authenticates with the GitCode personal access token (the same one the
# release API uses): GitCode accepts it as the password for HTTPS git, with
# the token owner's login as the username.
#
# Required env: GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO

GITCODE_REMOTE="https://gitcode.com/${GITCODE_OWNER}/${GITCODE_REPO}.git"

# Look up the token owner's login, used as the HTTPS git username. Call once
# before git_gitcode.
gitcode_git_init() {
  local i
  for ((i = 1; i <= 4; i++)); do
    if GITCODE_USER=$(curl -sS --fail --connect-timeout 30 --max-time 60 -G \
      https://api.gitcode.com/api/v5/user \
      --data-urlencode "access_token=$GITCODE_TOKEN" | jq -er '.login'); then
      export GITCODE_USER GITCODE_TOKEN
      echo "Using GitCode account $GITCODE_USER for git"
      return 0
    fi
    (( i < 4 )) && sleep $((i * 15))
  done
  echo "::error::Could not look up the GitCode account for the GITEEPAT token"
  return 1
}

# git_gitcode <git args...>: run git against GitCode with the token supplied
# by a credential helper that reads the environment, so it never appears in a
# URL, the git config or the log.
git_gitcode() {
  git \
    -c credential.helper= \
    -c 'credential.helper=!f() { echo "username=$GITCODE_USER"; echo "password=$GITCODE_TOKEN"; }; f' \
    -c http.postBuffer=524288000 \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=300 \
    "$@"
}
