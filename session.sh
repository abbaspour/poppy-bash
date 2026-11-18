#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# session.sh: manages Poppy Sessions (§5). There is no call to start one: a new random sid
# in the Session header starts it on the Company's side (§5.3). This script picks the sid
# and pins what must stay the same for the whole Session: the User ID, the Agent ID, the
# Poppy-Version and the Poppy-Extensions (§3.4, §5.2). Ending a Session means no longer
# using its sid (§5.5); refresh tokens are unaffected.
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
USAGE: $0 [-e env] [-d domain] [-u user] [-A agent] [-h|?] command
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -A agent       # with new: the Session is for this agent's Agent ID (§5.1)
        -h|?           # usage

commands:
        new            # start a Session with a new random sid, and make it current
        current        # print the current Session (default)
        list           # list Sessions at this Company
        use <sid>      # make an existing Session current
        end [sid]      # stop using a Session (default: the current one)

eg,
     $0 -d shop.example.com new
     $0 end
END
    exit "$1"
}

declare domain=''
declare agent=''

while getopts ":e:d:u:A:h" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    A) agent=${OPTARG} ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

declare command=${1:-current}
declare arg=${2:-}

domain=$(resolve_domain "${domain}")
readonly domain

discovery=$(load_discovery "${domain}")
readonly discovery
company_id=$(jq -r .company_id "${discovery}")
readonly company_id

dir=$(company_dir "${company_id}")
readonly dir
readonly sessions_dir="${dir}/sessions"
readonly current_file="${dir}/current-session"

umask 077
mkdir -p "${sessions_dir}"

function current_sid() {
    [[ -s ${current_file} ]] && cat "${current_file}"
    return 0
}

case ${command} in
new)
    # the User ID (and Agent ID) are fixed for the Session's lifetime
    user_json=$("${DIR}/user.sh" -d "${domain}" -u "${POPPY_USER}" ${agent:+-A "${agent}"} 2>/dev/null)
    sub=$(jq -r .sub <<<"${user_json}")
    agent_id=''
    [[ -n ${agent} ]] && agent_id=$(jq -r --arg a "${agent}" '.agent_ids[$a]' <<<"${user_json}")

    sid=$(rand_id)
    jq -n \
        --arg sid "${sid}" \
        --arg company_id "${company_id}" \
        --arg domain "${domain}" \
        --arg sub "${sub}" \
        --arg agent "${agent}" \
        --arg agent_id "${agent_id}" \
        --arg version "$(jq -r .poppy_version "${discovery}")" \
        --arg extensions "${POPPY_EXTENSIONS:-}" \
        --arg now "$(iso_now)" \
        '{sid: $sid, company_id: $company_id, domain: $domain, sub: $sub,
          agent: (if $agent == "" then null else $agent end),
          agent_id: (if $agent_id == "" then null else $agent_id end),
          poppy_version: $version, poppy_extensions: $extensions,
          created_at: $now, ended_at: null}' >"${sessions_dir}/${sid}.json"
    echo "${sid}" >"${current_file}"
    echo >&2 "started Session ${sid} (signed out) at ${company_id}"
    jq . "${sessions_dir}/${sid}.json"
    ;;
current)
    sid=$(current_sid)
    [[ -n ${sid} ]] || die "no current Session at ${company_id}; run: $0 new"
    jq . "${sessions_dir}/${sid}.json"
    ;;
list)
    cur=$(current_sid)
    for f in "${sessions_dir}"/*.json; do
        # <sid>.tasks.json is a Session's tasks response (tasks.sh), not a Session
        [[ -e ${f} && ${f} != *.tasks.json ]] || continue
        jq -r --arg cur "${cur}" \
            '"\(if .sid == $cur then "*" else " " end) \(.sid)  \(.created_at)  \(if .ended_at then "ended" else "active" end)\(if .agent_id then "  agent " + .agent_id else "" end)"' "${f}"
    done
    ;;
use)
    [[ -n ${arg} && -s ${sessions_dir}/${arg}.json ]] || die "no such Session: ${arg}"
    jq -e '.ended_at == null' "${sessions_dir}/${arg}.json" >/dev/null || die "Session ${arg} has ended"
    echo "${arg}" >"${current_file}"
    jq . "${sessions_dir}/${arg}.json"
    ;;
end)
    sid=${arg:-$(current_sid)}
    [[ -n ${sid} && -s ${sessions_dir}/${sid}.json ]] || die "no such Session: ${sid}"
    tmp=$(jq --arg now "$(iso_now)" '.ended_at = $now' "${sessions_dir}/${sid}.json")
    echo "${tmp}" >"${sessions_dir}/${sid}.json"
    [[ $(current_sid) == "${sid}" ]] && rm -f "${current_file}"
    echo >&2 "ended Session ${sid}"
    ;;
*)
    echo >&2 "ERROR: unknown command: ${command}"
    usage 1
    ;;
esac
