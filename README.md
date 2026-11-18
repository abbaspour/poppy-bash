# poppy-bash

A Personal Agent for the [Personal Agent Protocol](https://personalagentprotocol.org/) (Poppy) 1.0,
written as bash scripts. Point it at any Company that publishes `/.well-known/poppy.json`. It
discovers what the Company offers, starts a signed-out Session, signs the User in when a task needs
their account, and calls the Company's APIs on the User's behalf.

This repo is for _learning_. Following [oidc-bash](https://github.com/abbaspour/oidc-bash), the
scripts favor being easy to read over avoiding every duplicate line. Each script does one protocol
step, explains itself in `-h`, and cites the spec sections it implements.

## Status

| Phase | Scope                                                                                                                         | State   |
|-------|-------------------------------------------------------------------------------------------------------------------------------|---------|
| 1     | Agent identity (CIMD, JWKS), discovery (§3), User IDs, Sessions, delegated keys, Session JWTs (§5), signed-out API calls (§7) | done    |
| 2     | Direct and Device Sign-In (§4.2, §4.3), refresh, sign-out, signed-in API calls; uses oidc-bash                                | done    |
| 3     | Tasks and feedback (§9), conversations (§8)                                                                                   | planned |

## Requirements

bash 4+, curl, jq, openssl, xxd, python3, git. You also need `cloudflared` to expose the agent's
metadata and `shellcheck` for `make check`.

Sign-in uses [oidc-bash](https://github.com/abbaspour/oidc-bash) for the OAuth requests.
`setup.sh` finds it at `OIDC_BASH_DIR` (default `../oidc-bash`), or clones it into `vendor/`.
poppy-bash passes oidc-bash everything as flags and sets `OIDC_BASH_NO_DOTENV=1`, so oidc-bash's
own `.env` never mixes into a Poppy sign-in. It also passes `-x ''` and `-r ''` explicitly, so no
client secret or Auth0 connection can reach a request even if a `.env` were loaded. On macOS,
oidc-bash needs GNU coreutils on `PATH`.

## Setup

The Personal Agent's `client_id` is an HTTPS URL that returns its client metadata document
(§4.1). Companies fetch it, and the `jwks_uri` it names, to verify the agent's signatures. So
`web/public/` has to be reachable from the internet. This repo uses a Cloudflare tunnel for that.

1. Create a tunnel: Cloudflare dashboard > Networking > Tunnels > Create tunnel, with a public
   hostname such as `agent.abbaspour.net` pointing at `http://localhost:1990`.
2. Run `./setup.sh`. It creates `.env` from `env.sample`.
3. Edit `.env`. Set `AGENT_BASE_URL=https://agent.abbaspour.net`, and set `TUNNEL_ID` and
   `TUNNEL_HOSTNAME`. Put the tunnel token in `web/.tunnel-token`.
4. Run `./setup.sh` again. It creates the keys in `keys/`, then writes `web/public/jwks.json` and
   `web/public/cimd.json`.
5. Serve the files and open the tunnel, each in its own terminal:

   ```bash
   make serve
   make tunnel
   ```

6. Check that `https://agent.abbaspour.net/cimd.json` returns the document.

The agent has two long-lived keys, and both are published in `jwks.json`:

- `agent-ec-private.pem` (P-256) signs delegations (§5.2). With `CLIENT_ASSERTION_ALG=ES256`, it
  also signs client assertions.
- `agent-rsa-private.pem` signs client assertions with `PS256` or `RS256`. Poppy requires
  Companies to accept ES256 and PS384, so the default `CLIENT_ASSERTION_ALG=ES256` works with any
  conforming issuer. An authorization server that accepts only RSA algorithms (standard Auth0
  tenants accept RS256, RS384 and PS256) needs `CLIENT_ASSERTION_ALG=PS256`.

### Registering with a Company's issuer

Companies decide which Personal Agents they accept (§4.1). An issuer that supports CIMD fetches
`cimd.json` when the agent first signs in. With Auth0, either turn on Dynamic CIMD Registration,
or import the agent once under Applications > Create Application > Import from URL. Auth0 treats
CIMD clients as third-party applications, so the client also needs a grant for the Company's API.
To use Device Sign-In, the application also needs the Device Code grant enabled.

Direct Sign-In returns the browser to `${AGENT_BASE_URL}/callback`. `web/server.sh` routes that to
[`web/public/cgi-bin/callback.sh`](./web/public/cgi-bin/callback.sh), which hands the response to
the waiting `sign-in.sh`. Keep `make serve` and `make tunnel` running while signing in.

## Walkthrough

```bash
# 1. Discovery (§3). Fetches poppy.json, the protected resource metadata and the issuer's
#    metadata, and runs every check. The domain becomes the default for the other scripts.
./discover.sh -d shop.abbaspour.net

# 2. A User ID for this User at this Company (§5.1): random, stable, and different per Company
./user.sh

# 3. A Session (§5). There is no request to start one: the first request with a new sid starts it
./session.sh new

# 4. Signed-out API calls (§7). Each request carries a fresh Session JWT.
./api.sh list
./api.sh ops
./api.sh call GET /products
./api.sh call POST /cart/items '{"sku":"tee-m","quantity":2}'
./api.sh -v call GET /cart        # -v shows the decoded Session JWT
./api.sh call GET /session        # what the Company knows about this Session

# 5. Session continuity: the cart belongs to the Session, so a new Session starts empty
./session.sh new
./api.sh call GET /cart
./session.sh list

# 6. Account access needs sign-in. Signed out, the API says which scope it needs (§7)
./api.sh call POST /cart/items '{"sku":"mug"}'
./api.sh call GET /orders                      # 401: SIGN-IN NEEDED ... scope "orders:read"

# 7. Direct Sign-In (§4.2): opens the Company's sign-in and consent page in the browser, and
#    waits for the redirect to ${AGENT_BASE_URL}/callback. -m device uses Device Sign-In (§4.3).
./sign-in.sh -s orders:read,orders:write       # -C also copies the link; -n doesn't open the browser
# -R default names the Company's resource at sign-in, for issuers that need one (see below)
# if the redirect didn't reach web/server.sh, paste the URL the browser ended up on:
#   ./sign-in.sh -F 'https://agent.abbaspour.net/callback?code=...&state=...&iss=...'

# 8. Signed-in calls: the same Session, now with an access token. The cart filled signed out
#    is checked out signed in.
./api.sh call GET /orders
./api.sh call POST /orders                     # places an order from the Session's cart
./api.sh call POST /orders/ord_1042/returns '{"sku":"stormline-insulated-m","reason":"not warm enough"}'
./api.sh call GET /session                     # signed_in, the account and its scopes
./api.sh -o call GET /orders                   # -o: this one call signed out again

# 9. Refresh (§4.4) and sign-out (§4.6). After sign-out the Session continues signed out (§5.5)
./token.sh -f -v
./sign-out.sh
./api.sh call GET /orders                      # 401 again
./api.sh call GET /cart                        # the Session itself is still there
```

The Session JWT that `poppy-curl.sh` sends with each request looks like this
(`./jwt/decode.sh -D <jwt>` shows the delegation too):

```json
{
  "header": { "typ": "poppy-session+jwt", "alg": "ES256", "kid": "<delegated key thumbprint>", "poppy_dlg": "<delegation>" },
  "payload": {
    "iss": "https://agent.example.dev/cimd.json",
    "aud": "<Company identifier: issuer, or https://{domain}>",
    "sid": "gDT2Y687_hEMzSxH723msQ",
    "sub": "usr_GmDIGpOXRXrLl2Uyl2cpnw",
    "htm": "GET",
    "htu": "https://shop.example.dev/api/cart",
    "iat": 1794887637,
    "jti": "mjZ6HVtWaX2gSPlLjvfc3A"
  }
}
```

## Scripts

| Script                                                               | Spec             | What it does                                                                                                                                                                                                                                                                                 |
|----------------------------------------------------------------------|------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [`setup.sh`](./setup.sh)                                             |                  | Checks dependencies, creates `.env`, finds or clones oidc-bash, creates keys, JWKS and CIMD                                                                                                                                                                                                  |
| [`keys/gen-keys.sh`](./keys/gen-keys.sh)                             | §4.1             | Creates the agent's EC and RSA keys                                                                                                                                                                                                                                                          |
| [`keys/build-jwks.sh`](./keys/build-jwks.sh)                         | §4.1             | Writes `web/public/jwks.json`, with each `kid` set to the key's RFC 7638 thumbprint                                                                                                                                                                                                          |
| [`web/build-cimd.sh`](./web/build-cimd.sh)                           | §4.1             | Writes `web/public/cimd.json`. Its `client_id`, `jwks_uri` and `redirect_uris` are all on `AGENT_BASE_URL`                                                                                                                                                                                   |
| [`web/server.sh`](./web/server.sh)                                   |                  | Serves `web/public`, and routes `/callback` to `cgi-bin/callback.sh`                                                                                                                                                                                                                         |
| [`web/public/cgi-bin/callback.sh`](./web/public/cgi-bin/callback.sh) | §4.2             | The Direct Sign-In `redirect_uri`: saves the authorization response for `sign-in.sh`                                                                                                                                                                                                         |
| [`discover.sh`](./discover.sh)                                       | §3, §3.2, §3.4   | Runs discovery and its checks, chooses a version, and caches a summary in `.cache/<domain>/discovery.json`                                                                                                                                                                                   |
| [`user.sh`](./user.sh)                                               | §5.1             | Gets or creates the User ID, and an optional Agent ID with `-A`                                                                                                                                                                                                                              |
| [`session.sh`](./session.sh)                                         | §5, §5.5         | `new`, `current`, `list`, `use <sid>`, `end [sid]`                                                                                                                                                                                                                                           |
| [`delegation.sh`](./delegation.sh)                                   | §5.2             | Creates the User's delegated key and its delegation, and renews them before they expire                                                                                                                                                                                                      |
| [`poppy-curl.sh`](./poppy-curl.sh)                                   | §5.2, §5.6, §7   | Sends one request with `Poppy-Session` and `Poppy-Version` (and `Authorization` when signed in), and maps protocol errors to exit codes                                                                                                                                                      |
| [`api.sh`](./api.sh)                                                 | §7, §4.5         | `list` and `ops` show the Company's APIs and operations; `call METHOD PATH [json]` calls one through `poppy-curl.sh`, signed in when the User is (`-o` for signed out). Retries once after refreshing an `invalid_token`                                                                     |
| [`sign-in.sh`](./sign-in.sh)                                         | §4.2, §4.3, §4.7 | Direct Sign-In (PKCE, `prompt=consent`, PAR when listed, `iss` check) or Device Sign-In (link-host check). Opens the link in the browser (`-n` not), copies it with `-C`, finishes from a pasted callback URL with `-F`. Keeps scopes granted earlier and revokes the replaced refresh token |
| [`token.sh`](./token.sh)                                             | §4.4, §4.5       | Prints a valid access token, refreshing it when it's about to expire (`-f` to force). Handles rotation, `-R resource` and `-s` downscoping                                                                                                                                                   |
| [`sign-out.sh`](./sign-out.sh)                                       | §4.6, §5.5       | Revokes the refresh token; the Sessions continue signed out                                                                                                                                                                                                                                  |
| [`jwt/session-jwt.sh`](./jwt/session-jwt.sh)                         | §5.2             | Low-level Session JWT signer                                                                                                                                                                                                                                                                 |
| [`jwt/sign.sh`](./jwt/sign.sh)                                       |                  | Signs JWTs with openssl: ES256, RS256, PS256, PS384                                                                                                                                                                                                                                          |
| [`jwt/jwk.sh`](./jwt/jwk.sh)                                         | RFC 7638         | Prints a key's public JWK or thumbprint                                                                                                                                                                                                                                                      |
| [`jwt/decode.sh`](./jwt/decode.sh)                                   |                  | Decodes a JWT, and with `-D` also its delegation                                                                                                                                                                                                                                             |

### `poppy-curl.sh` exit codes

| Code | Meaning                                                 | What to do                                                                |
|------|---------------------------------------------------------|---------------------------------------------------------------------------|
| 0    | 2xx (3xx redirects are reported, never followed)        |                                                                           |
| 10   | `invalid_session`                                       | Fix the cause: delegation, `htu`, clock or CIMD. A new Session won't help |
| 11   | `session_ended`, again after one retry in a new Session | Stop                                                                      |
| 12   | `version_unsupported`, after rediscovery                | Stop                                                                      |
| 20   | 401 `invalid_token`                                     | Refresh the access token, or continue signed out                          |
| 21   | 401 without a token: sign-in needed                     | Sign in with the challenge's `scope`                                      |
| 22   | 403 `insufficient_scope`                                | Sign in again, requesting the missing scopes                              |
| 23   | 403 `extension_required`                                |                                                                           |
| 29   | 429                                                     | Wait `Retry-After` before sending the request again                       |
| 4    | Any other HTTP error                                    |                                                                           |

`token.sh` uses the same codes where they apply: 20 when the refresh token is no longer valid,
so the User is signed out (§5.5), and 21 when the User isn't signed in.

## What the agent enforces

- **Discovery (§3).** It follows only HTTPS redirects, and the last URL must be exactly
  `/.well-known/poppy.json` with no query. `organization.domain` must be the host that served the
  document. It never falls back to "no issuer" after an error. The issuer's `issuer` must match
  character for character, and its `protected_resources` must list `https://{domain}`. Every URL
  in the document must be HTTPS. Loopback and private addresses are refused.
- **Session destinations (§5.2).** A Session JWT goes only to URLs that `poppy.json` lists: the
  OpenAPI `servers`, MCP and conversation endpoints, the tasks endpoint, and browser join. Website
  pages on `organization.domain` get one too, but always signed out. Discovery documents never
  do.
- **Delegated keys (§5.2).** Each User has their own delegated key at each Company, so Companies
  can't link a User across Companies by key or delegation. A delegation names no User or Company.
  It lasts `POPPY_DELEGATION_TTL` (at most 24h), and is renewed 2 minutes before it expires.
- **Pinned per Session (§3.4, §5.2).** `sub`, `agent_id`, `Poppy-Version` and `Poppy-Extensions`
  stay the same for the whole Session.
- **No redirects with secrets (§3).** `poppy-curl.sh` never follows a redirect.
- **Sign-in (§4).** Every token request authenticates with a private_key_jwt client assertion
  whose `aud` is the issuer, and lasts 5 minutes. Every sign-in names its scopes. A Direct Sign-In
  redirect is used only if its `state` matches and its `iss` is exactly the Company's issuer. The
  authorization URL must be the issuer's `authorization_endpoint`. A Device Sign-In link is shown
  only if its host is the issuer's or the Company's. A sign-in must return a refresh token. When
  the issuer lists `offline_access`, as Auth0 does, it's added to the request, because Auth0
  issues refresh tokens only for that scope.
- **No `resource` at sign-in (§4.5).** By default a sign-in names no resource, so it covers
  every service the Company offers, and token requests name a resource only for a service that
  asks for its own. Some issuers need a resource to choose the token's audience: Auth0 does
  without a default audience. For those, `sign-in.sh -R default`, or
  `POPPY_SIGN_IN_RESOURCES=default` in `.env`, names `https://{organization.domain}`. Any named
  resources always include that one, so the default token stays available. Signing in again names
  them again. `token.sh` refuses a resource the sign-in didn't name.
- **Tokens per service (§4.5).** Before its first signed-in call, the agent fetches each API's
  protected resource metadata. An API that asks for its own resource gets a token for that
  resource only.

Not yet implemented: Web Bot Auth operator signatures (§5.3, SHOULD), DPoP (§4.5), and anonymous
User IDs (§5.1).

## State

Everything is kept under `.state/` (User IDs, Sessions, delegated keys, tokens) and `.cache/`
(discovery), both gitignored:

```
.cache/<domain>/{poppy,protected-resource,authorization-server,openapi-*,discovery}.json
.state/current-domain
.state/callbacks/<state>.json                   # a Direct Sign-In response, until sign-in.sh takes it
.state/users/<POPPY_USER>/<company identifier>/user.json
                                              /sessions/<sid>.json
                                              /current-session
                                              /delegation/{key.pem,delegation.jwt}
                                              /tokens.json            # refresh token, access tokens
                                              /pending-sign-in.json   # state and PKCE verifier
```

Tokens belong to the User and Company, not to a Session: any of the User's Sessions at the Company
can use them (§4.4).

User IDs are scoped by the Company identifier, not the domain (§5.1). Several domains that share an
issuer therefore share one User ID.

## Local development

You can run this against a Company on `http://localhost`, such as
[poppy-sample-company-cloudflare-auth0](../poppy-sample-company-cloudflare-auth0) under
`wrangler dev`. The spec requires HTTPS, so this is for testing only:

```bash
# .env
AGENT_BASE_URL=http://localhost:1990
POPPY_DEV_ALLOW_HTTP=1

./web/build-cimd.sh && make serve        # agent metadata on http://localhost:1990
./discover.sh -d localhost:8787          # the Company under `make dev`
./api.sh call GET /session
```

The Company also has to accept agent metadata over http. The sample Company does this in its `dev`
environment.

## Check

```bash
make check
```
