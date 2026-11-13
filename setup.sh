#!/usr/bin/env bash
# Builds the lab: two users, one access group, a SAML 2.0 app, and an
# app sign-in policy that requires Okta Verify on every sign-in.
# Safe to re-run: existing objects (matched by name) are reused.
source "$(dirname "$0")/lib/common.sh"

: "${EMAIL_BASE:?Set EMAIL_BASE to an inbox you own, e.g. you@gmail.com (users get +sara / +omar aliases)}"
GROUP_NAME="${GROUP_NAME:-App - Demo}"
APP_LABEL="${APP_LABEL:-SAML Test App (Demo)}"
POLICY_NAME="${POLICY_NAME:-Demo - MFA required}"
RULE_NAME="${RULE_NAME:-Require Okta Verify}"
SP_METADATA_URL="${SP_METADATA_URL:-https://sptest.iamshowcase.com/testsp_metadata.xml}"

if [[ -z "${DEMO_PASSWORD:-}" ]]; then
  DEMO_PASSWORD="Lab-$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)#9"
fi

alias_for() { # alias_for slug -> name+slug@domain
  echo "${EMAIL_BASE%@*}+$1@${EMAIL_BASE#*@}"
}

# ---------------------------------------------------------------- 0. token
log "Checking API token"
me="$(api_ok GET /api/v1/users/me | jq -r .profile.login)"
ok "Authenticated as $me on $OKTA_ORG"

# ---------------------------------------------------------------- 1. users
ensure_user() { # ensure_user First slug -> prints user id
  local first=$1 slug=$2 login id body
  login="$(alias_for "$slug")"
  id="$(api GET "/api/v1/users/$(uri "$login")" | jq -r '.id // empty')"
  if [[ -n "$id" ]]; then
    warn "User $login already exists ($id), reusing" >&2
  else
    body="$(jq -n --arg f "$first" --arg l "$login" --arg p "$DEMO_PASSWORD" '{
      profile: {firstName: $f, lastName: "Test", email: $l, login: $l},
      credentials: {password: {value: $p}} }')"
    id="$(api_ok POST "/api/v1/users?activate=true" -d "$body" | jq -r .id)"
    ok "Created $login ($id)" >&2
  fi
  echo "$id"
}

log "Users"
SARA_ID="$(ensure_user Sara sara)"
OMAR_ID="$(ensure_user Omar omar)"
save_state SARA_ID "$SARA_ID"; save_state OMAR_ID "$OMAR_ID"
save_state SARA_LOGIN "$(alias_for sara)"; save_state OMAR_LOGIN "$(alias_for omar)"
save_state DEMO_PASSWORD "$DEMO_PASSWORD"

# ---------------------------------------------------------------- 2. group
log "Group: $GROUP_NAME"
GROUP_ID="$(api_ok GET "/api/v1/groups?q=$(uri "$GROUP_NAME")" \
  | jq -r --arg n "$GROUP_NAME" '[.[] | select(.profile.name==$n)][0].id // empty')"
if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID="$(api_ok POST /api/v1/groups \
    -d "$(jq -n --arg n "$GROUP_NAME" '{profile: {name: $n, description: "Access to the demo SAML app"}}')" \
    | jq -r .id)"
  ok "Created group ($GROUP_ID)"
else
  warn "Group exists ($GROUP_ID), reusing"
fi
save_state GROUP_ID "$GROUP_ID"

code="$(api_status PUT "/api/v1/groups/$GROUP_ID/users/$SARA_ID")"
[[ "$code" == 204 ]] || die "Adding Sara to the group returned HTTP $code"
ok "Sara is a member; Omar is deliberately not"

# ---------------------------------------------------------------- 3. Okta Verify
log "Okta Verify"
ov_status="$(api_ok GET /api/v1/authenticators | jq -r '.[] | select(.key=="okta_verify") | .status')"
if [[ "$ov_status" != "ACTIVE" ]]; then
  ov_id="$(api_ok GET /api/v1/authenticators | jq -r '.[] | select(.key=="okta_verify") | .id')"
  api_ok POST "/api/v1/authenticators/$ov_id/lifecycle/activate" >/dev/null
  ok "Activated Okta Verify"
else
  ok "Okta Verify already active"
fi

enroll_id="$(api_ok GET "/api/v1/policies?type=MFA_ENROLL" | jq -r '[.[] | select(.system==true)][0].id')"
api_ok GET "/api/v1/policies/$enroll_id" \
  | jq '(.settings.authenticators[]? | select(.key=="okta_verify") | .enroll.self) |= (if . == "NOT_ALLOWED" then "OPTIONAL" else . end)' \
  > "$OUT_DIR/enroll-policy.json"
self="$(api_ok PUT "/api/v1/policies/$enroll_id" -d @"$OUT_DIR/enroll-policy.json" \
  | jq -r '.settings.authenticators[]? | select(.key=="okta_verify") | .enroll.self')"
ok "Default enrollment policy: Okta Verify is ${self:-unchanged}"

# ---------------------------------------------------------------- 4. SAML app
log "Service provider metadata"
curl -fsS "$SP_METADATA_URL" -o "$OUT_DIR/sp-metadata.xml"
SP_ENTITY="$(grep -o 'entityID="[^"]*"' "$OUT_DIR/sp-metadata.xml" | head -1 | cut -d'"' -f2)"
SP_ACS="$(grep -o '<[^>]*AssertionConsumerService[^>]*HTTP-POST[^>]*>' "$OUT_DIR/sp-metadata.xml" \
  | grep -o 'Location="[^"]*"' | head -1 | cut -d'"' -f2)"
[[ -n "$SP_ENTITY" && -n "$SP_ACS" ]] || die "Could not read entityID / ACS from $SP_METADATA_URL"
ok "Entity ID: $SP_ENTITY"
ok "ACS URL:   $SP_ACS"

log "SAML app: $APP_LABEL"
APP_ID="$(api_ok GET "/api/v1/apps?q=$(uri "$APP_LABEL")&limit=50" \
  | jq -r --arg l "$APP_LABEL" '[.[] | select(.label==$l and .status=="ACTIVE")][0].id // empty')"
if [[ -z "$APP_ID" ]]; then
  app_body="$(jq -n --arg label "$APP_LABEL" --arg acs "$SP_ACS" --arg aud "$SP_ENTITY" '{
    label: $label, signOnMode: "SAML_2_0",
    visibility: {autoSubmitToolbar: false, hide: {iOS: false, web: false}},
    settings: { signOn: {
      ssoAcsUrl: $acs, recipient: $acs, destination: $acs, audience: $aud,
      subjectNameIdTemplate: "${user.email}",
      subjectNameIdFormat: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
      responseSigned: true, assertionSigned: true,
      signatureAlgorithm: "RSA_SHA256", digestAlgorithm: "SHA256",
      honorForceAuthn: true,
      authnContextClassRef: "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport",
      attributeStatements: [
        {type: "EXPRESSION", name: "email",     namespace: "urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified", values: ["user.email"]},
        {type: "EXPRESSION", name: "firstname", namespace: "urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified", values: ["user.firstName"]},
        {type: "EXPRESSION", name: "lastname",  namespace: "urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified", values: ["user.lastName"]}
      ] } } }')"
  APP_ID="$(api_ok POST /api/v1/apps -d "$app_body" | jq -r .id)"
  ok "Created app ($APP_ID)"
else
  warn "App exists ($APP_ID), reusing"
fi
save_state APP_ID "$APP_ID"

curl -sS -H "Authorization: SSWS $OKTA_TOKEN" -H "Accept: application/xml" \
  "$OKTA_ORG/api/v1/apps/$APP_ID/sso/saml/metadata" -o "$OUT_DIR/okta-idp-metadata.xml"
grep -q 'EntityDescriptor' "$OUT_DIR/okta-idp-metadata.xml" || die "Downloaded IdP metadata looks wrong"
ok "Okta IdP metadata saved to out/okta-idp-metadata.xml"

api_ok PUT "/api/v1/apps/$APP_ID/groups/$GROUP_ID" -d '{}' >/dev/null
ok "App assigned to group '$GROUP_NAME'"

# ---------------------------------------------------------------- 5. sign-in policy
log "App sign-in policy: $POLICY_NAME"
POLICY_ID="$(api_ok GET "/api/v1/policies?type=ACCESS_POLICY" \
  | jq -r --arg n "$POLICY_NAME" '[.[] | select(.name==$n)][0].id // empty')"
if [[ -z "$POLICY_ID" ]]; then
  POLICY_ID="$(api_ok POST /api/v1/policies \
    -d "$(jq -n --arg n "$POLICY_NAME" '{type: "ACCESS_POLICY", name: $n, description: "Password + Okta Verify on every sign-in"}')" \
    | jq -r .id)"
  ok "Created policy ($POLICY_ID)"
else
  warn "Policy exists ($POLICY_ID), reusing"
fi
save_state POLICY_ID "$POLICY_ID"

rule_id="$(api_ok GET "/api/v1/policies/$POLICY_ID/rules" \
  | jq -r --arg n "$RULE_NAME" '[.[] | select(.name==$n)][0].id // empty')"
if [[ -z "$rule_id" ]]; then
  rule_body="$(jq -n --arg n "$RULE_NAME" '{
    name: $n, priority: 1, type: "ACCESS_POLICY",
    conditions: {network: {connection: "ANYWHERE"}},
    actions: {appSignOn: {access: "ALLOW", verificationMethod: {
      type: "ASSURANCE", factorMode: "2FA", reauthenticateIn: "PT0S",
      constraints: [{possession: {deviceBound: "REQUIRED"}}] }}} }')"
  rule_id="$(api_ok POST "/api/v1/policies/$POLICY_ID/rules" -d "$rule_body" | jq -r .id)"
  ok "Created rule '$RULE_NAME' ($rule_id): 2 factors, device-bound possession, every sign-in"
else
  warn "Rule exists ($rule_id), reusing"
fi

code="$(api_status PUT "/api/v1/apps/$APP_ID/policies/$POLICY_ID")"
[[ "$code" == 204 ]] || die "Assigning the policy to the app returned HTTP $code"
ok "Policy attached to the app"

# ---------------------------------------------------------------- done
cat <<EOF

$(printf '\033[1;32m')Lab ready.$(printf '\033[0m')

One manual step (the test SP has no API):
  1. Open https://sptest.iamshowcase.com/instructions
  2. Upload out/okta-idp-metadata.xml under "Upload your metadata file"
  3. Copy the login URL it gives you

Then test in private browser windows at $OKTA_ORG
  Sara (in group):     $(alias_for sara)  -> enroll Okta Verify -> app tile -> lands in the SP
  Omar (not in group): $(alias_for omar)  -> no tile; the SP login URL is refused
  Password for both:   $DEMO_PASSWORD   (also saved in out/state.env)

Verify with:  ./check.sh
Clean up with: ./teardown.sh
EOF
