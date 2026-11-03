#!/usr/bin/env bash
# =============================================================
# deploy.sh: commit, push, and wait until the change is LIVE.
#
# Usage:
#   ./deploy.sh                      # commit all changes with a default message
#   ./deploy.sh "Update schedule"    # commit with your own message
#   ./deploy.sh --redeploy           # nothing changed, but force a fresh deploy
#
# How it works:
#   1. Sanity-checks index.html
#   2. Commits any changes and pushes to main
#   3. GitHub Actions (.github/workflows/deploy.yml) builds + publishes to Pages
#   4. This script polls the live site until it sees the new commit's build stamp
# =============================================================
set -euo pipefail

BRANCH="main"
TIMEOUT_SECONDS=300   # how long to wait for the site to go live
POLL_SECONDS=10

cd "$(dirname "$0")"

# ---------- pretty output ----------
bold=$'\033[1m'; blue=$'\033[34m'; green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; reset=$'\033[0m'
step() { echo "${blue}${bold}▸${reset} $*"; }
ok()   { echo "${green}${bold}✓${reset} $*"; }
warn() { echo "${yellow}${bold}!${reset} $*"; }
die()  { echo "${red}${bold}✗${reset} $*" >&2; exit 1; }

# ---------- args ----------
REDEPLOY=false
MSG=""
for arg in "$@"; do
  case "$arg" in
    --redeploy) REDEPLOY=true ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) MSG="$arg" ;;
  esac
done
[[ -z "$MSG" ]] && MSG="Deploy: $(date '+%Y-%m-%d %H:%M')"

# ---------- figure out the live URL from the git remote ----------
REMOTE_URL="$(git remote get-url origin 2>/dev/null)" || die "No 'origin' remote found."
# handles https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
OWNER_REPO="$(echo "$REMOTE_URL" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"
OWNER_LC="$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')"
if [[ "$(echo "$REPO" | tr '[:upper:]' '[:lower:]')" == "${OWNER_LC}.github.io" ]]; then
  SITE_URL="https://${OWNER_LC}.github.io/"
else
  SITE_URL="https://${OWNER_LC}.github.io/${REPO}/"
fi
ACTIONS_URL="https://github.com/${OWNER}/${REPO}/actions"

# ---------- 1. sanity checks ("build") ----------
step "Checking the site…"
[[ -f index.html ]] || die "index.html not found."
grep -q '<!DOCTYPE html>' index.html || die "index.html is missing <!DOCTYPE html>."
grep -q 'const SIGNUP_URL = "https://' index.html || die "SIGNUP_URL looks missing or empty in index.html."
grep -q 'const EVENT_START = "' index.html || die "EVENT_START looks missing in index.html."
[[ -f .github/workflows/deploy.yml ]] || die "Missing .github/workflows/deploy.yml."
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] || die "You're on '$CURRENT_BRANCH'. Switch to '$BRANCH' first (git checkout $BRANCH)."
ok "Looks good."

# ---------- 2. commit ----------
if [[ -n "$(git status --porcelain)" ]]; then
  step "Committing changes…"
  git add -A
  git commit -q -m "$MSG"
  ok "Committed: $MSG"
elif $REDEPLOY; then
  step "No changes. Creating an empty commit to force a redeploy…"
  git commit -q --allow-empty -m "Redeploy: $(date '+%Y-%m-%d %H:%M')"
fi

# ---------- 3. push ----------
git fetch -q origin "$BRANCH"
AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD")"
BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH")"

if [[ "$BEHIND" -gt 0 ]]; then
  step "Remote has $BEHIND new commit(s). Rebasing on top of them…"
  git pull -q --rebase origin "$BRANCH" || die "Rebase hit a conflict. Fix it, then run ./deploy.sh again."
  AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD")"
fi

if [[ "$AHEAD" -eq 0 ]]; then
  warn "Nothing new to deploy. Use ./deploy.sh --redeploy to force one."
  echo "   Live site: $SITE_URL"
  exit 0
fi

step "Pushing $AHEAD commit(s) to $BRANCH…"
git push -q origin "$BRANCH"
SHA="$(git rev-parse HEAD)"
ok "Pushed ${SHA:0:7}."

# ---------- 4. wait for it to go live ----------
step "Waiting for GitHub Pages to publish (usually 30–90s)…"
echo "   Watch the build: $ACTIONS_URL"
START=$(date +%s)
while true; do
  # cache-busting query string so we don't get a stale CDN copy
  if curl -fsSL "${SITE_URL}?v=${SHA}&t=$(date +%s)" 2>/dev/null | grep -q "content=\"${SHA}\""; then
    echo
    ok "${bold}Live!${reset} ${SITE_URL}"
    if command -v open >/dev/null 2>&1; then open "$SITE_URL"; fi
    exit 0
  fi
  if (( $(date +%s) - START > TIMEOUT_SECONDS )); then
    echo
    warn "Not live after ${TIMEOUT_SECONDS}s. Check the run for errors: $ACTIONS_URL"
    warn "If it says Pages isn't enabled: repo Settings → Pages → Source: GitHub Actions."
    exit 1
  fi
  printf '.'
  sleep "$POLL_SECONDS"
done
