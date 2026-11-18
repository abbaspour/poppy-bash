#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# token.sh: prints a valid access token for the signed-in User at a Company, refreshing it with
# the refresh token and a client assertion when it is missing or about to expire (§4.4).
#   - A new refresh token in the response replaces the old one (rotation, RFC 6749 §6).
#   - -R gets a token for one service whose protected resource metadata asks for its own (§4.5).
#   - -s asks for fewer scopes than the refresh token has, eg. read-only for a lookup (§4.4).
#   - invalid_grant means the User signed out or disconnected the agent: the tokens are dropped
#     and the Sessions continue signed out (§5.5). Exit 20.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-R resource] [-s scopes] [-f] [-h|?] [-v]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -R resource    # a token for this resource only (§4.5)
        -s scopes      # comma separated subset of the granted scopes (§4.4)
        -f             # refresh even if the cached access token is still valid
        -h|?           # usage
        -v             # verbose: print what happened on stderr

eg,
     $0                       # the default access token
     $0 -f                    # refresh now
     $0 -s orders:read        # a read-only token
END
    exit "$1"
}

declare domain=''
declare resource=''
declare scopes=''
declare -i opt_force=0
declare -i opt_verbose=0

while getopts ":e:d:u:R:s:fhv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    R) resource=${OPTARG} ;;
    s) scopes=$(tr ',' ' ' <<<"${OPTARG}") ;;
    f) opt_force=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery
company_id=$(jq -r .company_id "${discovery}")
readonly company_id
tokens=$(tokens_file "${company_id}")
readonly tokens

[[ -s ${tokens} ]] || { echo >&2 "not signed in at ${domain}; run sign-in.sh"; exit 21; }

function log() { [[ ${opt_verbose} -eq 1 ]] && echo >&2 "> $*"; return 0; }

# §4.5: a sign-in that named resources covers only those; the default token is the one for
# https://{organization.domain}, which sign-in.sh always names alongside
wanted=${resource:-$(jq -r '.website | rtrimstr("/")' "${discovery}")}
if jq -e '.resources' "${tokens}" >/dev/null && ! jq -e --arg w "${wanted}" '.resources | index($w)' "${tokens}" >/dev/null; then
    die "the sign-in named only $(jq -r '.resources | join(", ")' "${tokens}"), not ${wanted}; sign in again with -R ${wanted}"
fi

# cached per resource and scope set
readonly slot="${resource:-default}${scopes:+ #${scopes}}"
now=$(date +%s)
readonly now

if [[ ${opt_force} -eq 0 ]]; then
    cached=$(jq -r --arg s "${slot}" --argjson now "${now}" \
        '.access_tokens[$s] // empty | select(.expires_at - 60 > $now) | .access_token' "${tokens}")
    if [[ -n ${cached} ]]; then
        log "using the cached access token for ${slot}"
        echo "${cached}"
        exit 0
    fi
fi

issuer=$(jq -r .issuer "${tokens}")
readonly issuer
[[ ${issuer} == "$(jq -r '.issuer // ""' "${discovery}")" ]] ||
    die "these tokens are from ${issuer}, but ${domain} now uses another issuer; sign in again (§3.2)"

oidc=$(oidc_bash)
key=$(assertion_key)
kid=$("${DIR}/jwt/jwk.sh" -f "${key}" -t)
readonly oidc key kid

# -x '': the agent authenticates only with its client assertion, whatever an oidc-bash .env says
declare -a args=(-d "$(issuer_host "${issuer}")" -c "${CLIENT_ID}" -k "${kid}" -K "${key}" -A "${CLIENT_ASSERTION_ALG}" -x ''
    -r "$(jq -r .refresh_token "${tokens}")")
[[ -n ${resource} ]] && args+=(-R "${resource}")
[[ -n ${scopes} ]] && args+=(-s "${scopes// /,}")

log "refreshing the access token for ${slot}"
response=$("${oidc}/refresh.sh" "${args[@]}") || die "refresh.sh failed"
readonly response

case $(jq -r '.error // ""' <<<"${response}") in
'') ;;
invalid_grant)
    # §5.5: the refresh token is no longer valid; continue signed out
    rm -f "${tokens}"
    echo >&2 "signed out: the refresh token is no longer valid (the User signed out or disconnected this agent)."
    echo >&2 "Sessions continue signed out; sign in again only if the User asks to (§5.5)."
    exit 20 ;;
invalid_target)
    die "${domain} doesn't offer ${resource} to this agent (§4.5)" ;;
*)
    die "refresh failed: $(jq -r '"\(.error): \(.error_description // "")"' <<<"${response}")" ;;
esac

jq -e '.access_token' <<<"${response}" >/dev/null || die "the refresh response has no access_token"

# rotation: use a new refresh token if the response has one, and keep the old one otherwise
updated=$(jq --argjson r "${response}" --arg s "${slot}" --argjson now "${now}" '
    (if $r.refresh_token then .refresh_token = $r.refresh_token else . end)
    | .access_tokens[$s] = {access_token: $r.access_token, token_type: ($r.token_type // "Bearer"),
                            scope: ($r.scope // .scope), expires_at: ($now + ($r.expires_in // 300))}' "${tokens}")
umask 077
echo "${updated}" >"${tokens}.tmp" && mv "${tokens}.tmp" "${tokens}"
jq -e '.refresh_token' <<<"${response}" >/dev/null && log "the refresh token was rotated"

jq -r '.access_token' <<<"${response}"
