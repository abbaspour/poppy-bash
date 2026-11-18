#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# poppy-curl.sh: sends one request to a Company the way §5 requires:
#   Poppy-Session      a Session JWT signed for this method and URL (§5.2)
#   Poppy-Version      the version pinned for the Session (§3.4)
#   Poppy-Extensions   when the Session uses extensions (§3.4)
#   Authorization      only with -t, signed in; the Session JWT's ath covers the token (§4.5)
# It sends the header only to the Session destinations poppy.json lists, or signed out to
# website pages on organization.domain (§5.2), never follows redirects (§3), and explains
# the protocol errors of §7:
#   exit 10 invalid_session      fix the cause; a new Session doesn't help
#   exit 11 session_ended        after starting a new Session and retrying once (§5.5)
#   exit 12 version_unsupported  after rediscovering and retrying once if the version changed (§3.4)
#   exit 20 401 invalid_token    refresh the access token, or continue signed out (§5.5)
#   exit 21 401 sign-in needed   the challenge's scope says which scopes
#   exit 22 403 insufficient_scope
#   exit 23 403 extension_required
#   exit 29 429 rate limited     wait Retry-After before sending it again (§5.6)
#   exit 4  any other HTTP error
# The response body goes to stdout.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-s sid] [-X method] [-H header]... [-j json] [-t token] [-i] [-h|?] [-v] url
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s sid         # Session (default: the current one; a new one is started if there is none)
        -X method      # HTTP method (default GET, or POST with -j)
        -H header      # extra request header (repeatable)
        -j json        # JSON request body
        -t token       # access token: send the request signed in
        -i             # print response status and headers on stderr
        -h|?           # usage
        -v             # verbose: print the request headers and decoded Session JWT on stderr

eg,
     $0 -d shop.example.com https://shop.example.com/api/products
     $0 -X POST -j '{"sku":"tee-m"}' https://shop.example.com/api/cart/items
END
    exit "$1"
}

declare domain=''
declare sid=''
declare method=''
declare body=''
declare token=''
declare -a extra_headers=()
declare -i opt_include=0
declare -i opt_verbose=0

while getopts ":e:d:u:s:X:H:j:t:ihv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    X) method=${OPTARG^^} ;;
    H) extra_headers+=(-H "${OPTARG}") ;;
    j) body=${OPTARG} ;;
    t) token=${OPTARG} ;;
    i) opt_include=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 1 ]] || { echo >&2 "ERROR: url undefined"; usage 1; }
readonly url=$1
[[ -z ${method} ]] && { if [[ -n ${body} ]]; then method=POST; else method=GET; fi; }
readonly method
[[ -z "${CLIENT_ID}" ]] && { echo >&2 "ERROR: CLIENT_ID undefined; set AGENT_BASE_URL in .env"; usage 1; }

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery

url_allowed "${url}" || die "refusing URL (must be HTTPS to a public host): ${url}"
htu=$(url_htu "${url}")
readonly htu

# --- §5.2: is this URL a Session destination? ---
# poppy.json's destinations, plus the feedback.endpoint from this Session's tasks response (§9.3)
function is_destination() {
    local d tasks_file sessions current
    while read -r d; do
        [[ ${htu} == "${d}" || ${htu} == "${d%/}/"* ]] && return 0
    done < <(jq -r '.destinations[]' "${discovery}")
    sessions="$(company_dir "$(jq -r .company_id "${discovery}")")"
    current=${sid}
    [[ -z ${current} && -s ${sessions}/current-session ]] && current=$(cat "${sessions}/current-session")
    tasks_file="${sessions}/sessions/${current}.tasks.json"
    [[ -n ${current} && -s ${tasks_file} ]] && [[ ${htu} == "$(jq -r '.feedback.endpoint // ""' "${tasks_file}")" ]]
}

if ! is_destination; then
    website=$(jq -r .website "${discovery}")
    if [[ ${htu} == "${website}"* && $(url_part "${url}" path) != /.well-known/* ]]; then
        # a website page fetched without a browser: Session header, but always signed out
        [[ -z ${token} ]] || die "website pages are always fetched signed out; drop -t (§5.2)"
    else
        die "${htu} isn't a Session destination in ${domain}'s poppy.json; not sending a Session JWT there (§5.2)"
    fi
fi

# --- the Session ---
company_id=$(jq -r .company_id "${discovery}")
readonly company_id
sessions_dir="$(company_dir "${company_id}")/sessions"
readonly sessions_dir

if [[ -z ${sid} ]]; then
    current_file="$(company_dir "${company_id}")/current-session"
    if [[ -s ${current_file} ]]; then
        sid=$(cat "${current_file}")
    else
        sid=$("${DIR}/session.sh" -d "${domain}" -u "${POPPY_USER}" new 2>/dev/null | jq -r .sid)
        echo >&2 "started a new Session ${sid}"
    fi
fi
readonly session_file="${sessions_dir}/${sid}.json"
[[ -s ${session_file} ]] || die "no such Session: ${sid}"
jq -e '.ended_at == null' "${session_file}" >/dev/null || die "Session ${sid} has ended; run session.sh new"

sub=$(jq -r .sub "${session_file}")
agent_id=$(jq -r '.agent_id // empty' "${session_file}")
poppy_version=$(jq -r .poppy_version "${session_file}")
poppy_extensions=$(jq -r '.poppy_extensions // empty' "${session_file}")
agent=$(jq -r '.agent // empty' "${session_file}")
readonly sub agent_id poppy_version poppy_extensions agent

dlg_dir=$("${DIR}/delegation.sh" -d "${domain}" -u "${POPPY_USER}")
readonly dlg_dir

session_jwt=$("${DIR}/jwt/session-jwt.sh" \
    -i "${CLIENT_ID}" -a "${company_id}" -s "${sid}" -S "${sub}" ${agent_id:+-g "${agent_id}"} \
    -m "${method}" -u "${url}" ${token:+-t "${token}"} \
    -k "${dlg_dir}/key.pem" -D "${dlg_dir}/delegation.jwt")
readonly session_jwt

declare -a headers=(-H "Poppy-Session: ${session_jwt}" -H "Poppy-Version: ${poppy_version}")
[[ -n ${poppy_extensions} ]] && headers+=(-H "Poppy-Extensions: ${poppy_extensions}")
[[ -n ${token} ]] && headers+=(-H "Authorization: Bearer ${token}")
[[ -n ${body} ]] && headers+=(-H "Content-Type: application/json" --data "${body}")

if [[ ${opt_verbose} -eq 1 ]]; then
    echo >&2 "> ${method} ${url}"
    echo >&2 "> Poppy-Version: ${poppy_version}${poppy_extensions:+  Poppy-Extensions: ${poppy_extensions}}"
    [[ -n ${token} ]] && echo >&2 "> Authorization: Bearer ${token:0:12}..."
    "${DIR}/jwt/decode.sh" "${session_jwt}" | jq -c '{header: (.header | .poppy_dlg = "…"), payload}' >&2
fi

resp_headers=$(mktemp)
resp_body=$(mktemp)
readonly resp_headers resp_body
trap 'rm -f "${resp_headers}" "${resp_body}"' EXIT

status=$(curl -sS --proto "$(curl_protos)" --max-time 60 -X "${method}" \
    -H 'Accept: application/json' "${headers[@]}" "${extra_headers[@]}" \
    -D "${resp_headers}" -o "${resp_body}" -w '%{http_code}' --url "${url}" || echo 000)
readonly status

[[ ${opt_include} -eq 1 ]] && tr -d '\r' <"${resp_headers}" >&2

# print the body, pretty when it is JSON
if jq -e . "${resp_body}" >/dev/null 2>&1; then jq . "${resp_body}"; else cat "${resp_body}"; fi

function header_value() { tr -d '\r' <"${resp_headers}" | awk -v h="$1" 'tolower($0) ~ "^"tolower(h)":" {sub(/^[^:]*: */, ""); print}' | tail -1; }
function json_error() { jq -r '.error // empty' "${resp_body}" 2>/dev/null || true; }

# re-run this request once, in a new Session
function retry_in_new_session() {
    [[ -z ${POPPY_RETRIED:-} ]] || return 1
    new_sid=$("${DIR}/session.sh" -d "${domain}" -u "${POPPY_USER}" ${agent:+-A "${agent}"} new 2>/dev/null | jq -r .sid)
    echo >&2 "retrying once in new Session ${new_sid}"
    declare -a args=(-d "${domain}" -u "${POPPY_USER}" -s "${new_sid}" -X "${method}")
    [[ -n ${body} ]] && args+=(-j "${body}")
    [[ -n ${token} ]] && args+=(-t "${token}")
    [[ ${opt_include} -eq 1 ]] && args+=(-i)
    [[ ${opt_verbose} -eq 1 ]] && args+=(-v)
    POPPY_RETRIED=1 exec "${DIR}/poppy-curl.sh" "${args[@]}" "${extra_headers[@]}" "${url}"
}

case ${status} in
2??|3??)
    [[ ${status} == 3?? ]] && echo >&2 "note: HTTP ${status} redirect not followed (§3): $(header_value location)"
    exit 0 ;;
400)
    case $(json_error) in
    invalid_session)
        echo >&2 "ERROR: invalid_session: $(jq -r '.error_description // "Session verification failed"' "${resp_body}")"
        echo >&2 "       a new Session won't fix this; check the delegation, htu, clock and CIMD (§5.3)"
        exit 10 ;;
    session_ended)
        sessions_end=$("${DIR}/session.sh" -d "${domain}" -u "${POPPY_USER}" end "${sid}" 2>&1 || true)
        echo >&2 "Session ${sid} has ended at the Company. ${sessions_end}"
        retry_in_new_session || { echo >&2 "ERROR: session_ended again; stopping (§5.5)"; exit 11; } ;;
    version_unsupported)
        old=$(jq -r .version "${discovery}")
        new=$("${DIR}/discover.sh" -d "${domain}" -W -q -f .version | jq -r .)
        if [[ ${new} != "${old}" ]]; then
            echo >&2 "Company now serves version ${new} (was ${old})"
            retry_in_new_session || { echo >&2 "ERROR: version_unsupported again; stopping (§3.4)"; exit 12; }
        fi
        echo >&2 "ERROR: version_unsupported, and poppy.json still selects ${new} (§3.4)"
        exit 12 ;;
    *)
        echo >&2 "ERROR: HTTP 400 $(json_error)"
        exit 4 ;;
    esac ;;
401)
    challenge=$(header_value www-authenticate)
    if [[ ${challenge} == *invalid_token* ]]; then
        echo >&2 "ERROR: invalid_token: the access token is expired, revoked or invalid; refresh it (§7)"
        echo >&2 "       WWW-Authenticate: ${challenge}"
        exit 20
    else
        scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"${challenge}")
        echo >&2 "SIGN-IN NEEDED: this request needs the User's account${scope:+, with scope \"${scope}\"} (§7)"
        echo >&2 "       run: ${DIR}/sign-in.sh -d ${domain}${scope:+ -s ${scope// /,}}"
    fi
    echo >&2 "       WWW-Authenticate: ${challenge}"
    exit 21 ;;
403)
    if [[ $(json_error) == extension_required ]]; then
        echo >&2 "ERROR: extension_required: $(jq -r .extension "${resp_body}") (§3.3)"
        exit 23
    fi
    challenge=$(header_value www-authenticate)
    scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"${challenge}")
    echo >&2 "INSUFFICIENT SCOPE: needs \"${scope}\"; sign in again requesting it (§4.7)"
    echo >&2 "       run: ${DIR}/sign-in.sh -d ${domain} -s ${scope// /,}   (scopes granted earlier are kept)"
    exit 22 ;;
429)
    echo >&2 "RATE LIMITED: wait at least $(header_value retry-after)s before sending this again (§5.6)"
    exit 29 ;;
000)
    echo >&2 "ERROR: request failed (network)"
    exit 4 ;;
*)
    echo >&2 "ERROR: HTTP ${status} $(json_error)"
    exit 4 ;;
esac
