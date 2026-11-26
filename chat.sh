#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# chat.sh: a text chat with a Company's agent (section 8), on top of converse.sh. Every turn is one
# converse.sh call, so request IDs, cursors, Sessions, tokens and refresh all work as they do there.
#
#   - Type a message to send it; the Company's reply is shown when it arrives.
#   - An `authorization` event (the Company needs the User's account) asks to sign in with
#     sign-in.sh, then sends the same message again in the same conversation (section 8.11).
#   - A `user_requested` event (the Company asks to talk with the User) asks to open a Direct
#     Conversation. In it the User's own words are sent as author.type human (section 8.10).
#   - Lines starting with / are commands; /help lists them.
#
# Uses gum (https://github.com/charmbracelet/gum) for the spinner, prompts and styling when it is
# installed and the terminal is interactive; -P uses plain read instead, with history.
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
USAGE: $0 [-e env] [-d domain] [-u user] [-w seconds] [-o] [-P] [-h|?] [conversation_id]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -w seconds     # how long the Company may hold a request for its reply (default 10)
        -o             # signed out, even if the User is signed in (/in undoes it)
        -P             # plain: no gum, read with history
        -h|?           # usage

eg,
     $0                    # a new conversation at \$COMPANY_DOMAIN, started by your first message
     $0 cnv_...            # continue a conversation this agent started
     $0 -o -d shop.example.dev
END
    exit "$1"
}

declare domain=''
declare -i wait_seconds=10
declare -i opt_signed_out=0
declare -i opt_plain=0

while getopts ":e:d:u:w:oPh" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    w) wait_seconds=${OPTARG} ;;
    o) opt_signed_out=1 ;;
    P) opt_plain=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

declare conv=${1:-}
if [[ -n ${conv} ]]; then
    [[ ${#conv} -le 256 && ${conv} =~ ^[A-Za-z0-9_-]+$ ]] || { echo >&2 "ERROR: not a conversation id: ${conv}"; usage 1; }
fi

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery
company_id=$(jq -r .company_id "${discovery}")
readonly company_id
conversations="$(company_dir "${company_id}")/conversations"
readonly conversations

declare -i use_gum=0
if [[ ${opt_plain} -eq 0 ]] && command -v gum >/dev/null && [[ -t 0 && -t 1 ]]; then use_gum=1; fi
readonly use_gum

tmp=$(mktemp -d)
readonly tmp
trap 'rm -rf "${tmp}"' EXIT

# --- looks: gum when there is a terminal for it, plain text otherwise ---
function style() {
    local fg=$1
    shift
    if [[ ${use_gum} -eq 1 ]]; then gum style --foreground "${fg}" -- "$*"; else printf '%s' "$*"; fi
}

function note() { echo "$(style 244 "$*")"; }

function fail() { echo "$(style 196 "$*")" >&2; }

# ask <question>: succeeds when the User says yes
function ask() {
    if [[ ${use_gum} -eq 1 ]]; then
        gum confirm "$1"
    else
        local answer=''
        read -r -p "$1 [y/N] " answer || return 1
        [[ ${answer} =~ ^[Yy] ]]
    fi
}

# the next line the User types; fails at end of input or when they leave
function prompt_line() {
    local label=$1 line=''
    if [[ ${use_gum} -eq 1 ]]; then
        line=$(gum input --prompt "${label} " --placeholder "a message, or /help" --char-limit 0 --width 0) || return 1
        # gum clears its line; show what was sent, so the conversation reads top to bottom
        echo "$(style 39 "${label}") ${line}"
    else
        IFS= read -er -p "${label} " line || return 1
        [[ -z ${line} ]] || history -s "${line}"
    fi
    reply=${line}
}

# --- one converse.sh call, with a spinner when there is one ---
# cv <title> <converse.sh args...> sets out (stdout: JSON lines), err (stderr) and rc
declare out='' err=''
declare -i rc=0
function cv() {
    local title=$1
    shift
    local -a cmd=("${DIR}/converse.sh" -J -d "${domain}" -u "${POPPY_USER}" -w "${wait_seconds}")
    [[ ${opt_signed_out} -eq 1 ]] && cmd+=(-o)
    [[ ${direct} -eq 1 ]] && cmd+=(-H)
    cmd+=("$@")
    rc=0
    if [[ ${use_gum} -eq 1 ]]; then
        gum spin --title "${title}" -- bash -c 'o=$1; e=$2; shift 2; "$@" >"$o" 2>"$e"' _ "${tmp}/out" "${tmp}/err" "${cmd[@]}" || rc=$?
    else
        "${cmd[@]}" >"${tmp}/out" 2>"${tmp}/err" || rc=$?
    fi
    out=$(cat "${tmp}/out" 2>/dev/null || true)
    err=$(cat "${tmp}/err" 2>/dev/null || true)
    if [[ ${rc} -ne 0 ]]; then
        fail "${err:-converse.sh failed (exit ${rc})}"
    elif [[ -n ${err} && ${err} != conversation\ * && ${err} != Direct\ Conversation* ]]; then
        note "${err}"
    fi
}

# --- showing what came back ---
declare st_working=false st_handoff=none st_closed=false
declare need_scope='' need_event='' need_reason=''

function render() {
    local line type who text
    need_scope='' need_event='' need_reason=''
    st_working=false st_handoff=none st_closed=false
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        type=$(jq -r '.type // ""' <<<"${line}")
        case ${type} in
        message)
            [[ $(jq -r '.message.role' <<<"${line}") == company ]] || continue
            who=$(jq -r 'if .message.author.type == "human" then "person" + (if .message.author.name then " (\(.message.author.name))" else "" end) else "company" end' <<<"${line}")
            text=$(jq -r '.message.text // ""' <<<"${line}")
            [[ -z ${text} ]] || echo "$(style 212 "${who}>") ${text}"
            jq -r '.message.data // empty | "      data: \(tojson | if length > 300 then .[:300] + "…" else . end)"' <<<"${line}"
            ;;
        state) note "[handoff: $(jq -r .handoff <<<"${line}"), responder: $(jq -r .responder <<<"${line}")$(jq -r 'if .closed then ", closed" else "" end' <<<"${line}")]" ;;
        authorization)
            need_scope=$(jq -r '.scope // ""' <<<"${line}")
            note "[the Company needs you signed in: $(jq -r .error <<<"${line}"), scope \"${need_scope}\"]"
            ;;
        user_requested)
            need_event=$(jq -r .id <<<"${line}")
            need_reason=$(jq -r '.reason // ""' <<<"${line}")
            ;;
        direct_opened) note "[Direct Conversation opened: $(jq -r .conversation_id <<<"${line}")]" ;;
        direct_closed) note "[Direct Conversation closed: $(jq -r .conversation_id <<<"${line}")]" ;;
        _status)
            st_working=$(jq -r .working <<<"${line}")
            st_handoff=$(jq -r .handoff <<<"${line}")
            st_closed=$(jq -r .closed <<<"${line}")
            ;;
        esac
    done <<<"${out}"
}

declare direct=0 parent='' last_text=''

# after a call: show it, keep reading while the Company is still replying, then act on what it asked
function settle() {
    [[ ${rc} -eq 0 ]] || return 0
    render
    local -i tries=0
    while [[ ${st_working} == true && ${tries} -lt 6 ]]; do
        cv "the Company is replying…" read "${conv}"
        [[ ${rc} -eq 0 ]] || return 0
        render
        tries+=1
    done
    [[ ${st_working} == true ]] && note "(still replying: /wait to look again)"
    [[ ${st_handoff} == pending ]] && note "(looking for a person: /wait to check)"
    [[ ${st_closed} == true && ${direct} -eq 0 ]] && note "(this conversation is closed; /new starts another)"
    follow_up
    return 0
}

# the Company asked for something: sign in (section 8.11), or a Direct Conversation (section 8.10)
function follow_up() {
    if [[ -n ${need_scope} ]]; then
        local scope=${need_scope}
        need_scope=''
        if ask "Sign in so the Company can use \"${scope}\"?"; then
            if "${DIR}/sign-in.sh" -d "${domain}" -u "${POPPY_USER}" -s "${scope// /,}"; then
                opt_signed_out=0
                note "signed in; sending your message again"
                deliver "${last_text}"
            else
                fail "sign-in didn't finish"
            fi
        else
            note "staying signed out; the Company can't do that for you"
        fi
    elif [[ -n ${need_event} ]]; then
        local event=${need_event}
        need_event=''
        if ask "The Company asks to talk with you directly (${need_reason:-no reason given}). Accept?"; then
            cv "opening a Direct Conversation…" -E "${event}" direct "${conv}"
            if [[ ${rc} -eq 0 ]]; then
                parent=${conv}
                conv=$(status_cid)
                direct=1
                note "Direct Conversation ${conv}: these are your own words now; /close ends it"
                settle
            fi
        else
            note "not accepted; the conversation goes on with the agent"
        fi
    fi
}

# the conversation a start or direct call is about, from its _status line
function status_cid() { jq -r 'select(.type == "_status") | .conversation_id' <<<"${out}"; }

function deliver() {
    local text=$1
    last_text=${text}
    if [[ -z ${conv} ]]; then
        cv "sending…" start "${text}"
        [[ ${rc} -ne 0 ]] || { conv=$(status_cid); note "conversation ${conv}"; }
    else
        cv "sending…" send "${conv}" "${text}"
    fi
    settle
}

function help() {
    local text='**Messages** go to the Company. **Commands:**

- `/handoff`, `/cancel`: ask for a person, or withdraw the request
- `/wait`, `/read`: look for new events, with or without waiting
- `/close`: close this conversation (in a Direct Conversation, return to the one before)
- `/new`: forget this conversation; your next message starts another
- `/sign-in scope,scope`: sign in now; `/out` signed out, `/in` back to normal
- `/id`, `/list`: the conversation id; the conversations this agent started
- `/quit`'
    if [[ ${use_gum} -eq 1 ]]; then gum format <<<"${text}"; else echo "${text}"; fi
}

function command_line() {
    local word=${1%% *} args=''
    [[ $1 == *" "* ]] && args=${1#* }
    case ${word} in
    /help | /\?) help ;;
    /quit | /exit) return 1 ;;
    /id) echo "${conv:-none yet}" ;;
    /list) "${DIR}/converse.sh" -d "${domain}" -u "${POPPY_USER}" list ;;
    /new) conv=''; direct=0; parent=''; note "the next message starts a new conversation" ;;
    /out) opt_signed_out=1; note "signed out for this chat; /in undoes it" ;;
    /in) opt_signed_out=0; note "using your tokens again, if you have them" ;;
    /sign-in)
        [[ -n ${args} ]] || { fail "usage: /sign-in scope,scope"; return 0; }
        "${DIR}/sign-in.sh" -d "${domain}" -u "${POPPY_USER}" -s "${args// /,}" && opt_signed_out=0 || fail "sign-in didn't finish"
        ;;
    /handoff | /cancel | /wait | /read | /close)
        [[ -n ${conv} ]] || { fail "no conversation yet"; return 0; }
        case ${word} in
        /handoff) cv "asking for a person…" handoff "${conv}" ;;
        /cancel) cv "withdrawing the request…" cancel "${conv}" ;;
        /wait) cv "waiting for the Company…" read "${conv}" ;;
        /read) cv "reading…" -w 0 read "${conv}" ;;
        /close)
            # take in any last reply first: closing marks what was read as seen
            cv "reading…" -w 0 read "${conv}"
            [[ ${rc} -ne 0 ]] || render
            cv "closing…" close "${conv}"
            ;;
        esac
        settle
        if [[ ${word} == /close && ${rc} -eq 0 ]]; then
            if [[ ${direct} -eq 1 ]]; then
                conv=${parent}; parent=''; direct=0
                note "back in ${conv}"
                cv "reading…" -w 0 read "${conv}"
                settle
            else
                conv=''
            fi
        fi
        ;;
    *) fail "unknown command ${word}; /help lists them" ;;
    esac
    return 0
}

# --- start ---
company=$(jq -r '.poppy.organization.name // empty' "${discovery}")
readonly company
signed_in=signed\ out
[[ ${opt_signed_out} -eq 0 && -s $(tokens_file "${company_id}") ]] && signed_in=signed\ in
banner="Poppy chat with ${company:-${domain}} (${domain}) as ${POPPY_USER}, ${signed_in}"
if [[ ${use_gum} -eq 1 ]]; then gum style --border rounded --border-foreground 212 --padding "0 2" "${banner}"; else echo "${banner}"; fi
note "/help lists the commands"

if [[ -n ${conv} ]]; then
    parent=$(jq -r '.parent // empty' "${conversations}/${conv}.json" 2>/dev/null || true)
    [[ -z ${parent} ]] || direct=1
    cv "catching up…" -w 0 read "${conv}"
    settle
fi

if [[ ${use_gum} -eq 0 && -t 0 ]]; then
    HISTFILE="${POPPY_STATE}/chat_history"
    set -o history
    history -r || true
fi

declare reply=''
while :; do
    label='you>'
    [[ ${direct} -eq 1 ]] && label='you (direct)>'
    prompt_line "${label}" || break
    reply=${reply#"${reply%%[![:space:]]*}"}
    reply=${reply%"${reply##*[![:space:]]}"}
    [[ -n ${reply} ]] || continue
    if [[ ${reply} == /* ]]; then
        command_line "${reply}" || break
    else
        deliver "${reply}"
    fi
done
[[ ${use_gum} -eq 0 && -t 0 ]] && history -w || true
echo
