# okta-saml-mfa-lab

Builds an Okta workforce SSO setup from the Management API: a SAML 2.0 app, access controlled by a group, and an app sign-in policy that requires Okta Verify on every sign-in. You then prove it in a browser: one user gets in after MFA, one user is refused.

It's the pattern used to move a company's apps to Okta one at a time, run here against a free sandbox:

```
 Sara (in "App - Demo") ──▶ password ──▶ Okta Verify push ──▶ SAML assertion ──▶ test app  ✅
 Omar (not in the group) ─▶ password ──▶ no app assigned ───────────────────────▶ refused   ⛔
```

## What it creates

| Object | Name | Why |
| --- | --- | --- |
| Users | `Sara Test`, `Omar Test` | One user with access and one without, to prove the boundary |
| Group | `App - Demo` | Access by group, so granting or removing access is one membership change |
| App | `SAML Test App (Demo)` | Custom SAML 2.0 integration with signed response and assertion, SHA-256, email NameID, and first/last name attributes |
| Sign-in policy | `Demo - MFA required` | Rule: 2 factors, a device-bound possession factor (Okta Verify), re-auth on every sign-in. Email can't count as the second factor |
| Enrollment policy | default (updated) | Okta Verify set to optional, so users can enroll it |

The service provider is the public [RSA SAML Test Service Provider](https://sptest.iamshowcase.com/). It shows the assertion it receives, so you can see exactly what Okta sent.

## Requirements

- A **free Okta Integrator org** (sign up at [developer.okta.com/signup](https://developer.okta.com/signup/)). Never run this against a client or production org.
- An API token from that org: Admin Console → Security → API → Tokens.
- `bash`, `curl`, `jq`.
- The Okta Verify app on your phone, for the browser test.

## Run it

```bash
cp .env.example .env        # set OKTA_ORG and EMAIL_BASE
./setup.sh                  # prompts for the API token (hidden input)
```

`setup.sh` is safe to re-run: it reuses objects that already exist by name. IDs and the generated test password go to `out/state.env`, which is git-ignored.

**One manual step:** the test SP has no API. Upload `out/okta-idp-metadata.xml` at [sptest.iamshowcase.com/instructions](https://sptest.iamshowcase.com/instructions) under "Upload your metadata file" and copy the login URL it returns.

## Prove it

In private browser windows at your org URL:

1. **Sara** signs in, enrolls Okta Verify, clicks **SAML Test App (Demo)** and lands on the SP's "Hello Sara Test" page, with the assertion details shown.
2. **Omar** signs in and has no app tile. Opening the SP login URL is refused.

Then:

```bash
./check.sh
```

```
==> App visibility (expected: Sara sees it, Omar does not)
  you+sara@gmail.com                   SAML Test App (Demo)
  you+omar@gmail.com                   <no apps>
==> System Log for the app, last 60 min (challenge -> MFA -> SSO)
  20:08:08  policy.evaluate_sign_on                  CHALLENGE   you+sara@gmail.com
  20:08:33  user.authentication.verify               SUCCESS     you+sara@gmail.com
  20:08:34  user.authentication.sso                  SUCCESS     you+sara@gmail.com
```

The log shows the policy challenging Sara for this app specifically, Okta Verify passing, and then SSO.

## Clean up

```bash
./teardown.sh               # asks you to type DELETE
```

Then revoke the API token (Security → API → Tokens).

## Notes

- **Why a custom SAML app, not the catalog entry?** Catalog apps are added by their internal name, which is awkward to look up by API. A custom SAML 2.0 app shows the full configuration, which is what you set for apps that aren't in the catalog.
- **Token handling:** the token is read with hidden input or from `.env`. It's never printed or written to `out/`.
- **In a real rollout**, the same steps run per app with a pilot group first, the app's own admin login kept as a way back, and SCIM provisioning enabled where the app supports it.
- Okta API references: [Applications](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/Application/), [Policies](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/Policy/), [System Log](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/SystemLog/).
