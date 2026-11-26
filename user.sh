#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# user.sh: the User ID this agent gives the local User at one Company (section 5.1), created on
# first use. It is random, so it is opaque, stable, different at each Company, and derived
# from nothing personal. It is scoped by the Company identifier (issuer, or https://{domain}),
# so every domain of one Company gets the same User ID. -A also creates an Agent ID, for
# agents that act for the User separately, such as a travel and a shopping agent.
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
USAGE: $0 [-e env] [-d domain] [-u user] [-A agent] [-h|?]
        -e file        # .env file location
        -d domain      # Company domain (default COMPANY_DOMAIN, or last discovered)
        -u user        # local User this agent acts for (default POPPY_USER=${POPPY_USER})
        -A agent       # also create (or show) the Agent ID for this agent name
        -h|?           # usage

eg,
     $0 -d shop.example.com
     $0 -d shop.example.com -A shopping
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

domain=$(resolve_domain "${domain}")
readonly domain

discovery=$(load_discovery "${domain}")
readonly discovery
company_id=$(jq -r .company_id "${discovery}")
readonly company_id

dir=$(company_dir "${company_id}")
readonly dir
readonly user_file="${dir}/user.json"

# the mapping of Users to User IDs is confidential (section 5.1)
umask 077
mkdir -p "${dir}"

if [[ ! -s ${user_file} ]]; then
    jq -n --arg c "${company_id}" --arg sub "usr_$(rand_id)" --arg now "$(iso_now)" \
        '{company_id: $c, sub: $sub, agent_ids: {}, created_at: $now}' >"${user_file}"
    echo >&2 "created User ID for ${POPPY_USER} at ${company_id}"
fi

if [[ -n ${agent} ]] && ! jq -e --arg a "${agent}" '.agent_ids[$a]' "${user_file}" >/dev/null; then
    tmp=$(jq --arg a "${agent}" --arg id "agt_$(rand_id)" '.agent_ids[$a] = $id' "${user_file}")
    echo "${tmp}" >"${user_file}"
    echo >&2 "created Agent ID for '${agent}'"
fi

jq . "${user_file}"
