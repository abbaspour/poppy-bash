#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# callback.sh: the redirect_uri of Direct Sign-In (§4.2), run by web/server.sh as CGI for
# /callback. It saves the authorization response (code, state, iss, or error) under
# .state/callbacks/<state>.json, where sign-in.sh is waiting for it, and tells the User to go
# back to the terminal. It doesn't exchange the code or judge the response: sign-in.sh checks
# state and iss before using it.
##########################################################################################

set -uo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../../../lib/common.sh
. "${DIR}/../../../lib/common.sh"

readonly MAX_QUERY_LEN=8192

# decodes only %XX triples and +, without interpreting backslash escapes
function url_decode() {
    local data="${1//+/ }"
    data="${data//\\/\\\\}"
    printf '%b' "${data//%/\\x}"
}

function html_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    printf '%s' "${s}"
}

function page() {
    local status=$1 title=$2 message=$3
    printf 'Status: %s\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\r\n' "${status}"
    printf '<!doctype html><meta charset="utf-8"><title>%s</title><body style="font-family:system-ui;margin:3em">' "${title}"
    printf '<h1>%s</h1><p>%s</p></body>\n' "${title}" "${message}"
}

declare query=${QUERY_STRING:-}
[[ ${REQUEST_METHOD:-GET} == POST ]] && query=$(head -c "${MAX_QUERY_LEN}")
query=${query:0:${MAX_QUERY_LEN}}

declare -A params=()
IFS='&' read -r -a pairs <<<"${query}"
for pair in "${pairs[@]}"; do
    name=${pair%%=*}
    [[ ${name} =~ ^(code|state|iss|error|error_description)$ ]] || continue
    params[${name}]=$(url_decode "${pair#*=}" | tr -d '[:cntrl:]')
done

readonly state=${params[state]:-}
# the state names the file, so it must be one sign-in.sh made: an ID, nothing that walks paths
if [[ ! ${state} =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
    page "400 Bad Request" "Sign-in failed" "The response has no valid state, so it isn't one this agent started."
    exit 0
fi

umask 077
mkdir -p "${POPPY_STATE}/callbacks"
jq -n \
    --arg code "${params[code]:-}" \
    --arg state "${state}" \
    --arg iss "${params[iss]:-}" \
    --arg error "${params[error]:-}" \
    --arg error_description "${params[error_description]:-}" \
    --arg received_at "$(iso_now)" \
    '{code: $code, state: $state, iss: $iss, error: $error, error_description: $error_description, received_at: $received_at}
     | with_entries(select(.value != ""))' >"${POPPY_STATE}/callbacks/${state}.json.tmp" &&
    mv "${POPPY_STATE}/callbacks/${state}.json.tmp" "${POPPY_STATE}/callbacks/${state}.json"

echo >&2 "callback: received the authorization response for state ${state:0:8}..."

if [[ -n ${params[error]:-} ]]; then
    page "200 OK" "Sign-in didn't complete" "The Company answered: $(html_escape "${params[error]}"). You can close this tab and go back to the terminal."
else
    page "200 OK" "Signed in" "You can close this tab and go back to the terminal; the agent is finishing sign-in."
fi
