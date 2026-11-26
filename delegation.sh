#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# delegation.sh: makes sure the User has a valid delegated key at a Company (section 5.2), and
# prints the directory that holds it (key.pem, delegation.jwt).
#
# Session JWTs are signed with a short-lived delegated key, not with a key from jwks.json.
# A jwks.json key signs a delegation that vouches for it:
#   header  {alg: ES256, typ: poppy-delegation+jwt, kid: <jwks key thumbprint>}
#   claims  {iss: client_id, cnf: {jwk: <delegated public key>}, iat, exp, jti}
# The delegation names no User or Company. Each delegated key signs for one User ID only, so
# it lives in that User's directory for that Company and Companies can't link Users by it.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v openssl >/dev/null || { echo >&2 "error: openssl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-n] [-h|?] [-v]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -n             # new delegated key and delegation even if the current one is valid
        -h|?           # usage
        -v             # verbose: print the decoded delegation

eg,
     $0 -d shop.example.com -v
END
    exit "$1"
}

declare domain=''
declare -i opt_new=0
declare -i opt_verbose=0

while getopts ":e:d:u:nhv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    n) opt_new=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -z "${CLIENT_ID}" ]] && { echo >&2 "ERROR: CLIENT_ID undefined; set AGENT_BASE_URL in .env"; usage 1; }
[[ -f "${AGENT_EC_KEY}" ]] || die "missing ${AGENT_EC_KEY}; run keys/gen-keys.sh"
(( POPPY_DELEGATION_TTL > 0 && POPPY_DELEGATION_TTL <= 86400 )) || die "POPPY_DELEGATION_TTL must be 1..86400"

domain=$(resolve_domain "${domain}")
readonly domain

discovery=$(load_discovery "${domain}")
company_id=$(jq -r .company_id "${discovery}")
readonly company_id

dlg_dir="$(company_dir "${company_id}")/delegation"
readonly dlg_dir

umask 077
mkdir -p "${dlg_dir}"

now=$(date +%s)
readonly now

# renew when missing, or within 2 minutes of expiry: a Session JWT must never be signed after
# its delegation's exp, and the Company checks exp when it receives the request
declare -i renew=${opt_new}
if [[ ! -s ${dlg_dir}/delegation.jwt || ! -s ${dlg_dir}/key.pem ]]; then
    renew=1
else
    exp=$(IFS=. read -r _ p _ <"${dlg_dir}/delegation.jwt"; b64url_decode "${p}" | jq -r .exp)
    (( exp - now < 120 )) && renew=1
fi

if [[ ${renew} -eq 1 ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${dlg_dir}/key.pem.new" 2>/dev/null

    cnf_jwk=$("${DIR}/jwt/jwk.sh" -f "${dlg_dir}/key.pem.new")
    root_kid=$("${DIR}/jwt/jwk.sh" -f "${AGENT_EC_KEY}" -t)

    header=$(jq -cn --arg kid "${root_kid}" '{alg: "ES256", typ: "poppy-delegation+jwt", kid: $kid}')
    claims=$(jq -cn \
        --arg iss "${CLIENT_ID}" \
        --argjson jwk "${cnf_jwk}" \
        --argjson iat "${now}" \
        --argjson exp "$((now + POPPY_DELEGATION_TTL))" \
        --arg jti "$(rand_id)" \
        '{iss: $iss, cnf: {jwk: $jwk}, iat: $iat, exp: $exp, jti: $jti}')

    "${DIR}/jwt/sign.sh" -f "${AGENT_EC_KEY}" -H "${header}" -P "${claims}" >"${dlg_dir}/delegation.jwt.new"
    mv "${dlg_dir}/key.pem.new" "${dlg_dir}/key.pem"
    mv "${dlg_dir}/delegation.jwt.new" "${dlg_dir}/delegation.jwt"
    [[ ${opt_verbose} -eq 1 ]] && echo >&2 "issued a new delegation, valid for ${POPPY_DELEGATION_TTL}s"
fi

[[ ${opt_verbose} -eq 1 ]] && "${DIR}/jwt/decode.sh" "$(cat "${dlg_dir}/delegation.jwt")" >&2

echo "${dlg_dir}"
