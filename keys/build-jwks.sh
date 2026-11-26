#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# build-jwks.sh: writes the public key set served at jwks_uri (section 4.1). It holds only public
# keys, each with kid = its RFC 7638 thumbprint. The EC key is listed as ES256 and the RSA
# key with CLIENT_ASSERTION_ALG when that is an RSA algorithm (default PS256).
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../lib/common.sh
. "${DIR}/../lib/common.sh"

command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

declare output="${POPPY_HOME}/web/public/jwks.json"

function usage() {
    cat <<END >&2
USAGE: $0 [-o output] [-h|?]
        -o output      # output file (default ${output})
        -h|?           # usage

eg,
     $0
END
    exit "$1"
}

while getopts ":o:h" opt; do
    case ${opt} in
    o) output=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -f "${AGENT_EC_KEY}" ]] || die "missing ${AGENT_EC_KEY}; run keys/gen-keys.sh"

declare rsa_alg=PS256
[[ ${CLIENT_ASSERTION_ALG} =~ ^(RS|PS) ]] && rsa_alg=${CLIENT_ASSERTION_ALG}
readonly rsa_alg

declare -a keys=()
keys+=("$("${DIR}/../jwt/jwk.sh" -f "${AGENT_EC_KEY}" -K -a ES256)")
[[ -f "${AGENT_RSA_KEY}" ]] && keys+=("$("${DIR}/../jwt/jwk.sh" -f "${AGENT_RSA_KEY}" -K -a "${rsa_alg}")")

mkdir -p "${output%/*}"
printf '%s\n' "${keys[@]}" | jq -s '{keys: .}' >"${output}"
echo >&2 "wrote ${output}"
