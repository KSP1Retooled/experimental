#!/usr/bin/env bash
# Shared by gitcode-sync.sh and gitcode-mirror.sh (sourced, not run): access
# to the GitCode copy of this repository, through its API and through git.
#
# GitCode API reference: https://docs.gitcode.com/en/docs/apis/
#   - Request bodies are JSON; the token goes in the access_token query param.
#
# Git authenticates with the same personal access token: GitCode accepts it
# as the password for HTTPS git, with the token owner's login as the username.
#
# Required env: GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO
# Optional env: API_ATTEMPTS  tries per API call (default 8, ~5 min)

API="https://api.gitcode.com/api/v5/repos/${GITCODE_OWNER}/${GITCODE_REPO}"
GITCODE_REMOTE="https://gitcode.com/${GITCODE_OWNER}/${GITCODE_REPO}.git"
API_ATTEMPTS=${API_ATTEMPTS:-8}

# Seconds to wait before retry number $1: 15, 30, 45, then 60 each time.
backoff() {
  local s=$(( $1 * 15 ))
  echo $(( s > 60 ? 60 : s ))
}

# retry <attempts> <command...>: re-run a command until it succeeds.
retry() {
  local n=$1 i wait_s
  shift
  for ((i = 1; ; i++)); do
    "$@" && return 0
    (( i >= n )) && return 1
    wait_s=$(backoff "$i")
    echo "'$1' failed; retrying in ${wait_s}s ($i/$n)" >&2
    sleep "$wait_s"
  done
}

# api <METHOD> <path> [curl args...]
# Calls the GitCode API, retrying transient failures (network errors,
# timeouts, HTTP 408/429/5xx). Prints the response body. Returns 0 on 2xx,
# 3 on 404, 4 on any other 4xx, 1 when retries ran out.
api() {
  local method=$1 path=$2 attempt out code body
  shift 2
  for ((attempt = 1; ; attempt++)); do
    out=$(curl -sS -X "$method" "$API$path" \
      --url-query "access_token=$GITCODE_TOKEN" \
      --connect-timeout 30 --max-time 300 \
      -w '\n%{http_code}' "$@") || true
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    case $code in
      2??) printf '%s' "$body"; return 0 ;;
      404) printf '%s' "$body"; return 3 ;;
      408 | 429 | 5?? | 000) ;;   # transient: retry
      *) printf '%s' "$body"; return 4 ;;
    esac
    if (( attempt >= API_ATTEMPTS )); then
      echo "::warning::GitCode $method $path failed after $attempt attempts (HTTP $code): ${body:0:300}" >&2
      printf '%s' "$body"
      return 1
    fi
    local wait_s
    wait_s=$(backoff "$attempt")
    echo "GitCode $method $path: HTTP $code; retrying in ${wait_s}s ($attempt/$API_ATTEMPTS)" >&2
    sleep "$wait_s"
  done
}

# Print every GitCode release as one JSON array, or fail. Each release lists
# its assets; uploaded files have type "attach", a size and a sha256 digest.
gitcode_releases() {
  local page out all='[]'
  for ((page = 1; page <= 50; page++)); do
    out=$(api GET /releases --url-query "per_page=100" --url-query "page=$page") || return 1
    jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || return 1
    all=$(jq -c --argjson a "$all" '$a + . | unique_by(.tag_name)' <<<"$out")
    if [ "$(jq length <<<"$out")" -lt 100 ]; then break; fi
  done
  printf '%s' "$all"
}

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
