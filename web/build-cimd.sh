#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# build-cimd.sh: writes the Personal Agent's client metadata document (section 4.1, CIMD draft).
# Its client_id is the URL it is served from, and jwks_uri and redirect_uris are on the
# same host, so everything comes from AGENT_BASE_URL.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../lib/common.sh
. "${DIR}/../lib/common.sh"

command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

declare client_name="${AGENT_NAME:-poppy-bash}"
declare output="${DIR}/public/cimd.json"

function usage() {
    cat <<END >&2
USAGE: $0 [-b base_url] [-n name] [-o output] [-h|?]
        -b base_url    # public base URL of web/public (default AGENT_BASE_URL=${AGENT_BASE_URL})
        -n name        # client_name (default ${client_name})
        -o output      # output file (default ${output})
        -h|?           # usage

eg,
     $0 -b https://agent.example.dev
END
    exit "$1"
}

while getopts ":b:n:o:h" opt; do
    case ${opt} in
    b) AGENT_BASE_URL=${OPTARG} ;;
    n) client_name=${OPTARG} ;;
    o) output=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -z "${AGENT_BASE_URL}" ]] && { echo >&2 "ERROR: AGENT_BASE_URL undefined"; usage 1; }
AGENT_BASE_URL=${AGENT_BASE_URL%/}
url_allowed "${AGENT_BASE_URL}/" || die "AGENT_BASE_URL must be HTTPS: ${AGENT_BASE_URL}"

declare auth_method=private_key_jwt

jq -n \
    --arg client_id "${AGENT_BASE_URL}/cimd.json" \
    --arg client_name "${client_name}" \
    --arg jwks_uri "${AGENT_BASE_URL}/jwks.json" \
    --arg redirect_uri "${AGENT_BASE_URL}/callback" \
    --arg auth_method "${auth_method}" \
    '{
        client_id: $client_id,
        client_name: $client_name,
        jwks_uri: $jwks_uri,
        redirect_uris: [$redirect_uri],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: $auth_method,
        application_type: "web"
    }' >"${output}"

echo >&2 "wrote ${output} (client_id ${AGENT_BASE_URL}/cimd.json)"
