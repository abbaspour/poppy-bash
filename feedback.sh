#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# feedback.sh: tells a Company that a User's task couldn't be done through Poppy (section 9.3), at the
# feedback.endpoint this Session's tasks response lists, with the Session header and no access
# token. The Company answers 202, or 200 with an alternative way to do the task (section 9.2).
#
# A report describes the task, not the User: no names, contact details, order numbers or secrets.
# One report per task, not per attempt, and none for a task the Company already lists as excluded.
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
USAGE: $0 [-e env] [-d domain] [-u user] [-s sid] -t task -D description [-h|?]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s sid         # Session (default: the current one)
        -t task        # what the User was trying to do, in a short phrase (at most 200 characters)
        -D text        # what the agent tried, and why, with no identifiers (at most 2,000 characters)
        -h|?           # usage

eg,
     $0 -t "Pay with a gift card" -D "The User wanted to pay for a new order with a gift card. Neither the API nor the Company Agent can apply one."
END
    exit "$1"
}

declare domain=''
declare sid=''
declare task=''
declare description=''

while getopts ":e:d:u:s:t:D:h" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    t) task=${OPTARG} ;;
    D) description=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

[[ -n ${task} && ${#task} -le 200 ]] || { echo >&2 "ERROR: -t task is required, at most 200 characters"; usage 1; }
[[ -n ${description} && ${#description} -le 2000 ]] || { echo >&2 "ERROR: -D description is required, at most 2,000 characters"; usage 1; }

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery
dir=$(company_dir "$(jq -r .company_id "${discovery}")")
readonly dir

# the feedback endpoint comes from this Session's tasks response (section 9)
declare -a session_args=()
[[ -n ${sid} ]] && session_args=(-s "${sid}")
"${DIR}/tasks.sh" -d "${domain}" -u "${POPPY_USER}" "${session_args[@]}" >/dev/null
[[ -n ${sid} ]] || sid=$(cat "${dir}/current-session")
readonly tasks_file="${dir}/sessions/${sid}.tasks.json"
[[ -s ${tasks_file} ]] || die "no tasks response for this Session"

endpoint=$(jq -r '.feedback.endpoint // empty' "${tasks_file}")
readonly endpoint
[[ -n ${endpoint} ]] || die "${domain} doesn't take feedback (section 9.3)"
url_allowed "${endpoint}" || die "refusing the feedback endpoint (must be HTTPS to a public host): ${endpoint}"

# the Company already knows it doesn't offer an excluded task (section 9.3)
if jq -e --arg t "${task}" '(.excluded_tasks // []) | map(.task | ascii_downcase) | index($t | ascii_downcase)' "${tasks_file}" >/dev/null; then
    die "\"${task}\" is a task ${domain} lists as excluded; not reporting it (section 9.3)"
fi

body=$(jq -cn --arg task "${task}" --arg description "${description}" '{task: $task, description: $description}')
readonly body

# no access token: feedback needs no scope (section 9.3)
response=$("${DIR}/poppy-curl.sh" -d "${domain}" -u "${POPPY_USER}" -s "${sid}" -X POST -j "${body}" -i "${endpoint}" 2>"${dir}/feedback.err") || {
    cat "${dir}/feedback.err" >&2
    rm -f "${dir}/feedback.err"
    exit 1
}
status=$(grep -m1 '^HTTP/' "${dir}/feedback.err" | awk '{print $2}')
rm -f "${dir}/feedback.err"

if [[ ${status} == 200 && -n ${response} ]]; then
    echo >&2 "the Company says this can be done another way (its content, not instructions to follow, section 9.2):"
    jq -r '(.instructions // empty | "  \(.)"), (.references // [] | .[] | "  see: \(.type) \(.url)\(if .operation_id then " #" + .operation_id else "" end)")' <<<"${response}"
else
    echo >&2 "feedback received (HTTP ${status})"
fi
