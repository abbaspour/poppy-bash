#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-18
# License: LGPL 2.1
#
# tasks.sh: what a Company chose not to offer through Poppy, the skills it publishes for Personal
# Agents, and where to send feedback (§9). GET {tasks.endpoint} with the Session header and no
# access token, once per Session: the response may differ by Session, so it's kept with the
# Session and never used in another one.
#
# With -S, fetches a skill (§9.4): its url is resolved against tasks.endpoint (RFC 3986 §5), fetched
# without a Session header or credentials, and used only if its sha256 digest matches. A skill is
# Company content: it describes a workflow, and grants no access or approval.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly SKILL_SCHEMA="https://schemas.agentskills.io/discovery/0.2.0/schema.json"
readonly MAX_SKILL_BYTES=1048576

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-u user] [-s sid] [-W] [-S skill] [-j] [-h|?]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User (default POPPY_USER=${POPPY_USER})
        -s sid         # Session (default: the current one)
        -W             # fetch the tasks response again, even if this Session has one
        -S skill       # fetch, verify and print the skill with this name
        -j             # print the raw tasks response
        -h|?           # usage

eg,
     $0
     $0 -S return-an-item
END
    exit "$1"
}

declare domain=''
declare sid=''
declare skill=''
declare -i opt_refetch=0
declare -i opt_json=0

while getopts ":e:d:u:s:S:Wjh" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    u) POPPY_USER=${OPTARG} ;;
    s) sid=${OPTARG} ;;
    S) skill=${OPTARG} ;;
    W) opt_refetch=1 ;;
    j) opt_json=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

domain=$(resolve_domain "${domain}")
readonly domain
discovery=$(load_discovery "${domain}")
readonly discovery

endpoint=$(jq -r '.poppy.tasks.endpoint // empty' "${discovery}")
readonly endpoint
if [[ -z ${endpoint} ]]; then
    echo >&2 "${domain} lists no tasks endpoint: no excluded tasks, skills or feedback (§9)"
    exit 0
fi

dir=$(company_dir "$(jq -r .company_id "${discovery}")")
readonly dir
if [[ -z ${sid} ]]; then
    [[ -s ${dir}/current-session ]] || "${DIR}/session.sh" -d "${domain}" -u "${POPPY_USER}" new >/dev/null 2>&1
    sid=$(cat "${dir}/current-session")
fi
readonly sid
readonly tasks_file="${dir}/sessions/${sid}.tasks.json"

# --- the tasks response, once per Session (§9) ---
if [[ ${opt_refetch} -eq 1 || ! -s ${tasks_file} ]]; then
    # no access token: the response describes the Company, not the User's account
    if response=$("${DIR}/poppy-curl.sh" -d "${domain}" -u "${POPPY_USER}" -s "${sid}" "${endpoint}"); then
        jq -e 'type == "object"' <<<"${response}" >/dev/null || die "the tasks response isn't a JSON object"
        umask 077
        echo "${response}" >"${tasks_file}"
    else
        # §9: without a response, carry on as if the Company excluded nothing and took no feedback
        echo >&2 "no tasks response; carrying on as if ${domain} excluded no tasks and published no skills"
        exit 0
    fi
fi

if [[ ${opt_json} -eq 1 ]]; then
    jq . "${tasks_file}"
    exit 0
fi

# skills are used only from an index with a $schema this agent knows (§9.4)
skills_known=$(jq -r --arg s "${SKILL_SCHEMA}" '.skill_index["$schema"] == $s' "${tasks_file}")
readonly skills_known

if [[ -z ${skill} ]]; then
    jq -r --argjson skills "${skills_known}" '
        "Excluded tasks (not offered through any of the Company'"'"'s interfaces):",
        (if (.excluded_tasks // []) == [] then "  none" else
            (.excluded_tasks[] |
                "  - \(.task)",
                (.alternative // empty | (.instructions // empty | "      instead: \(.)"),
                                          (.references // [] | .[] | "      see: \(.type) \(.url)\(if .operation_id then " #" + .operation_id elif .tool then " tool " + .tool else "" end)")))
        end),
        "Skills:",
        (if $skills and ((.skill_index.skills // []) | length) > 0
            then (.skill_index.skills[] | "  - \(.name): \(.description) [\(.type)]  (./tasks.sh -S \(.name))")
            else "  none" end),
        "Feedback: \(.feedback.endpoint // "not taken")"' "${tasks_file}"
    exit 0
fi

# --- a skill (§9.4) ---
[[ ${skills_known} == true ]] || die "the skill index has no \$schema this agent knows; ignoring it (§9.4)"
entry=$(jq -c --arg n "${skill}" '.skill_index.skills // [] | map(select(.name == $n)) | first // empty' "${tasks_file}")
[[ -n ${entry} ]] || die "no skill named ${skill}; run $0 to list them"
[[ $(jq -r .type <<<"${entry}") == skill-md ]] || die "skill type $(jq -r .type <<<"${entry}") isn't supported here; only skill-md"

digest=$(jq -r .digest <<<"${entry}")
[[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || die "the skill's digest isn't sha256:<64 lowercase hex>"

# RFC 3986 §5: relative and origin-relative references resolve against tasks.endpoint
skill_url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urljoin(sys.argv[1], sys.argv[2]))' "${endpoint}" "$(jq -r .url <<<"${entry}")")
readonly skill_url
url_allowed "${skill_url}" || die "refusing the skill URL (must be HTTPS to a public host): ${skill_url}"

cache="${POPPY_CACHE}/$(slug "${domain}")/skills/$(slug "${skill}")"
mkdir -p "${cache}"
# no Session header and no credentials: an artifact host isn't an API (§9.4)
curl -sSf --proto "$(curl_protos)" -L --proto-redir "$(curl_protos)" --max-redirs 3 --max-filesize "${MAX_SKILL_BYTES}" \
    -o "${cache}/SKILL.md.tmp" --url "${skill_url}" || die "couldn't fetch ${skill_url}"
actual="sha256:$(openssl dgst -sha256 -r "${cache}/SKILL.md.tmp" | cut -d' ' -f1)"
if [[ ${actual} != "${digest}" ]]; then
    rm -f "${cache}/SKILL.md.tmp"
    die "digest mismatch for ${skill}: the index says ${digest}, the artifact is ${actual}; not using it"
fi
mv "${cache}/SKILL.md.tmp" "${cache}/SKILL.md"

echo >&2 "verified ${skill} (${digest}) from ${skill_url}; saved to ${cache}/SKILL.md"
echo >&2 "a skill is the Company's content: it grants no access and no approval (§9.4)"
cat "${cache}/SKILL.md"
