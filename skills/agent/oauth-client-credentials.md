---
aliases: client credentials grant, server to server auth, oauth machine auth, service account token
tags: auth, oauth, api, credentials
verified: true
source: RFC 6749 Section 4.4
---

OAUTH CLIENT CREDENTIALS FLOW (SERVER-TO-SERVER)

Steps:
1. Obtain client_id and client_secret from the API provider's developer console.
2. POST to the token endpoint:
   - POST /token with grant_type=client_credentials, client_id=CLIENT_ID, client_secret=CLIENT_SECRET, scope=SCOPES
   - OR: use HTTP Basic auth header with client_id:client_secret base64-encoded, body contains only grant_type and scope.
3. Response contains `access_token`, `expires_in`, `token_type`. No refresh token -- request a new token when this one expires.
4. Cache the token until `expires_in` minus a safety margin (e.g., 60 seconds).
5. On 401 response from the API: discard cached token, request a new one, retry the original request once.

Notes:
- This flow has no user interaction. It authenticates the application, not a user.
- Never embed client_secret in client-side code (browser, mobile). This flow is for server-side only.
- Some providers use JWT bearer assertions instead of client_secret (RFC 7523). Check provider docs.
- Rate limit token requests. Requesting a new token on every API call is wasteful and may trigger throttling.
