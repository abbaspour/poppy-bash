#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# converse.sh: talks with the Company Agent over Personal Agent Protocol conversations (§8), at
# the endpoint of the `poppy` entry in agent.protocols. Every request carries the Session header,
# and an access token when the User is signed in (§8.2).
#
#   - Each POST has a request id, so sending it again is safe (§8.3). A request that fails with
#     invalid_token is refreshed and sent again with the same id.
#   - Events are read after the saved cursor, page by page while has_more, and an event id seen
#     before is skipped (§8.5). Unknown event types are skipped.
#   - author.type is agent for what this agent writes, and human only for the User's own words,
#     with -H (§8.8).
#   - With -J, new events are printed as JSON lines, then one `_status` line, so a program such as
#     chat.sh can react to them; the notes meant for a person stay on stderr.
#   - An `authorization` event means the Company Agent needs the account: sign in, then continue
#     the same conversation (§8.11). A `user_requested` event is an invitation to bring the User
#     into a Direct Conversation, which only this agent can start (§8.10).
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

declare -i wait_seconds=10

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-s sid] [-w seconds] [-H] [-o] [-E event_id] [-L locale] [-Z time_zone] [-U yes|no] [-j] [-J] [-h|?] command
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s sid         # Session (default: the current one)
        -w seconds     # how long the Company may hold a request for its reply (default ${wait_seconds})
        -H             # the text is the User's own words: author.type human (§8.8)
        -o             # signed out, even if the User is signed in
        -E event_id    # with direct: the user_requested event being accepted (§8.10)
        -L locale      # context.locale, eg. en-AU (§8.4)
        -Z time_zone   # context.time_zone, eg. Australia/Sydney
        -U yes|no      # context.user_available: can the User answer questions now
        -j             # print raw JSON responses
        -J             # print new events as JSON lines, then a {"type":"_status"} line (for chat.sh)
        -h|?           # usage

commands:
        start "text"                 start a conversation with its first message (§8.3)
        send <cid> "text"            send another message
        read <cid>                   read new events (with -w, wait for them)
        handoff <cid>                ask for a person at the Company (§8.9)
        cancel <cid>                 withdraw the request for a person
        close <cid>                  close the conversation (§8.12)
        direct <parent> ["text"]     start a Direct Conversation, with -E to accept the Company's
                                     user_requested event; the User then talks themselves (§8.10)
        list                         conversations at this Company

eg,
     $0 start "What products do you sell?"
     $0 send cnv_... "Where is my latest order?"
     $0 -E evt_7 direct cnv_...
     $0 -H send cnv_... "Yes, please cancel it"
END
    exit "$1"
}

declare domain=''
declare sid=''
declare event_id=''
declare -i opt_human=0
declare -i opt_signed_out=0
declare -i opt_json=0
declare -i opt_jsonl=0
declare -A context=()

while getopts ":e:d:u:s:w:E:L:Z:U:HojJh" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    w) wait_seconds=${OPTARG} ;;
    E) event_id=${OPTARG} ;;
    L) context[locale]=${OPTARG} ;;
    Z) context[time_zone]=${OPTARG} ;;
    U) case ${OPTARG} in yes) context[user_available]=true ;; no) context[user_available]=false ;;
       *) echo >&2 "ERROR: -U takes yes or no"; usage 1 ;; esac ;;
    H) opt_human=1 ;;
    o) opt_signed_out=1 ;;
    j) opt_json=1 ;;
    J) opt_jsonl=1 ;;
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

# §8.1: use the first protocol this agent supports, which is poppy
endpoint=$(jq -r '[.poppy.agent.protocols // [] | .[] | select(.type == "poppy")][0].endpoint // empty' "${discovery}")
readonly endpoint
[[ -n ${endpoint} ]] || die "${domain} lists no poppy conversation endpoint in agent.protocols (§8.1)"

company_id=$(jq -r .company_id "${discovery}")
dir=$(company_dir "${company_id}")
readonly company_id dir
readonly conversations="${dir}/conversations"
umask 077
mkdir -p "${conversations}"

# --- local state per conversation: cursor and the event ids already handled (§8.5) ---
function state_file() { echo "${conversations}/$1.json"; }

function load_state() {
    local f
    f=$(state_file "$1")
    if [[ -s ${f} ]]; then cat "${f}"; else jq -n --arg id "$1" '{conversation_id: $id, cursor: null, seen: []}'; fi
}

# --- account access: like api.sh, signed in when the User has tokens here (§8.11) ---
declare token=''
declare -i signed_in=0
if [[ ${opt_signed_out} -eq 0 && -s $(tokens_file "${company_id}") ]]; then
    signed_in=1
    resource=$(jq -r --arg e "${endpoint}" '.resources[$e] // empty' "${discovery}")
    token=$("${DIR}/token.sh" -d "${domain}" -u "${POPPY_USER}" ${resource:+-R "${resource}"}) || {
        rc=$?
        [[ ${rc} -eq 20 ]] || exit "${rc}"
        token=''
        signed_in=0
    }
fi

# poppy-curl.sh, with the Session, the token, and one refresh on invalid_token (§7); the request id
# in the body makes the retry safe (§8.3). Sets reply_body and last_rc: call it directly, not in
# $(...), whose subshell would lose them.
declare reply_body=''
declare -i last_rc=0
function request() {
    local method=$1 url=$2 body=${3:-}
    local -a args=(-d "${domain}" -u "${POPPY_USER}" -X "${method}")
    [[ -n ${sid} ]] && args+=(-s "${sid}")
    [[ -n ${body} ]] && args+=(-j "${body}")
    last_rc=0
    reply_body=$("${DIR}/poppy-curl.sh" "${args[@]}" ${token:+-t "${token}"} "${url}") || last_rc=$?
    if [[ ${last_rc} -eq 20 && ${signed_in} -eq 1 ]] && token=$("${DIR}/token.sh" -d "${domain}" -u "${POPPY_USER}" -f); then
        last_rc=0
        reply_body=$("${DIR}/poppy-curl.sh" "${args[@]}" -t "${token}" "${url}") || last_rc=$?
    fi
    return 0
}

# §8.13: conversation errors are JSON with an error code
function explain_error() {
    local body=$1
    case $(jq -r '.error // ""' <<<"${body}" 2>/dev/null) in
    conversation_not_found) echo >&2 "the conversation is unknown, or belongs to another agent, User or account (§8.2)" ;;
    conversation_closed) echo >&2 "the conversation is closed; start a new one (§8.12)" ;;
    direct_conversation_open)
        echo >&2 "a Direct Conversation is open: $(jq -r .conversation_id <<<"${body}"). Talk there, or close it (§8.10)" ;;
    request_id_conflict) echo >&2 "a request id was reused with another body (§8.3)" ;;
    cursor_expired) echo >&2 "the Company no longer has those events (§8.5)" ;;
    version_mismatch) echo >&2 "the conversation started in Poppy $(jq -r .protocol_version <<<"${body}") (§8.2)" ;;
    '') ;;
    *) echo >&2 "error: $(jq -r '"\(.error)\(if .error_description then ": " + .error_description else "" end)"' <<<"${body}")" ;;
    esac
}

# prints new events, and saves the cursor and the ids handled
function handle_read() {
    local cid=$1 body=$2 st
    st=$(load_state "${cid}")
    if [[ ${opt_json} -eq 1 ]]; then jq . <<<"${body}"; fi
    if [[ ${opt_jsonl} -eq 1 ]]; then
        jq -c --argjson seen "$(jq -c .seen <<<"${st}")" '.events[] | select(.id as $i | $seen | index($i) | not)' <<<"${body}"
        jq -c --arg cid "${cid}" '{type: "_status", conversation_id: $cid, working, handoff, responder, closed, has_more, cursor}' <<<"${body}"
    else
        print_events "${cid}" "${body}" "${st}"
    fi
    jq -n --argjson st "${st}" --argjson r "${body}" '
        $st + {cursor: ($r.cursor // $st.cursor), closed: $r.closed,
               seen: (($st.seen + [$r.events[].id]) | unique | .[-500:])}' >"$(state_file "${cid}")"
    [[ ${opt_jsonl} -eq 1 ]] ||
        jq -r 'if .working then "  (the Company is still replying; read again)"
               elif .handoff == "pending" then "  (looking for a person)" else empty end' <<<"${body}" >&2
}

# the new events as text for a person
function print_events() {
    local cid=$1 body=$2 st=$3
    jq -r --argjson seen "$(jq -c .seen <<<"${st}")" --arg cid "${cid}" --arg me "${DIR}" '
        .events[] | select(.id as $i | $seen | index($i) | not) |
        if .type == "message" then
            .message as $m |
            (if $m.role == "user" then "you (\($m.author.type))" else "company (\($m.author.type)\(if $m.author.name then ", " + $m.author.name else "" end))" end) as $who |
            if $m.text then "  \($who): \($m.text)"
            elif $m.context then "  \($who): [context] \($m.context | tojson)"
            else "  \($who): [data]" end,
            ($m.data // empty | "      data: \(tojson | if length > 300 then .[:300] + "…" else . end)")
        elif .type == "state" then "  [state] handoff=\(.handoff) responder=\(.responder) closed=\(.closed)"
        elif .type == "authorization" then
            "  [sign-in needed: \(.error), scope \"\(.scope)\"]",
            "      run: \($me)/sign-in.sh -s \(.scope | gsub(" "; ",")), then continue this conversation"
        elif .type == "user_requested" then
            "  [the Company asks to talk with the User: \(.reason)]",
            "      if the User agrees: \($me)/converse.sh -E \(.id) direct \($cid)"
        elif .type == "direct_opened" then "  [Direct Conversation opened: \(.conversation_id)]"
        elif .type == "direct_closed" then "  [Direct Conversation closed: \(.conversation_id)]"
        else empty end' <<<"${body}"
}

# reads events after the cursor until has_more is false (§8.5)
function read_events() {
    local cid=$1 wait=$2 st cursor body url
    while :; do
        st=$(load_state "${cid}")
        cursor=$(jq -r '.cursor // empty' <<<"${st}")
        url="${endpoint}/${cid}/events?wait=${wait}${cursor:+&cursor=${cursor}}"
        request GET "${url}"
        body=${reply_body}
        if [[ ${last_rc} -ne 0 ]]; then
            if [[ $(jq -r '.error // ""' <<<"${body}" 2>/dev/null) == cursor_expired ]]; then
                # read from the beginning; ids already handled are skipped
                jq '.cursor = null' <<<"${st}" >"$(state_file "${cid}")"
                continue
            fi
            explain_error "${body}"
            return 1
        fi
        handle_read "${cid}" "${body}"
        [[ $(jq -r .has_more <<<"${body}") == true ]] || return 0
        wait=0
    done
}

# a message as §8.4 defines it, with this agent's context facts
function message_json() {
    local text=$1 cid=${2:-} author=agent cursor=''
    [[ ${opt_human} -eq 1 ]] && author=human
    [[ -n ${cid} && ${author} == agent ]] && cursor=$(load_state "${cid}" | jq -r '.cursor // empty')
    local ctx='{}'
    for k in "${!context[@]}"; do
        if [[ ${k} == user_available ]]; then ctx=$(jq -c --arg k "${k}" --argjson v "${context[${k}]}" '.[$k] = $v' <<<"${ctx}")
        else ctx=$(jq -c --arg k "${k}" --arg v "${context[${k}]}" '.[$k] = $v' <<<"${ctx}"); fi
    done
    # as_of_cursor only on what the agent's AI writes, never the User's own words (§8.4)
    jq -cn --arg type "${author}" --arg text "${text}" --argjson ctx "${ctx}" --arg cursor "${cursor}" '
        {author: {type: $type}}
        + (if $text != "" then {text: $text} else {} end)
        + (if ($ctx | length) > 0 then {context: $ctx} else {} end)
        + (if $cursor != "" then {as_of_cursor: $cursor} else {} end)'
}

# POSTs with ?wait so the Company's reply comes back in the same response (§8.3)
function post() {
    local cid=$1 url=$2 body=$3 cursor
    cursor=$(load_state "${cid}" | jq -r '.cursor // empty')
    request POST "${url}?wait=${wait_seconds}${cursor:+&cursor=${cursor}}" "${body}"
    if [[ ${last_rc} -ne 0 ]]; then explain_error "${reply_body}"; return 1; fi
    handle_read "${cid}" "${reply_body}"
}

# an ID (§8.2): 1 to 256 characters from the URL-safe base64 alphabet. Length is checked apart,
# since bash's regex can't repeat more than 255 times on every platform.
function require_cid() {
    [[ -n ${1:-} && ${#1} -le 256 && ${1} =~ ^[A-Za-z0-9_-]+$ ]] || { echo >&2 "ERROR: conversation id required"; usage 1; }
}

case ${command} in
start)
    [[ $# -ge 1 ]] || { echo >&2 "ERROR: start needs a first message"; usage 1; }
    body=$(jq -cn --arg id "req_$(rand_id)" --argjson m "$(message_json "$1")" '{id: $id, message: $m}')
    request POST "${endpoint}?wait=${wait_seconds}" "${body}"
    response=${reply_body}
    if [[ ${last_rc} -ne 0 ]]; then explain_error "${response}"; exit 1; fi
    cid=$(jq -r .conversation_id <<<"${response}")
    jq -n --arg id "${cid}" --arg at "$(iso_now)" '{conversation_id: $id, started_at: $at, cursor: null, seen: []}' >"$(state_file "${cid}")"
    echo >&2 "conversation ${cid}"
    handle_read "${cid}" "${response}"
    ;;
send)
    require_cid "${1:-}"
    [[ $# -ge 2 ]] || { echo >&2 "ERROR: send needs a message"; usage 1; }
    post "$1" "${endpoint}/$1/messages" "$(jq -cn --arg id "req_$(rand_id)" --argjson m "$(message_json "$2" "$1")" '{id: $id, message: $m}')"
    ;;
read)
    require_cid "${1:-}"
    read_events "$1" "${wait_seconds}"
    ;;
handoff | cancel | close)
    require_cid "${1:-}"
    path=handoff
    [[ ${command} == cancel ]] && path=handoff/cancel
    [[ ${command} == close ]] && path=close
    if [[ ${command} == close ]]; then
        # read until working is false first, so the Company has acted on everything sent (§8.12)
        read_events "$1" 5 >/dev/null || true
    fi
    post "$1" "${endpoint}/$1/${path}" "$(jq -cn --arg id "req_$(rand_id)" '{id: $id}')"
    ;;
direct)
    require_cid "${1:-}"
    # the User talks themselves in a Direct Conversation (§8.10)
    opt_human=1
    body=$(jq -cn --arg id "dir_$(rand_id)" --arg parent "$1" --arg event "${event_id}" '{id: $id, parent_conversation_id: $parent}
        + (if $event != "" then {user_requested_event_id: $event} else {} end)')
    if [[ -n ${2:-} ]]; then
        body=$(jq -c --argjson m "$(message_json "$2")" '. + {message: $m}' <<<"${body}")
    elif [[ -z ${event_id} ]]; then
        die "direct needs a first message, unless it accepts a user_requested event with -E (§8.10)"
    fi
    request POST "${endpoint}?wait=${wait_seconds}" "${body}"
    response=${reply_body}
    if [[ ${last_rc} -ne 0 ]]; then explain_error "${response}"; exit 1; fi
    cid=$(jq -r .conversation_id <<<"${response}")
    [[ -s $(state_file "${cid}") ]] ||
        jq -n --arg id "${cid}" --arg p "$1" --arg at "$(iso_now)" '{conversation_id: $id, parent: $p, started_at: $at, cursor: null, seen: []}' >"$(state_file "${cid}")"
    echo >&2 "Direct Conversation ${cid} (the User's own words go in with -H; this script sets it)"
    handle_read "${cid}" "${response}"
    echo >&2 "continue with: $0 -H send ${cid} \"...\""
    ;;
list)
    for f in "${conversations}"/*.json; do
        [[ -e ${f} ]] || continue
        jq -r '"\(.conversation_id)  \(.started_at // "")  \(if .closed then "closed" else "open" end)\(if .parent then "  direct, parent " + .parent else "" end)"' "${f}"
    done
    ;;
*)
    echo >&2 "ERROR: unknown command: ${command}"
    usage 1
    ;;
esac
