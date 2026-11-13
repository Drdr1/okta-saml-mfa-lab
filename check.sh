#!/usr/bin/env bash
# Verifies the lab: who can see the app, and what the System Log recorded.
source "$(dirname "$0")/lib/common.sh"
load_state

SINCE_MINUTES="${SINCE_MINUTES:-60}"
since="$(date -u -d "-${SINCE_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${SINCE_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)"

log "App visibility (expected: Sara sees it, Omar does not)"
for who in SARA OMAR; do
  id_var="${who}_ID"; login_var="${who}_LOGIN"
  apps="$(api_ok GET "/api/v1/users/${!id_var}/appLinks" | jq -r '[.[].label] | join(", ")')"
  printf '  %-36s %s\n' "${!login_var}" "${apps:-<no apps>}"
done

log "Policy on the app"
api_ok GET "/api/v1/apps/$APP_ID" \
  | jq -r '"  app: \(.label) [\(.status)]  sign-in policy: \(._links.accessPolicy.href // "none" | split("/") | last)"'

log "System Log for the app, last ${SINCE_MINUTES} min (challenge -> MFA -> SSO)"
api_ok GET "/api/v1/logs?since=$(uri "$since")&limit=200&filter=$(uri "target.id eq \"$APP_ID\"")" \
  | jq -r 'sort_by(.published)[] | "  \(.published[11:19])  \(.eventType | .[0:38] | . + (" " * (38 - length)))  \(.outcome.result | . + (" " * (10 - length)))  \(.actor.alternateId)"'

log "Omar: denied or failed events (open the SP login URL as Omar to create one)"
api_ok GET "/api/v1/logs?since=$(uri "$since")&limit=100&filter=$(uri "actor.id eq \"$OMAR_ID\" and (outcome.result eq \"DENY\" or outcome.result eq \"FAILURE\")")" \
  | jq -r 'if length == 0 then "  (none yet: open the SP login URL as Omar to generate one)" else
      (sort_by(.published)[] | "  \(.published[11:19])  \(.eventType)  \(.outcome.result)  \(.outcome.reason // "")") end'
