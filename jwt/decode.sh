#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# decode.sh: prints the header and payload of a compact JWT, without verifying it. With -D,
# also decodes the delegation that a Session JWT carries in its poppy_dlg header (§5.2).
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=../lib/common.sh
. "${DIR}/../lib/common.sh"

command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-D] jwt
        -D             # also decode the poppy_dlg delegation in the header
        -h|?           # usage

eg,
     $0 -D eyJ0eXAiOiJwb3BweS1zZXNzaW9uK2p3dCIs...
END
    exit "$1"
}

declare -i opt_dlg=0

while getopts ":Dh" opt; do
    case ${opt} in
    D) opt_dlg=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 1 ]] || { echo >&2 "ERROR: jwt undefined"; usage 1; }

function decode() {
    local h p
    IFS=. read -r h p _ <<<"$1"
    jq -n --argjson header "$(b64url_decode "${h}")" --argjson payload "$(b64url_decode "${p}")" \
        '{header:$header, payload:$payload}'
}

decoded=$(decode "$1")
readonly decoded

if [[ ${opt_dlg} -eq 1 ]]; then
    dlg=$(jq -r '.header.poppy_dlg // empty' <<<"${decoded}")
    [[ -n ${dlg} ]] || die "no poppy_dlg header"
    jq --argjson delegation "$(decode "${dlg}")" '. + {delegation:$delegation}' <<<"${decoded}"
else
    jq . <<<"${decoded}"
fi
