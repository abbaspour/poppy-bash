#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# api.sh: uses the APIs a Company lists in poppy.json (§7). Lists them, lists an OpenAPI
# API's operations with the scopes each needs, and calls an operation through poppy-curl.sh,
# so every call carries the Session header. Paths resolve against the description's first
# server URL.
#
# When the User is signed in at the Company, calls carry an access token from token.sh: the
# default token, or one for the API's own resource when its metadata asks for that (§4.5). An
# invalid_token is refreshed and retried once (§7). -o calls signed out.
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
USAGE: $0 [-e env] [-d domain] [-u user] [-n index] [-s sid] [-t token] [-o] [-h|?] [-v] command
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -n index       # which openapi entry of apis[] to use (default 0)
        -s sid         # Session (default: current)
        -t token       # use this access token (default: the signed-in User's, from token.sh)
        -o             # call signed out, even if the User is signed in
        -h|?           # usage
        -v             # verbose

commands:
        list                          # the APIs in poppy.json
        ops                           # the operations of the OpenAPI API, with their scopes
        call METHOD PATH [json_body]  # call an operation, eg. call GET /products

eg,
     $0 list
     $0 call GET /products
     $0 call POST /cart/items '{"sku":"tee-m","quantity":1}'
     $0 call GET /orders                  # signed in, once sign-in.sh has run
     $0 -o call GET /orders               # signed out: a 401 naming the scope it needs
END
    exit "$1"
}

declare domain=''
declare -i index=0
declare sid=''
declare token=''
declare -i opt_verbose=0
declare -i opt_signed_out=0

while getopts ":e:d:u:n:s:t:ohv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    n) index=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    t) token=${OPTARG} ;;
    o) opt_signed_out=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -ge 1 ]] || { echo >&2 "ERROR: command undefined"; usage 1; }
readonly command=$1
shift

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery

if [[ ${command} == list ]]; then
    jq -r '.poppy.apis // [] | to_entries[] | "\(.key)  \(.value.type)\t\(.value.url)\t\(.value.description // "")"' "${discovery}"
    exit 0
fi

api_url=$(jq -r --argjson i "${index}" '[.poppy.apis // [] | .[] | select(.type == "openapi")][$i].url // empty' "${discovery}")
[[ -n ${api_url} ]] || die "no openapi entry #${index} in ${domain}'s poppy.json"
readonly api_url
description="${POPPY_CACHE}/$(slug "${domain}")/openapi-$(slug "${api_url}").json"
readonly description
[[ -s ${description} ]] || die "OpenAPI description not cached; run: discover.sh -d ${domain} -W"

case ${command} in
ops)
    jq -r '
        (.security // []) as $default |
        (.components.securitySchemes // {}) as $schemes |
        .paths | to_entries[] | .key as $path | .value | to_entries[]
        | select(.key | test("^(get|put|post|delete|patch)$"))
        | (.value.security // $default) as $sec
        | "\(.key | ascii_upcase)\t\($path)\t\(.value.summary // .value.operationId // "")\t\(
            if ($sec | length) == 0 then "signed out"
            else "scopes: " + ([$sec[] | to_entries[] | .value[]] | unique | join(" ") | if . == "" then "(sign-in)" else . end)
            end)"' "${description}" | column -t -s $'\t'
    ;;
call)
    [[ $# -ge 2 ]] || { echo >&2 "ERROR: call needs METHOD and PATH"; usage 1; }
    method=${1^^}
    path=$2
    json=${3:-}
    origin="$(url_part "${api_url}" scheme)://$(url_part "${api_url}" authority)"
    server=$(jq -r '.servers[0].url // "/"' "${description}")
    [[ ${server} == /* ]] && server="${origin}${server}"
    url="${server%/}/${path#/}"

    # signed in when the User has tokens at this Company (§5.4), unless -o or -t
    declare -i auto_token=0
    if [[ -z ${token} && ${opt_signed_out} -eq 0 ]]; then
        company_id=$(jq -r .company_id "${discovery}")
        if [[ -s $(tokens_file "${company_id}") ]]; then
            auto_token=1
            resource=$(jq -r --arg s "${server%/}" '.resources[$s] // empty' "${discovery}")
            declare -a token_args=(-d "${domain}" -u "${POPPY_USER}")
            [[ -n ${resource} ]] && token_args+=(-R "${resource}")
            token=$("${DIR}/token.sh" "${token_args[@]}") || {
                rc=$?
                [[ ${rc} -eq 20 ]] || exit "${rc}"
                token=''    # signed out by the Company: continue signed out (§5.5)
            }
        fi
    fi

    function call() {
        declare -a args=(-d "${domain}" -u "${POPPY_USER}" -X "${method}")
        [[ -n ${sid} ]] && args+=(-s "${sid}")
        [[ -n ${token} ]] && args+=(-t "${token}")
        [[ -n ${json} ]] && args+=(-j "${json}")
        [[ ${opt_verbose} -eq 1 ]] && args+=(-v)
        "${DIR}/poppy-curl.sh" "${args[@]}" "${url}"
    }

    rc=0
    call || rc=$?
    # §7 invalid_token: refresh, and send the request again once
    if [[ ${rc} -eq 20 && ${auto_token} -eq 1 ]]; then
        echo >&2 "refreshing the access token and retrying once"
        token_args+=(-f)
        if token=$("${DIR}/token.sh" "${token_args[@]}"); then
            rc=0
            call || rc=$?
        fi
    fi
    exit "${rc}"
    ;;
*)
    echo >&2 "ERROR: unknown command: ${command}"
    usage 1
    ;;
esac
