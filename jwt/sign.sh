#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# sign.sh: signs a JWT from a header and a payload JSON with openssl. Supports ES256 (P-256,
# raw r||s signature as RFC 7518 section 3.4 requires), RS256, PS256 and PS384. Every Poppy JWT goes
# through this: delegations, Session JWTs and client assertions.
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
USAGE: $0 -f key.pem -H header_json -P payload_json [-h|?]
        -f key.pem     # private key PEM
        -H json        # protected header; must include alg
        -P json        # claims
        -h|?           # usage

eg,
     $0 -f keys/agent-ec-private.pem -H '{"alg":"ES256","typ":"JWT"}' -P '{"iss":"me"}'
END
    exit "$1"
}

declare pem_file=''
declare header=''
declare payload=''

while getopts ":f:H:P:h" opt; do
    case ${opt} in
    f) pem_file=${OPTARG} ;;
    H) header=${OPTARG} ;;
    P) payload=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -f "${pem_file}" ]] || { echo >&2 "ERROR: key file missing: ${pem_file}"; usage 1; }
[[ -z "${header}" ]] && { echo >&2 "ERROR: header undefined"; usage 1; }
[[ -z "${payload}" ]] && { echo >&2 "ERROR: payload undefined"; usage 1; }

alg=$(jq -er '.alg' <<<"${header}") || die "header has no alg"
readonly alg

signing_input="$(jq -c . <<<"${header}" | tr -d '\n' | b64url).$(jq -c . <<<"${payload}" | tr -d '\n' | b64url)"
readonly signing_input

declare signature=''
case ${alg} in
ES256)
    # openssl emits a DER SEQUENCE { r, s }; JWS wants r and s as fixed 32-byte big-endian values
    ints=$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${pem_file}" -binary |
        openssl asn1parse -inform DER | awk '/INTEGER/ {print $NF}' | tr -d ':')
    r=$(sed -n 1p <<<"${ints}")
    s=$(sed -n 2p <<<"${ints}")
    r=$(printf '%064s' "${r: -64}" | tr ' ' 0)
    s=$(printf '%064s' "${s: -64}" | tr ' ' 0)
    signature=$(printf '%s%s' "${r}" "${s}" | xxd -r -p | b64url)
    ;;
RS256)
    signature=$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${pem_file}" -binary | b64url) ;;
PS256 | PS384)
    signature=$(printf '%s' "${signing_input}" | openssl dgst "-sha${alg:2}" -sign "${pem_file}" \
        -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:digest -binary | b64url) ;;
*) die "unsupported alg: ${alg}" ;;
esac
readonly signature

echo "${signing_input}.${signature}"
