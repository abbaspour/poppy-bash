#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# sign-out.sh: ends the agent's access to the User's account at a Company by revoking its
# refresh token at the revocation_endpoint, with token_type_hint=refresh_token and a client
# assertion (§4.6). The User's Sessions continue signed out: requests keep the Session header
# and carry no access token (§5.5).
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
USAGE: $0 [-e env] [-d domain] [-u user] [-h|?]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -h|?           # usage

eg,
     $0
END
    exit "$1"
}

declare domain=''

while getopts ":e:d:u:h" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
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

[[ -s ${tokens} ]] || { echo >&2 "not signed in at ${domain}"; exit 0; }

issuer=$(jq -r .issuer "${tokens}")
oidc=$(oidc_bash)
key=$(assertion_key)
kid=$("${DIR}/jwt/jwk.sh" -f "${key}" -t)
readonly issuer oidc key kid

# RFC 7009 §2.2: a token that's already invalid also gets HTTP 200, so any 2xx means signed out
if ! "${oidc}/revoke-refresh-token.sh" -d "$(issuer_host "${issuer}")" -c "${CLIENT_ID}" \
    -k "${kid}" -K "${key}" -A "${CLIENT_ASSERTION_ALG}" -x '' -r "$(jq -r .refresh_token "${tokens}")" >/dev/null 2>"${tokens}.err"; then
    echo >&2 "ERROR: revocation failed; still signed in: $(tr '\n' ' ' <"${tokens}.err")"
    rm -f "${tokens}.err"
    exit 1
fi
rm -f "${tokens}.err" "${tokens}"

echo >&2 "signed out of $(jq -r .organization.name "${discovery}") (${domain}). Sessions continue signed out (§5.5)."
