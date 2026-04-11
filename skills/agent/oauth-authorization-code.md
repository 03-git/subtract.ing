---
aliases: oauth authorization code, oauth pkce, oauth login flow, get oauth token, authorization code grant
tags: auth, oauth, api, credentials
verified: true
source: RFC 6749 Section 4.1, RFC 7636
---

OAUTH AUTHORIZATION CODE FLOW (WITH PKCE)

Steps:
1. Generate a `code_verifier`: 43-128 character random string (A-Z, a-z, 0-9, -, ., _, ~).
2. Compute `code_challenge`: base64url(sha256(code_verifier)). Set method to S256.
3. Redirect user to authorization endpoint:
   - GET /authorize?response_type=code&client_id=CLIENT_ID&redirect_uri=REDIRECT&code_challenge=CHALLENGE&code_challenge_method=S256&scope=SCOPES&state=RANDOM_STATE
4. User authenticates and consents. Server redirects to redirect_uri with ?code=AUTH_CODE&state=STATE.
5. Verify state matches what you sent. If not, abort -- possible CSRF.
6. Exchange code for tokens:
   - POST /token with grant_type=authorization_code, code=AUTH_CODE, redirect_uri=REDIRECT, client_id=CLIENT_ID, code_verifier=VERIFIER
7. Response contains `access_token`, `refresh_token` (if granted), `expires_in`, `token_type`.
8. Store tokens securely. Never log access tokens. Set a timer to refresh before expiry.

Notes:
- PKCE is mandatory for public clients and recommended for all clients (RFC 7636).
- Always use state parameter to prevent CSRF. Always use HTTPS.
- If the server returns error=invalid_grant, the code was already used or expired. Codes are single-use.
- Token endpoint may require client_secret for confidential clients (server-side apps). Public clients (SPAs, mobile) omit it.
