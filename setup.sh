#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# setup.sh: one-time setup. Checks dependencies, creates .env from env.sample, finds or
# clones oidc-bash (used for the OAuth steps), creates the agent's keys, and builds
# jwks.json and cimd.json when AGENT_BASE_URL is set.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

readonly OIDC_BASH_REPO=https://github.com/abbaspour/oidc-bash

function usage() {
    cat <<END >&2
USAGE: $0 [-h|?]
        -h|?           # usage

eg,
     $0
END
    exit "$1"
}

while getopts ":h" opt; do
    case ${opt} in
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    esac
done

(( BASH_VERSINFO[0] >= 4 )) || { echo >&2 "error: bash 4 or later required (macOS: brew install bash)"; exit 3; }
for cmd in curl jq openssl xxd python3 git; do
    command -v "${cmd}" >/dev/null || { echo >&2 "error: ${cmd} not found"; exit 3; }
done
for cmd in cloudflared shellcheck gum; do
    command -v "${cmd}" >/dev/null || echo >&2 "note: ${cmd} not found (optional)"
done

if [[ ! -f "${DIR}/.env" ]]; then
    cp "${DIR}/env.sample" "${DIR}/.env"
    echo >&2 "created .env from env.sample; edit AGENT_BASE_URL, then run $0 again"
fi

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

: "${OIDC_BASH_DIR:=../oidc-bash}"
[[ ${OIDC_BASH_DIR} == /* ]] || OIDC_BASH_DIR="${POPPY_HOME}/${OIDC_BASH_DIR}"
if [[ -x "${OIDC_BASH_DIR}/authorize.sh" ]]; then
    echo >&2 "oidc-bash: ${OIDC_BASH_DIR}"
else
    OIDC_BASH_DIR="${POPPY_HOME}/vendor/oidc-bash"
    if [[ ! -d ${OIDC_BASH_DIR} ]]; then
        git clone --depth 1 "${OIDC_BASH_REPO}" "${OIDC_BASH_DIR}"
    fi
    echo >&2 "oidc-bash: ${OIDC_BASH_DIR} (set OIDC_BASH_DIR=vendor/oidc-bash in .env)"
fi

"${POPPY_HOME}/keys/gen-keys.sh"
"${POPPY_HOME}/keys/build-jwks.sh"
if [[ -n ${AGENT_BASE_URL} && ${AGENT_BASE_URL} != https://agent.example.dev ]]; then
    "${POPPY_HOME}/web/build-cimd.sh"
else
    echo >&2 "set AGENT_BASE_URL in .env, then run: web/build-cimd.sh"
fi
