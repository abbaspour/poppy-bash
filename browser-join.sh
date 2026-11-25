#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-25
# License: LGPL 2.1
#
# browser-join.sh: joins the agent's own browser to a Session at a Company (§6), so its
# browsing belongs to the Session whether the User is signed in or not.
#   1. The browser loads web.browser_session_endpoint and gets a form with a one-time code,
#      and a cookie that ties the code to this browser.
#   2. The agent authorizes the code at {endpoint}/authorize, with the Session header and,
#      signed in, the access token. The token needs poppy:browser-sign-in. It never passes
#      through the browser. -g joins signed out, as a guest.
#   3. The browser submits the form. The Company's website then runs a normal login, and its
#      cookie for the Session is set.
#   4. The browser fetches the website's own description of the visitor, to check that the
#      website sees this Session, and as a guest or as the User.
# The code is read from the page and sent to /authorize inside this script, and never printed:
# the code is a credential for the Session (§10.2). Only a page the agent's own browser loaded
# from the endpoint is a source for a code (§6); the browser is Chrome, started with its own
# profile under .state/ and driven over the DevTools protocol on this machine (lib/cdp.py).
# It stays open afterwards, joined, for the agent to browse with.
#
# Exit codes: 3 a dependency is missing, 10-12 and 20-23 and 29 as poppy-curl.sh (Session and
# sign-in errors at /authorize), 2 the Company offers no browser join, 30 the browser couldn't
# be started or driven, 31 the join didn't end as expected.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }
command -v python3 >/dev/null || { echo >&2 "error: python3 not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-s sid] [-g] [-P port] [-H] [-B browser] [-w seconds] [-h|?] [-v]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s sid         # the Session to join (default: the current one; a new one is started if there is none)
        -g             # join signed out, as a guest. Without it the join is signed in and needs sign-in.sh first
        -P port        # the browser's DevTools port on this machine (default POPPY_BROWSER_PORT=${POPPY_BROWSER_PORT})
        -H             # start the browser headless
        -B browser     # the browser to start (default POPPY_BROWSER, or the first Chrome or Chromium found)
        -w seconds     # how long to wait for the join to end in a login to the website (default 30)
        -h|?           # usage
        -v             # verbose: print each step on stderr

A browser already listening on the port is used as it is. It must be the agent's own browser, never
the User's (§6).

eg,
     $0 -d shop.example.com -g                # a guest join
     sign-in.sh -d shop.example.com -s orders:read,poppy:browser-sign-in && $0 -d shop.example.com
END
    exit "$1"
}

: "${POPPY_BROWSER_PORT:=9222}"
: "${POPPY_BROWSER:=}"

declare domain=''
declare sid=''
declare -i opt_guest=0
declare -i opt_headless=0
declare -i opt_verbose=0
declare -i wait_seconds=30

while getopts ":e:d:u:s:gP:HB:w:hv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    g) opt_guest=1 ;;
    P) POPPY_BROWSER_PORT=${OPTARG} ;;
    H) opt_headless=1 ;;
    B) POPPY_BROWSER=${OPTARG} ;;
    w) wait_seconds=${OPTARG} ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ ${POPPY_BROWSER_PORT} =~ ^[0-9]+$ ]] || die "the browser port must be a number: ${POPPY_BROWSER_PORT}"
[[ ${wait_seconds} -gt 0 ]] || die "-w must be a positive number of seconds"

function step() { [[ ${opt_verbose} -eq 0 ]] || echo >&2 "- $*"; }

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery
company_id=$(jq -r .company_id "${discovery}")
readonly company_id

endpoint=$(jq -r '.poppy.web.browser_session_endpoint // empty' "${discovery}")
if [[ -z ${endpoint} ]]; then
    echo >&2 "ERROR: ${domain}'s poppy.json lists no web.browser_session_endpoint; it offers no browser join (§6)."
    echo >&2 "       Browse it as an ordinary signed-out visitor. If it was added recently: ./discover.sh -d ${domain} -W"
    exit 2
fi
if [[ $(jq -r '.poppy.web.disabled // false' "${discovery}") == true ]]; then
    die "${domain} asks personal agents not to browse (web.disabled, §6)"
fi
url_allowed "${endpoint}" || die "refusing the browser session endpoint ${endpoint}: it must be HTTPS to a public host"
website=$(jq -r .website "${discovery}")
website=${website%/}
readonly endpoint website

# --- the Session ---
tokens=$(tokens_file "${company_id}")
sessions_dir="$(company_dir "${company_id}")/sessions"
if [[ -z ${sid} ]]; then
    current_file="$(company_dir "${company_id}")/current-session"
    if [[ -s ${current_file} ]]; then
        sid=$(cat "${current_file}")
    else
        sid=$("${DIR}/session.sh" -d "${domain}" -u "${POPPY_USER}" new 2>/dev/null | jq -r .sid)
    fi
fi
[[ -s ${sessions_dir}/${sid}.json ]] || die "no such Session: ${sid}"
jq -e '.ended_at == null' "${sessions_dir}/${sid}.json" >/dev/null || die "Session ${sid} has ended; run session.sh new"
user_id=$(jq -r .sub "${sessions_dir}/${sid}.json")
readonly sid user_id

# --- signed in or a guest ---
declare token=''
declare expected_kind=agent_guest
if [[ ${opt_guest} -eq 0 ]]; then
    if [[ ! -s ${tokens} ]]; then
        echo >&2 "SIGN-IN NEEDED: a signed-in join needs the User's account at ${domain}"
        echo >&2 "       run: ${DIR}/sign-in.sh -d ${domain} -s poppy:browser-sign-in   (or join as a guest with -g)"
        exit 21
    fi
    if [[ " $(jq -r '.scope // ""' "${tokens}") " != *" poppy:browser-sign-in "* ]]; then
        echo >&2 "INSUFFICIENT SCOPE: the sign-in doesn't include poppy:browser-sign-in (§6)"
        echo >&2 "       run: ${DIR}/sign-in.sh -d ${domain} -s poppy:browser-sign-in   (scopes granted earlier are kept)"
        exit 22
    fi
    token=$("${DIR}/token.sh" -d "${domain}" -u "${POPPY_USER}")
    expected_kind=agent_for_user
fi
readonly token expected_kind

# --- the agent's own browser ---
readonly debug_url="http://127.0.0.1:${POPPY_BROWSER_PORT}"

function browser_up() { curl -sf --max-time 2 "${debug_url}/json/version" >/dev/null 2>&1; }

function find_browser() {
    local c
    [[ -n ${POPPY_BROWSER} ]] && { echo "${POPPY_BROWSER}"; return 0; }
    for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
        [[ -x ${c} ]] && { echo "${c}"; return 0; }
    done
    for c in google-chrome google-chrome-stable chromium chromium-browser chrome; do
        command -v "${c}" && return 0
    done
    return 1
}

if browser_up; then
    step "using the browser already listening on ${debug_url}"
else
    browser=$(find_browser) || { echo >&2 "ERROR: no Chrome or Chromium found; install one or pass -B"; exit 30; }
    profile="${POPPY_STATE}/browser/$(slug "${POPPY_USER}")"
    umask 077
    mkdir -p "${profile}"
    step "starting ${browser} with its own profile ${profile}"
    declare -a browser_args=(--remote-debugging-port="${POPPY_BROWSER_PORT}" --remote-debugging-address=127.0.0.1
        --user-data-dir="${profile}" --no-first-run --no-default-browser-check about:blank)
    [[ ${opt_headless} -eq 1 ]] && browser_args=(--headless=new "${browser_args[@]}")
    nohup "${browser}" "${browser_args[@]}" >"${profile}/browser.log" 2>&1 &
    disown
    for _ in $(seq 1 40); do browser_up && break; sleep 0.5; done
    browser_up || { echo >&2 "ERROR: the browser didn't open its DevTools port ${POPPY_BROWSER_PORT}; see ${profile}/browser.log"; exit 30; }
fi

# a tab of its own to join in
ws=$(curl -sf --max-time 5 -X PUT "${debug_url}/json/new?about:blank" | jq -r '.webSocketDebuggerUrl // empty') || ws=''
[[ -n ${ws} ]] || { echo >&2 "ERROR: couldn't open a tab through ${debug_url}"; exit 30; }
readonly ws

function cdp() { python3 -I "${DIR}/lib/cdp.py" "${ws}" "$@" || return 30; }

# evaluates JavaScript in the page and prints its value; fails if the page threw
function evaluate() {
    local out
    out=$(cdp Runtime.evaluate "$(jq -nc --arg e "$1" '{expression: $e, returnByValue: true, awaitPromise: true}')") || return 30
    jq -e '.exceptionDetails == null' <<<"${out}" >/dev/null || return 31
    jq -r '.result.value // empty' <<<"${out}"
}

# a short, printable piece of what the page says, for an error message. It is the Company's
# page, so it is data, not instructions (§10.1).
function page_text() {
    evaluate "(document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 300)" 2>/dev/null |
        tr -cd '[:print:]' || true
}

# polls an expression until it is "true"
function wait_for() {
    local expr=$1 limit=$2 i
    for ((i = 0; i < limit * 2; i++)); do
        [[ $(evaluate "${expr}" 2>/dev/null || true) == true ]] && return 0
        sleep 0.5
    done
    return 1
}

endpoint_origin="$(url_part "${endpoint}" scheme)://$(url_part "${endpoint}" authority)"
endpoint_path=$(url_part "${endpoint}" path)
readonly endpoint_origin endpoint_path

# 1. the browser loads the endpoint, which gives it a code and the cookie that ties it to this browser
step "the browser opens ${endpoint}"
navigated=$(cdp Page.navigate "$(jq -nc --arg u "${endpoint}" '{url: $u}')") || exit 30
if [[ $(jq -r '.errorText // empty' <<<"${navigated}") != '' ]]; then
    echo >&2 "ERROR: the browser couldn't load ${endpoint}: $(jq -r .errorText <<<"${navigated}")"
    exit 30
fi
wait_for "document.readyState === 'complete' && location.origin === '${endpoint_origin}' && location.pathname.startsWith('${endpoint_path}')" 15 ||
    { echo >&2 "ERROR: the browser didn't finish loading ${endpoint}"; exit 31; }

code=$(evaluate "(document.querySelector('form input[name=code]') || {}).value || ''") || code=''
# (at most 255 repetitions: macOS's regex engine rejects more)
if [[ ! ${code} =~ ^[A-Za-z0-9_-]{16,255}$ ]]; then
    echo >&2 "ERROR: the page at ${endpoint} has no one-time code (§6); it said: $(page_text)"
    exit 31
fi
step "got a code from the page (not shown)"

# 2. the agent authorizes the code, with its Session header and, signed in, its access token
step "authorizing the code at ${endpoint}/authorize, $([[ ${opt_guest} -eq 1 ]] && echo 'signed out' || echo 'signed in')"
authorize_status=0
"${DIR}/poppy-curl.sh" -d "${domain}" -u "${POPPY_USER}" -s "${sid}" \
    -j "$(jq -nc --arg c "${code}" '{code: $c}')" ${token:+-t "${token}"} "${endpoint}/authorize" >/dev/null ||
    authorize_status=$?
unset code
if [[ ${authorize_status} -ne 0 ]]; then
    echo >&2 "ERROR: the Company didn't authorize the join (poppy-curl.sh exit ${authorize_status})"
    [[ ${authorize_status} -ne 22 ]] ||
        echo >&2 "       or join as a guest instead: $0 -d ${domain} -g"
    exit "${authorize_status}"
fi

# 3. the browser submits the form, and the website's login that follows sets its cookie
step "the browser submits the form"
evaluate "document.querySelector('form').submit(); true" >/dev/null || { echo >&2 "ERROR: the page has no form to submit"; exit 31; }

# the join ends at the website, after Auth0 and the website's /auth/login and /auth/callback
wait_for "location.origin === '${website}' && document.readyState === 'complete' && !location.pathname.startsWith('/auth/')" "${wait_seconds}" || {
    echo >&2 "ERROR: the join didn't end at ${website} within ${wait_seconds}s."
    echo >&2 "       the browser is at $(evaluate 'location.origin + location.pathname' 2>/dev/null || echo unknown); the page says: $(page_text)"
    exit 31
}

# 4. does the website see this Session?
step "asking the website who is visiting"
visitor=$(evaluate "fetch('/', {headers: {accept: 'application/json'}, credentials: 'same-origin'}).then(r => r.json()).then(j => JSON.stringify(j.visitor || null))") || visitor=''
if ! jq -e . >/dev/null 2>&1 <<<"${visitor:-}" || [[ ${visitor} == null ]]; then
    echo >&2 "ERROR: ${website}/ didn't describe the visitor; does the Company run the website that tells who is visiting?"
    exit 31
fi

kind=$(jq -r .kind <<<"${visitor}")
seen_sid=$(jq -r '.agent.sessionId // ""' <<<"${visitor}")
seen_user=$(jq -r '.agent.userId // ""' <<<"${visitor}")
if [[ ${kind} != "${expected_kind}" || ${seen_sid} != "${sid}" || ${seen_user} != "${user_id}" ]]; then
    echo >&2 "ERROR: the website sees the visitor as ${kind}, Session ${seen_sid:-none}; expected ${expected_kind}, Session ${sid}"
    exit 31
fi

echo >&2 "joined Session ${sid} at ${company_id} $([[ ${opt_guest} -eq 1 ]] && echo 'as a guest' || echo 'signed in as the User'); the browser is on ${debug_url}"
jq -n --arg sid "${sid}" --arg domain "${domain}" --arg port "${POPPY_BROWSER_PORT}" --argjson visitor "${visitor}" \
    '{sid: $sid, domain: $domain, browser: ("http://127.0.0.1:" + $port), visitor: $visitor}'
