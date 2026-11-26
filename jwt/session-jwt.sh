#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# session-jwt.sh: signs the Session JWT for one request (section 5.2), the value of Poppy-Session.
#   header  {typ: poppy-session+jwt, alg: ES256, kid: <delegated key thumbprint>, poppy_dlg}
#   claims  {iss, aud, sid, sub, [agent_id], htm, htu, iat, jti, [ath]}
# htu is the request URL without query or fragment. ath, the hash of the access token, is
# present only on signed-in requests. This is a low-level signer: poppy-curl.sh fills in the
# identity from the Session and the delegation from delegation.sh.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../lib/common.sh
. "${DIR}/../lib/common.sh"

command -v openssl >/dev/null || { echo >&2 "error: openssl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 -i iss -a aud -s sid -S sub [-g agent_id] -m method -u url [-t access_token] -k key.pem -D delegation.jwt
        -i iss         # the Personal Agent's client_id
        -a aud         # the Company identifier: issuer, or https://{organization.domain}
        -s sid         # Session ID
        -S sub         # User ID at this Company
        -g agent_id    # optional Agent ID
        -m method      # request method (htm)
        -u url         # request URL (htu is derived from it)
        -t token       # access token, for signed-in requests (adds ath)
        -k key.pem     # delegated private key
        -D file        # file with the delegation JWT for that key
        -h|?           # usage

eg,
     $0 -i https://agent.example/cimd.json -a https://auth.example.com/ -s Yx2b7Qd -S usr_Q7c1vK \\
        -m GET -u https://api.example.com/orders -k key.pem -D delegation.jwt
END
    exit "$1"
}

declare iss='' aud='' sid='' sub='' agent_id='' method='' url='' token='' key='' dlg_file=''

while getopts ":i:a:s:S:g:m:u:t:k:D:h" opt; do
    case ${opt} in
    i) iss=${OPTARG} ;;
    a) aud=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    S) sub=${OPTARG} ;;
    g) agent_id=${OPTARG} ;;
    m) method=${OPTARG} ;;
    u) url=${OPTARG} ;;
    t) token=${OPTARG} ;;
    k) key=${OPTARG} ;;
    D) dlg_file=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

for v in iss aud sid sub method url; do
    [[ -n ${!v} ]] || { echo >&2 "ERROR: ${v} undefined"; usage 1; }
done
[[ -f "${key}" ]] || { echo >&2 "ERROR: key file missing: ${key}"; usage 1; }
[[ -s "${dlg_file}" ]] || { echo >&2 "ERROR: delegation file missing: ${dlg_file}"; usage 1; }

delegation=$(cat "${dlg_file}")
readonly delegation
kid=$("${DIR}/jwk.sh" -f "${key}" -t)
readonly kid
htu=$(url_htu "${url}") || die "can't parse URL: ${url}"
readonly htu

declare ath=''
[[ -n ${token} ]] && ath=$(printf '%s' "${token}" | openssl dgst -sha256 -binary | b64url)
readonly ath

header=$(jq -cn --arg kid "${kid}" --arg dlg "${delegation}" \
    '{typ: "poppy-session+jwt", alg: "ES256", kid: $kid, poppy_dlg: $dlg}')
readonly header

claims=$(jq -cn \
    --arg iss "${iss}" \
    --arg aud "${aud}" \
    --arg sid "${sid}" \
    --arg sub "${sub}" \
    --arg agent_id "${agent_id}" \
    --arg htm "${method^^}" \
    --arg htu "${htu}" \
    --argjson iat "$(date +%s)" \
    --arg jti "$(rand_id)" \
    --arg ath "${ath}" \
    '{iss: $iss, aud: $aud, sid: $sid, sub: $sub}
     + (if $agent_id != "" then {agent_id: $agent_id} else {} end)
     + {htm: $htm, htu: $htu, iat: $iat, jti: $jti}
     + (if $ath != "" then {ath: $ath} else {} end)')
readonly claims

"${DIR}/sign.sh" -f "${key}" -H "${header}" -P "${claims}"
