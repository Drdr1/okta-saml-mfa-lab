#!/usr/bin/env bash
# Removes everything setup.sh created (IDs come from out/state.env).
source "$(dirname "$0")/lib/common.sh"
load_state

echo "This deletes the demo app, policy, group and both test users from:"
echo "  $OKTA_ORG"
read -rp "Type DELETE to continue: " answer
[[ "$answer" == "DELETE" ]] || { echo "Cancelled."; exit 0; }

log "App"
if [[ -n "${APP_ID:-}" ]]; then
  api_status POST "/api/v1/apps/$APP_ID/lifecycle/deactivate" >/dev/null
  code="$(api_status DELETE "/api/v1/apps/$APP_ID")"
  [[ "$code" =~ ^(204|404)$ ]] && ok "App removed" || warn "App delete returned HTTP $code"
fi

log "Sign-in policy"
if [[ -n "${POLICY_ID:-}" ]]; then
  code="$(api_status DELETE "/api/v1/policies/$POLICY_ID")"
  [[ "$code" =~ ^(204|404)$ ]] && ok "Policy removed" || warn "Policy delete returned HTTP $code"
fi

log "Group"
if [[ -n "${GROUP_ID:-}" ]]; then
  code="$(api_status DELETE "/api/v1/groups/$GROUP_ID")"
  [[ "$code" =~ ^(204|404)$ ]] && ok "Group removed" || warn "Group delete returned HTTP $code"
fi

log "Users"
for id in "${SARA_ID:-}" "${OMAR_ID:-}"; do
  [[ -n "$id" ]] || continue
  api_status DELETE "/api/v1/users/$id" >/dev/null   # 1st call deactivates
  code="$(api_status DELETE "/api/v1/users/$id")"     # 2nd call deletes
  [[ "$code" =~ ^(204|404)$ ]] && ok "User $id removed" || warn "User delete returned HTTP $code"
done

rm -f "$STATE_FILE"
ok "Done. Remember to revoke the API token: Security > API > Tokens."
