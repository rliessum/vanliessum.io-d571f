#!/usr/bin/env bash
# VPS pull updater for vanliessum.vanliessum.io.
# Root + Docker. Git runs as the checkout owner via runuser.
set -euo pipefail

ROOT="${VANLIESSUM_ROOT:-/opt/vanliessum}"
REMOTE="${VANLIESSUM_REMOTE:-origin}"
BRANCH="${VANLIESSUM_BRANCH:-main}"
LOCK="${VANLIESSUM_LOCK:-/run/vanliessum-update.lock}"
STATE_DIR="${VANLIESSUM_STATE_DIR:-/var/lib/vanliessum-update}"
VERSION_URL="${VANLIESSUM_VERSION_URL:-http://127.0.0.1:8798/version.json}"
HEALTH_TIMEOUT_SEC="${VANLIESSUM_HEALTH_TIMEOUT_SEC:-90}"
HEALTH_INTERVAL_SEC="${VANLIESSUM_HEALTH_INTERVAL_SEC:-2}"
DOCKER_UP_TIMEOUT_SEC="${VANLIESSUM_DOCKER_UP_TIMEOUT_SEC:-120}"
DOCKER_BUILD_TIMEOUT_SEC="${VANLIESSUM_DOCKER_BUILD_TIMEOUT_SEC:-300}"
DOCKER="${VANLIESSUM_DOCKER:-docker}"
CURL="${VANLIESSUM_CURL:-curl}"
GIT="${VANLIESSUM_GIT:-git}"

TARGET_SHA=""
HEAD_SHA=""
PREVIOUS_SHA=""

short_sha() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | cut -c1-7
}

normalize_sha() {
  local value
  value="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$value" =~ ^[0-9a-f]{7,40}$ ]]; then
    return 1
  fi
  printf '%s' "$value"
}

log() {
  local phase="$1"
  shift || true
  printf 'vanliessum-update sha=%s phase=%s %s\n' \
    "$(short_sha "${TARGET_SHA:-?}")" \
    "$phase" \
    "$*"
}

die() {
  log error "$*"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "reason=not-root"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK")" "$STATE_DIR"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log skip "reason=lock-held"
    exit 0
  fi
}

checkout_git_user() {
  if [[ -n "${VANLIESSUM_GIT_USER:-}" ]]; then
    printf '%s' "$VANLIESSUM_GIT_USER"
    return 0
  fi
  stat -c '%U' "$ROOT"
}

git_in_root() {
  local user
  user="$(checkout_git_user)"
  if [[ "$(id -un)" == "$user" ]]; then
    "$GIT" -C "$ROOT" "$@"
    return
  fi
  command -v runuser >/dev/null || die "reason=runuser-missing"
  runuser -u "$user" -- "$GIT" -C "$ROOT" "$@"
}

run_timed() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10s "$seconds" "$@"
    return
  fi
  "$@"
}

remote_sha() {
  local line sha
  line="$(git_in_root ls-remote --quiet "$REMOTE" "refs/heads/$BRANCH")"
  sha="$(printf '%s' "$line" | awk 'NF { print $1; exit }')"
  normalize_sha "$sha"
}

fetch_and_reset() {
  local sha="$1"
  git_in_root fetch --quiet "$REMOTE" "$BRANCH"
  if ! git_in_root cat-file -e "${sha}^{commit}" 2>/dev/null; then
    git_in_root fetch --quiet "$REMOTE" "$sha"
  fi
  git_in_root cat-file -e "${sha}^{commit}" || die "reason=missing-commit"
  git_in_root reset --hard "$sha"
}

tag_previous_image() {
  if "$DOCKER" image inspect vanliessum:latest >/dev/null 2>&1; then
    "$DOCKER" tag vanliessum:latest vanliessum:previous
  fi
}

restore_previous_image() {
  if "$DOCKER" image inspect vanliessum:previous >/dev/null 2>&1; then
    "$DOCKER" tag vanliessum:previous vanliessum:latest
    return 0
  fi
  return 1
}

version_card_ok() {
  local card="$1"
  local expected_short="$2"
  printf '%s' "$card" | grep -q "\"webSha\":\"${expected_short}\""
}

wait_healthy() {
  local expected_short="$1"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SEC))
  local card
  while (( SECONDS < deadline )); do
    card="$("$CURL" -fsS --max-time 5 "$VERSION_URL" 2>/dev/null || true)"
    if version_card_ok "$card" "$expected_short"; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL_SEC"
  done
  return 1
}

write_state() {
  local deployed="$1"
  local previous="$2"
  printf '%s\n' "$deployed" >"$STATE_DIR/deployed-sha"
  printf '%s\n' "$previous" >"$STATE_DIR/previous-sha"
}

rollback() {
  local previous="$1"
  log rollback "to=$(short_sha "$previous")"
  git_in_root reset --hard "$previous"
  export GIT_SHA="$previous"
  if restore_previous_image; then
    log rollback "mode=retag"
  else
    log rollback "mode=rebuild reason=no-previous-image"
    run_timed "$DOCKER_BUILD_TIMEOUT_SEC" "$DOCKER" compose --project-directory "$ROOT" build || return 1
  fi
  run_timed "$DOCKER_UP_TIMEOUT_SEC" "$DOCKER" compose --project-directory "$ROOT" up -d || return 1
  if wait_healthy "$(short_sha "$previous")"; then
    write_state "$previous" "$previous"
    log rollback "result=healthy"
    return 0
  fi
  log rollback "result=unhealthy"
  return 1
}

deploy_build_and_up() {
  local expected
  expected="$(short_sha "$TARGET_SHA")"
  tag_previous_image
  export GIT_SHA="$TARGET_SHA"

  if ! run_timed "$DOCKER_BUILD_TIMEOUT_SEC" "$DOCKER" compose --project-directory "$ROOT" build; then
    git_in_root reset --hard "$PREVIOUS_SHA"
    die "reason=build-failed"
  fi
  log build "mode=compose sha=$expected"

  if ! run_timed "$DOCKER_UP_TIMEOUT_SEC" "$DOCKER" compose --project-directory "$ROOT" up -d \
    || ! wait_healthy "$expected"; then
    rollback "$PREVIOUS_SHA" || die "reason=rollback-failed"
    die "reason=health-failed rolled_back=$(short_sha "$PREVIOUS_SHA")"
  fi
  log swap "result=healthy"
}

main() {
  require_root
  acquire_lock

  [[ -d "$ROOT/.git" ]] || die "reason=not-a-checkout path=$ROOT"
  [[ -f "$ROOT/docker-compose.yml" ]] || die "reason=missing-compose"

  HEAD_SHA="$(normalize_sha "$(git_in_root rev-parse HEAD)")" || die "reason=head-unreadable"
  TARGET_SHA="$(remote_sha)" || die "reason=ls-remote-failed"
  log detect "target=$(short_sha "$TARGET_SHA") head=$(short_sha "$HEAD_SHA")"

  if [[ "$TARGET_SHA" == "$HEAD_SHA" || "$(short_sha "$TARGET_SHA")" == "$(short_sha "$HEAD_SHA")" ]]; then
    log skip "reason=unchanged"
    exit 0
  fi

  PREVIOUS_SHA="$HEAD_SHA"
  printf '%s\n' "$PREVIOUS_SHA" >"$STATE_DIR/previous-sha"

  fetch_and_reset "$TARGET_SHA"
  deploy_build_and_up
  write_state "$TARGET_SHA" "$PREVIOUS_SHA"
  log "done" "deployed=$(short_sha "$TARGET_SHA") previous=$(short_sha "$PREVIOUS_SHA")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
