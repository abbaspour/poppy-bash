#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# gen-keys.sh: creates the Personal Agent's long-lived keys, whose public halves go in
# jwks.json (section 4.1):
#   agent-ec-private.pem   P-256, signs delegations (section 5.2) and ES256 client assertions
#   agent-rsa-private.pem  RSA 3072, signs PS256/RS256 client assertions, for authorization
#                          servers that don't accept ES256 or PS384, such as Auth0
# Existing keys are kept unless -f is given.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

command -v openssl >/dev/null || { echo >&2 "error: openssl not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-f] [-h|?]
        -f             # overwrite existing keys
        -h|?           # usage

eg,
     $0
END
    exit "$1"
}

declare -i opt_force=0

while getopts ":fh" opt; do
    case ${opt} in
    f) opt_force=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    esac
done

umask 077

function gen() {
    local file=$1; shift
    if [[ -f ${file} && ${opt_force} -eq 0 ]]; then
        echo >&2 "keeping ${file}"
        return
    fi
    openssl genpkey "$@" -out "${file}" 2>/dev/null
    echo >&2 "created ${file}"
}

gen "${DIR}/agent-ec-private.pem" -algorithm EC -pkeyopt ec_paramgen_curve:P-256
gen "${DIR}/agent-rsa-private.pem" -algorithm RSA -pkeyopt rsa_keygen_bits:3072
