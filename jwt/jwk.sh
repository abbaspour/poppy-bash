#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# jwk.sh: prints the public JWK of an EC P-256 or RSA key PEM file, or its RFC 7638
# thumbprint. Poppy uses thumbprints as kid for jwks.json keys and delegated keys (section 5.2).
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../lib/common.sh
. "${DIR}/../lib/common.sh"

command -v openssl >/dev/null || { echo >&2 "error: openssl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }
command -v xxd >/dev/null || { echo >&2 "error: xxd not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 -f key.pem [-t] [-K] [-a alg] [-h|?]
        -f key.pem     # private or public key PEM (EC P-256 or RSA)
        -t             # print the RFC 7638 thumbprint instead of the JWK
        -K             # add kid (the thumbprint) to the JWK
        -a alg         # add alg to the JWK, eg. ES256, PS256
        -h|?           # usage

eg,
     $0 -f keys/agent-ec-private.pem -K -a ES256
     $0 -f keys/agent-ec-private.pem -t
END
    exit "$1"
}

declare pem_file=''
declare alg=''
declare -i opt_thumbprint=0
declare -i opt_kid=0

while getopts ":f:a:tKh" opt; do
    case ${opt} in
    f) pem_file=${OPTARG} ;;
    a) alg=${OPTARG} ;;
    t) opt_thumbprint=1 ;;
    K) opt_kid=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -z "${pem_file}" ]] && { echo >&2 "ERROR: key file undefined"; usage 1; }
[[ -f "${pem_file}" ]] || { echo >&2 "ERROR: key file missing: ${pem_file}"; usage 1; }

# accept private or public PEM
declare pubin=''
grep -q 'PUBLIC KEY' "${pem_file}" && pubin='-pubin'

function hex_to_b64url() { xxd -r -p | b64url; }

declare required=''
if openssl pkey ${pubin} -in "${pem_file}" -noout -text 2>/dev/null | grep -q 'ASN1 OID: prime256v1\|NIST CURVE: P-256'; then
    # uncompressed point: 04 || x || y
    point=$(openssl pkey ${pubin} -in "${pem_file}" -pubout -outform DER 2>/dev/null | tail -c 65 | xxd -p | tr -d '\n')
    x=$(echo "${point:2:64}" | hex_to_b64url)
    y=$(echo "${point:66:64}" | hex_to_b64url)
    required=$(jq -cn --arg x "${x}" --arg y "${y}" '{crv:"P-256",kty:"EC",x:$x,y:$y}')
elif openssl pkey ${pubin} -in "${pem_file}" -noout -text 2>/dev/null | grep -q 'Modulus\|modulus'; then
    n=$(openssl rsa ${pubin} -in "${pem_file}" -noout -modulus 2>/dev/null | cut -d= -f2 | hex_to_b64url)
    e_dec=$(openssl rsa ${pubin} -in "${pem_file}" -noout -text 2>/dev/null | grep -i 'exponent' | head -1 | awk '{print $2}')
    e_hex=$(printf '%x' "${e_dec}")
    (( ${#e_hex} % 2 )) && e_hex="0${e_hex}"
    e=$(echo "${e_hex}" | hex_to_b64url)
    required=$(jq -cn --arg n "${n}" --arg e "${e}" '{e:$e,kty:"RSA",n:$n}')
else
    die "unsupported key type in ${pem_file}: need EC P-256 or RSA"
fi
readonly required

# RFC 7638: SHA-256 over the required members, sorted, with no whitespace (jq -cS)
thumbprint=$(printf '%s' "${required}" | jq -cS . | tr -d '\n' | openssl dgst -sha256 -binary | b64url)
readonly thumbprint

if [[ ${opt_thumbprint} -eq 1 ]]; then
    echo "${thumbprint}"
    exit 0
fi

declare kid=''
[[ ${opt_kid} -eq 1 ]] && kid=${thumbprint}

jq -c --arg kid "${kid}" --arg alg "${alg}" \
    '. + (if $kid != "" then {kid:$kid} else {} end) + (if $alg != "" then {alg:$alg, use:"sig"} else {} end)' \
    <<<"${required}"
