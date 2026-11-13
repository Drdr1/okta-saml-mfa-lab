# Shared helpers for the Okta SAML + MFA lab scripts.
# shellcheck shell=bash

set -euo pipefail
set +H # stop bash treating "!" in values as history expansion

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
STATE_FILE="$OUT_DIR/state.env"
mkdir -p "$OUT_DIR"

# Load optional .env (never committed)
if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$ROOT_DIR/.env"; set +a
fi

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

: "${OKTA_ORG:?Set OKTA_ORG, e.g. https://integrator-1234567.okta.com (no -admin)}"
OKTA_ORG="${OKTA_ORG%/}"
if [[ "$OKTA_ORG" == *"-admin."* ]]; then
  echo "OKTA_ORG must be the org URL, not the -admin console URL." >&2
  exit 1
fi

if [[ -z "${OKTA_TOKEN:-}" ]]; then
  read -rsp "Okta API token (input hidden): " OKTA_TOKEN
  echo
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

uri() { jq -rn --arg s "$1" '$s|@uri'; }

# api METHOD PATH [extra curl args...]  -> prints response body
api() {
  local method=$1 path=$2
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: SSWS $OKTA_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$OKTA_ORG$path" "$@"
}

# api_ok METHOD PATH [args...] -> like api, but exits on an Okta error object
api_ok() {
  local body
  body="$(api "$@")"
  if jq -e 'type=="object" and has("errorCode")' >/dev/null 2>&1 <<<"$body"; then
    echo "$body" | jq '{errorCode, errorSummary, errorCauses}' >&2
    die "Okta API call failed: $1 $2"
  fi
  printf '%s' "$body"
}

# api_status METHOD PATH [args...] -> prints only the HTTP status code
api_status() {
  local method=$1 path=$2
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
    -H "Authorization: SSWS $OKTA_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$OKTA_ORG$path" "$@"
}

save_state() { # save_state KEY VALUE
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  echo "$1=$2" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "No $STATE_FILE yet. Run ./setup.sh first."
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}
