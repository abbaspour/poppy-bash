#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# sign-in.sh: the User signs in to their account at a Company and approves the agent's access
# (section 4). Sign-in is plain OAuth and doesn't involve a Session: the tokens it stores serve any of
# the User's Sessions at this Company (section 5.4).
#
#   Direct Sign-In (section 4.2): authorization code + PKCE, with prompt=consent because the redirect
#     comes back through a public URL rather than only to this device. PAR when the issuer lists
#     it. The redirect's iss must be the Company's issuer exactly (RFC 9207).
#
# By default the sign-in names no resource, so it covers every service the Company offers (section 4.5).
# -R (or POPPY_SIGN_IN_RESOURCES) names resources anyway, for issuers that need one to choose the
# token's audience. The Company's default resource is then always among them, so the default
# token stays available (section 4.5).
#
# Every token request authenticates with a private_key_jwt client assertion whose aud is the
# issuer (section 4.1). oidc-bash makes the OAuth requests; this script adds Poppy's rules.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

declare -i wait_seconds=300

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] -s scopes [-R resource]... [-F callback_url] [-w seconds] [-C] [-n] [-h|?] [-v]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s scopes      # comma separated scopes to request (section 4.7). Scopes already granted are kept.
        -R resource    # name this resource at sign-in (repeatable; "default" is https://{organization.domain}).
                       # Poppy says not to (section 4.5); default POPPY_SIGN_IN_RESOURCES=${POPPY_SIGN_IN_RESOURCES:-none}
        -F url         # finish a Direct Sign-In with the full callback URL from the browser,
                       # instead of waiting for web/server.sh to receive it
        -w seconds     # how long to wait for the callback (default ${wait_seconds})
        -C             # copy the sign-in link to the clipboard
        -n             # don't open the browser; only print the link
        -h|?           # usage
        -v             # verbose

scopes (the shop's OpenAPI document, https://shop.abbaspour.net/openapi.json):
            # See your orders and returns. Needed to track an order or find one to return
        orders:write   # Place orders from your cart and return items. Needed for any change to an order

eg,
     $0 -s orders:read
     $0 -s orders:read,orders:write,poppy:browser-sign-in,offline_access -C
     $0 -s orders:read -R default         # for an issuer that needs a resource
     $0 -F 'https://agent.example.dev/callback?code=...&state=...&iss=...'
END
    exit "$1"
}

declare domain=''
declare requested=''
declare callback_url=''
declare -a resource_args=()
declare -i opt_no_browser=0
declare -i opt_clipboard=0
declare -i opt_verbose=0

while getopts ":e:d:u:s:R:F:w:Cnhv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) requested=${OPTARG} ;;
    R) resource_args+=("${OPTARG}") ;;
    F) callback_url=${OPTARG} ;;
    w) wait_seconds=${OPTARG} ;;
    C) opt_clipboard=1 ;;
    n) opt_no_browser=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -z "${CLIENT_ID}" ]] && { echo >&2 "ERROR: CLIENT_ID undefined; set AGENT_BASE_URL in .env"; usage 1; }
[[ -z "${requested}" && -z "${callback_url}" ]] && { echo >&2 "ERROR: scopes undefined; every sign-in names its scopes (section 4.7)"; usage 1; }

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery

company_id=$(jq -r .company_id "${discovery}")
issuer=$(jq -r '.issuer // empty' "${discovery}")
org_name=$(jq -r '.organization.name' "${discovery}")
readonly company_id issuer org_name

jq -e '.sign_in.available' "${discovery}" >/dev/null || die "${org_name} (${domain}) offers no sign-in (section 3.2)"

dir=$(company_dir "${company_id}")
tokens=$(tokens_file "${company_id}")
readonly dir tokens
readonly pending="${dir}/pending-sign-in.json"
umask 077
mkdir -p "${dir}"

function log() { [[ ${opt_verbose} -eq 1 ]] && echo >&2 "> $*"; return 0; }

# shows the User a sign-in link: prints it, copies it with -C, and opens it in the browser unless -n
function show_link() {
    local link=$1
    echo >&2
    echo >&2 "  ${link}"
    echo >&2
    if [[ ${opt_clipboard} -eq 1 ]]; then
        if printf '%s' "${link}" | copy_to_clipboard; then echo >&2 "(copied to the clipboard)"
        else echo >&2 "note: no clipboard tool found (pbcopy, wl-copy or xclip)"; fi
    fi
    if [[ ${opt_no_browser} -eq 0 ]]; then
        if command -v open >/dev/null && open "${link}" 2>/dev/null; then echo >&2 "(opened in your browser)"
        elif command -v xdg-open >/dev/null && xdg-open "${link}" 2>/dev/null; then echo >&2 "(opened in your browser)"
        else echo >&2 "note: couldn't open a browser; open the link yourself"; fi
    fi
}

oidc=$(oidc_bash)
readonly oidc
host=$(issuer_host "${issuer}")
readonly host
key=$(assertion_key)
readonly key
[[ -f ${key} ]] || die "missing ${key}; run keys/gen-keys.sh"
kid=$("${DIR}/jwt/jwk.sh" -f "${key}" -t)
readonly kid
readonly -a assertion=(-k "${kid}" -K "${key}" -A "${CLIENT_ASSERTION_ALG}")
# the agent authenticates only with its client assertion: -x '' overrides any CLIENT_SECRET an
# oidc-bash .env might set, for the scripts that take one (OIDC_BASH_NO_DOTENV=1 already skips it)
readonly -a no_secret=(-x '')

# --- what to request (section 4.7) ---
function normalize_scopes() { tr ', ' '\n\n' | sed '/^$/d' | awk '!seen[$0]++' | paste -sd ' ' -; }

declare scopes
scopes=$(normalize_scopes <<<"${requested}")
# signing in again: request every scope still needed, including those granted before (section 4.7)
if [[ -s ${tokens} ]]; then
    scopes=$(printf '%s %s' "$(jq -r '.scope // ""' "${tokens}")" "${scopes}" | normalize_scopes)
fi
if [[ " ${scopes} " == *" poppy:browser-sign-in "* ]] && ! jq -e '.poppy.web.browser_session_endpoint' "${discovery}" >/dev/null; then
    die "poppy:browser-sign-in is only for Companies that list web.browser_session_endpoint (section 6)"
fi
# Auth0 issues a refresh token only for offline_access; Poppy needs one from every sign-in (section 4.4)
if jq -e '.authorization_server.scopes_supported // [] | index("offline_access")' "${discovery}" >/dev/null &&
    [[ " ${scopes} " != *" offline_access "* ]]; then
    scopes="${scopes:+${scopes} }offline_access"
    log "adding offline_access, which this issuer needs to issue a refresh token"
fi
readonly scopes

# --- resources to name at sign-in (section 4.5): none, unless asked ---
default_resource=$(jq -r '.website | rtrimstr("/")' "${discovery}")
readonly default_resource
declare -a resources=()
if [[ ${#resource_args[@]} -eq 0 && -n ${POPPY_SIGN_IN_RESOURCES} ]]; then
    read -r -a resource_args <<<"${POPPY_SIGN_IN_RESOURCES//,/ }"
fi
# signing in again names the resources the first sign-in did, like it keeps the scopes (section 4.7)
if [[ -s ${tokens} ]]; then
    while read -r r; do resource_args+=("${r}"); done < <(jq -r '.resources // [] | .[]' "${tokens}")
fi
for r in ${resource_args[@]+"${resource_args[@]}"}; do
    [[ ${r} == default ]] && r=${default_resource}
    url_allowed "${r}" || die "resource must be an HTTPS URL: ${r}"
    [[ " ${resources[*]-} " == *" ${r} "* ]] || resources+=("${r}")
done
# after a sign-in that names resources, only one that named the default resource gets the
# default token (section 4.5), so always name it too
if [[ ${#resources[@]} -gt 0 && " ${resources[*]} " != *" ${default_resource} "* ]]; then
    resources=("${default_resource}" "${resources[@]}")
fi
readonly resources
[[ ${#resources[@]} -gt 0 ]] &&
    echo >&2 "note: naming resources at sign-in, which Poppy says not to (section 4.5): ${resources[*]}"

# --- Direct Sign-In is the only sign-in type (section 4.2) ---
jq -e '.sign_in.direct' "${discovery}" >/dev/null || die "${org_name} doesn't offer Direct Sign-In"

declare response=''

[[ -n ${AGENT_BASE_URL} ]] || die "AGENT_BASE_URL undefined; Direct Sign-In returns to \${AGENT_BASE_URL}/callback"
readonly redirect_uri="${AGENT_BASE_URL%/}/callback"

if [[ -z ${callback_url} ]]; then
    # --- start: build the authorization request ---
    state="$(rand_id)$(rand_id)"
    # -r '' and -x '': Poppy has no connection, and the agent uses no client secret
    declare -a args=(-d "${host}" -c "${CLIENT_ID}" -f pkce -s "${scopes// /,}" -p consent
        -S "${state}" -n "$(rand_id)" -u "${redirect_uri}" -r '' -x '' -N)
    # section 4.2: PAR whenever the issuer lists it, with the client assertion
    jq -e '.sign_in.par' "${discovery}" >/dev/null && args+=(-Q -k "${kid}" -K "${key}" -Y "${CLIENT_ASSERTION_ALG}")
    for r in ${resources[@]+"${resources[@]}"}; do args+=(-q "${r}"); done
    out=$("${oidc}/authorize.sh" "${args[@]}") || die "authorize.sh failed: ${out:-no output}"
    code_verifier=$(sed -n 's/^code_verifier=//p' <<<"${out}")
    authorize_url=$(grep -E '^https://' <<<"${out}" | tail -1)
    [[ -n ${code_verifier} && -n ${authorize_url} ]] || die "authorize.sh didn't return a URL and code_verifier"

    # the browser must go to the authorization_endpoint this Company's metadata names (section 3.2)
    endpoint=$(jq -r '.authorization_server.authorization_endpoint' "${discovery}")
    [[ ${authorize_url} == "${endpoint}?"* ]] || die "authorization URL isn't at ${endpoint}"

    jq -n --arg state "${state}" --arg verifier "${code_verifier}" --arg issuer "${issuer}" \
        --arg redirect_uri "${redirect_uri}" --arg scope "${scopes}" --arg started_at "$(iso_now)" \
        '{state: $state, code_verifier: $verifier, issuer: $issuer, redirect_uri: $redirect_uri, scope: $scope, started_at: $started_at}' \
        >"${pending}"

    echo >&2 "Sign in to ${org_name} (${domain}) and approve: ${scopes}"
    show_link "${authorize_url}"

    # --- wait for web/public/cgi-bin/callback.sh ---
    callback_file="${POPPY_STATE}/callbacks/${state}.json"
    echo >&2 "waiting up to ${wait_seconds}s for the redirect to ${redirect_uri} (make serve and make tunnel must be running)"
    echo >&2 "or finish later with: $0 -F '<the URL the browser ends up on>'"
    declare -i waited=0
    until [[ -s ${callback_file} ]]; do
        (( waited >= wait_seconds )) && die "no callback after ${wait_seconds}s; finish with -F, or sign in again"
        sleep 1
        waited+=1
    done
    callback=$(cat "${callback_file}")
    rm -f "${callback_file}"
else
    # --- finish with a callback URL the User pasted ---
    [[ -s ${pending} ]] || die "no pending Direct Sign-In at ${company_id}"
    query=$(url_part "${callback_url}" query)
    # the callback URL's query parameters, decoded, as callback.sh would have saved them
    callback=$(python3 -c 'import json,sys,urllib.parse; print(json.dumps({k: v[0] for k, v in urllib.parse.parse_qs(sys.argv[1]).items()}))' "${query#\?}")
fi

[[ -s ${pending} ]] || die "no pending sign-in; it may have finished already"
state=$(jq -r .state "${pending}")
code_verifier=$(jq -r .code_verifier "${pending}")

# --- check the authorization response ---
[[ $(jq -r '.state // ""' <<<"${callback}") == "${state}" ]] || die "the callback's state isn't this sign-in's"
# section 4.2, RFC 9207: iss must be the issuer this sign-in started with, also on errors
cb_iss=$(jq -r '.iss // ""' <<<"${callback}")
[[ -n ${cb_iss} ]] || die "the callback has no iss; can't tell which authorization server answered (RFC 9207)"
[[ ${cb_iss} == "${issuer}" ]] || die "the callback's iss '${cb_iss}' isn't ${issuer}; refusing a mixed-up response"
rm -f "${pending}"
if [[ -n $(jq -r '.error // ""' <<<"${callback}") ]]; then
    err=$(jq -r .error <<<"${callback}")
    [[ ${err} == access_denied ]] && die "the User declined; existing tokens are unchanged (section 4.7)"
    die "sign-in failed: ${err}: $(jq -r '.error_description // ""' <<<"${callback}")"
fi
code=$(jq -r '.code // ""' <<<"${callback}")
[[ -n ${code} ]] || die "the callback has no code"

# --- exchange the code, with the client assertion (section 4.2) ---
log "POST token endpoint: authorization_code"
response=$("${oidc}/code-exchange.sh" -d "${host}" -c "${CLIENT_ID}" "${assertion[@]}" "${no_secret[@]}" \
    -a "${code}" -X "${code_verifier}" -u "${redirect_uri}") || die "code-exchange.sh failed"

# --- the token response (section 4.7) ---
if jq -e '.error' <<<"${response}" >/dev/null; then
    die "token request failed: $(jq -r '"\(.error): \(.error_description // "")"' <<<"${response}")"
fi
jq -e '.access_token' <<<"${response}" >/dev/null || die "the token response has no access_token"
jq -e '.refresh_token' <<<"${response}" >/dev/null ||
    die "the token response has no refresh_token; Poppy needs one from every sign-in (section 4.4). On Auth0, allow offline access on the API"

# without scope in the response, the Company granted exactly what was requested (RFC 6749 section 5.1)
granted=$(jq -r --arg req "${scopes}" '.scope // $req' <<<"${response}" | normalize_scopes)
readonly granted

old_refresh_token=''
[[ -s ${tokens} ]] && old_refresh_token=$(jq -r '.refresh_token // ""' "${tokens}")

now=$(date +%s)
resources_json=$(printf '%s\n' ${resources[@]+"${resources[@]}"} | jq -R 'select(. != "")' | jq -sc .)
jq -n --argjson r "${response}" --arg issuer "${issuer}" --arg scope "${granted}" \
    --arg at "$(iso_now)" --argjson now "${now}" --argjson resources "${resources_json}" \
    '{issuer: $issuer, signed_in_at: $at, scope: $scope, refresh_token: $r.refresh_token}
     + (if ($resources | length) > 0 then {resources: $resources} else {} end) + {
      access_tokens: {default: {access_token: $r.access_token, token_type: ($r.token_type // "Bearer"),
                                scope: ($r.scope // $scope), expires_at: ($now + ($r.expires_in // 300))}}}' >"${tokens}.tmp"
mv "${tokens}.tmp" "${tokens}"

# the new refresh token replaces the old one, which the agent SHOULD revoke (section 4.7); not a sign-out
if [[ -n ${old_refresh_token} && ${old_refresh_token} != "$(jq -r .refresh_token "${tokens}")" ]]; then
    "${oidc}/revoke-refresh-token.sh" -d "${host}" -c "${CLIENT_ID}" "${assertion[@]}" "${no_secret[@]}" -r "${old_refresh_token}" >/dev/null 2>&1 ||
        echo >&2 "note: couldn't revoke the replaced refresh token"
fi

echo >&2 "signed in to ${org_name} (${domain}) with: ${granted}"
missing=$(comm -23 <(tr ' ' '\n' <<<"${scopes}" | sort) <(tr ' ' '\n' <<<"${granted}" | sort) | paste -sd ' ' -)
[[ -n ${missing} ]] && echo >&2 "note: not granted: ${missing}"
jq '{issuer, signed_in_at, scope} + (if .resources then {resources} else {} end)' "${tokens}"
