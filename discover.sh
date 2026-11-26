#!/usr/bin/env bash

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# discover.sh: Poppy discovery (section 3) for any Company domain.
#   1. GET https://{domain}/.well-known/poppy.json, following HTTPS-only redirects. The final
#      URL's path must be exactly /.well-known/poppy.json with no query, and organization.domain
#      must be the host that served it.
#   2. Choose the newest compatible version among protocol_version and supported_versions (section 3.4).
#   3. GET https://{organization.domain}/.well-known/oauth-protected-resource (RFC 9728) to find
#      the issuer. 404, or no authorization_servers, means a Company without sign-in.
#   4. GET the issuer's RFC 8414 metadata; issuer must match character for character and
#      protected_resources must list https://{organization.domain}.
#   5. Fetch the OpenAPI descriptions to learn which URLs are Session header destinations (section 5.2),
#      and, with an issuer, each API's own protected resource metadata: an API whose resource
#      isn't https://{organization.domain} accepts only tokens issued for it (section 4.5).
# Writes a summary to .cache/<domain>/discovery.json, which the other scripts read.
##########################################################################################

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

# shellcheck source=lib/common.sh
. "${DIR}/lib/common.sh"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

function usage() {
    cat <<END >&2
USAGE: $0 [-e env] [-d domain] [-f jq_filter] [-W] [-q] [-h|?] [-v]
        -e file        # .env file location
        -d domain      # Company domain, eg. shop.example.com (default COMPANY_DOMAIN, or last discovered)
        -f filter      # jq filter applied to the summary, eg. .company_id (default: whole summary)
        -W             # wipe the cache and discover again
        -q             # quiet: no human-readable report on stderr
        -h|?           # usage
        -v             # verbose

eg,
     $0 -d shop.example.com
     $0 -d shop.example.com -f '.sign_in'
END
    exit "$1"
}

declare domain=''
declare filter='.'
declare -i opt_force=0
declare -i opt_quiet=0
declare -i opt_verbose=0

while getopts ":e:d:f:Wqhv" opt; do
    case ${opt} in
    e) # shellcheck disable=SC1090
       source "${OPTARG}" ;;
    d) domain=${OPTARG} ;;
    f) filter=${OPTARG} ;;
    W) opt_force=1 ;;
    q) opt_quiet=1 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

domain=$(resolve_domain "${domain}")
readonly domain

summary_file=$(discovery_file "${domain}")
readonly summary_file
cache_dir=${summary_file%/*}
readonly cache_dir

if [[ ${opt_force} -eq 0 && -s ${summary_file} ]]; then
    [[ ${opt_verbose} -eq 1 ]] && echo >&2 "> using cache ${summary_file}"
    mkdir -p "${POPPY_STATE}" && echo "${domain}" >"${POPPY_STATE}/current-domain"
    jq "${filter}" "${summary_file}"
    exit 0
fi

rm -rf "${cache_dir}"
mkdir -p "${cache_dir}"

function log() { [[ ${opt_verbose} -eq 1 ]] && echo >&2 "> $*"; return 0; }

# fetch <url> <out_file> [follow_redirects]; sets status and final_url
declare status='' final_url=''
function fetch() {
    local url=$1 out=$2 follow=${3:-0}
    url_allowed "${url}" || die "refusing URL (must be HTTPS to a public host): ${url}"
    local -a args=(-sS --max-time 15 --proto "$(curl_protos)" -H 'accept: application/json' -o "${out}" -w '%{http_code} %{url_effective}\n')
    [[ ${follow} -eq 1 ]] && args+=(-L --proto-redir "$(curl_protos)" --max-redirs 5)
    log "GET ${url}"
    read -r status final_url < <(curl "${args[@]}" --url "${url}" 2>/dev/null || echo "000 ${url}")
    log "${status} ${final_url}"
}

# --- 1. poppy.json ---
declare first_url="https://${domain}/.well-known/poppy.json"
# dev mode: a local Company on plain http
[[ ${POPPY_DEV_ALLOW_HTTP} == 1 && ${domain} =~ ^(localhost|127\.0\.0\.1)(:|$) ]] && first_url="http://${domain}/.well-known/poppy.json"
readonly first_url
fetch "${first_url}" "${cache_dir}/poppy.json" 1
[[ ${status} == 200 ]] || die "GET poppy.json returned HTTP ${status} (${final_url})"
url_allowed "${final_url}" || die "poppy.json redirected to a disallowed URL: ${final_url}"
[[ $(url_part "${final_url}" path) == /.well-known/poppy.json && -z $(url_part "${final_url}" query) ]] ||
    die "poppy.json redirected to ${final_url}; the last URL must be exactly /.well-known/poppy.json with no query (section 3)"
jq -e 'type == "object"' "${cache_dir}/poppy.json" >/dev/null || die "poppy.json is not a JSON object"

served_host=$(url_part "${final_url}" authority)
readonly served_host
scheme=$(url_part "${final_url}" scheme)
readonly scheme

org_domain=$(jq -r '.organization.domain // empty' "${cache_dir}/poppy.json")
[[ -n ${org_domain} ]] || die "poppy.json has no organization.domain"
[[ $(tr '[:upper:]' '[:lower:]' <<<"${org_domain}") == "${served_host}" ]] ||
    die "organization.domain '${org_domain}' isn't the host that served poppy.json '${served_host}' (section 3)"
org_domain=${served_host}
readonly org_domain

# --- 2. version (section 3.4) ---
readonly impl_major=${POPPY_IMPLEMENTED_VERSION%%.*}
readonly impl_minor=${POPPY_IMPLEMENTED_VERSION#*.}

function compatible() {
    local major=${1%%.*} minor=${1#*.}
    [[ $1 =~ ^[0-9]+\.[0-9]+$ && ${major} == "${impl_major}" ]] || return 1
    [[ ${major} != 0 || ${minor} == "${impl_minor}" ]]
}

declare chosen=''
while read -r v; do
    compatible "${v}" && chosen=${v}
done < <(jq -r '[.protocol_version] + (.supported_versions // {} | keys) | .[]' "${cache_dir}/poppy.json" |
    sort -t. -k1,1n -k2,2n)
[[ -n ${chosen} ]] || die "no version in poppy.json is compatible with ${POPPY_IMPLEMENTED_VERSION} (section 3.4)"
readonly chosen

if [[ ${chosen} != $(jq -r .protocol_version "${cache_dir}/poppy.json") ]]; then
    version_url=$(jq -r --arg v "${chosen}" '.supported_versions[$v]' "${cache_dir}/poppy.json")
    [[ $(url_part "${version_url}" authority) == "${served_host}" ]] ||
        die "supported_versions[${chosen}] isn't on ${served_host}: ${version_url}"
    mv "${cache_dir}/poppy.json" "${cache_dir}/poppy-preferred.json"
    fetch "${version_url}" "${cache_dir}/poppy.json" 0
    [[ ${status} == 200 ]] || die "GET ${version_url} returned HTTP ${status}"
    [[ $(jq -r .protocol_version "${cache_dir}/poppy.json") == "${chosen}" ]] ||
        die "${version_url} doesn't have protocol_version ${chosen}"
    [[ $(jq -r '.organization.domain | ascii_downcase' "${cache_dir}/poppy.json") == "${org_domain}" ]] ||
        die "${version_url} has another organization.domain"
fi
readonly poppy="${cache_dir}/poppy.json"

jq -e 'has("agent") or has("apis") or has("web")' "${poppy}" >/dev/null ||
    die "poppy.json lists none of agent, apis or web (section 3.1)"

# every URL the document gives us must be HTTPS (section 3)
while read -r u; do
    url_allowed "${u}" || die "poppy.json has a disallowed URL: ${u}"
done < <(jq -r '[.. | objects | to_entries[] | select(.key | test("(endpoint|url|uri)$")) | .value | strings] | .[]' "${poppy}")

# --- 3. protected resource metadata (RFC 9728, section 3.2) ---
readonly resource="${scheme}://${org_domain}"
fetch "${resource}/.well-known/oauth-protected-resource" "${cache_dir}/protected-resource.json" 0

declare issuer=''
auth_issuer=$(jq -r '.auth.issuer // empty' "${poppy}")
readonly auth_issuer

case ${status} in
404)
    rm -f "${cache_dir}/protected-resource.json"
    ;;
200)
    prm_resource=$(jq -r '.resource // empty' "${cache_dir}/protected-resource.json")
    [[ ${prm_resource} == "${resource}" ]] ||
        die "protected resource metadata 'resource' is '${prm_resource}', expected '${resource}' (section 3.2)"
    n_as=$(jq '.authorization_servers // [] | length' "${cache_dir}/protected-resource.json")
    if [[ ${n_as} -eq 1 ]]; then
        issuer=$(jq -r '.authorization_servers[0]' "${cache_dir}/protected-resource.json")
        [[ -z ${auth_issuer} || ${auth_issuer} == "${issuer}" ]] ||
            die "auth.issuer '${auth_issuer}' isn't the one authorization server '${issuer}' (section 3.1)"
    elif [[ ${n_as} -gt 1 ]]; then
        [[ -n ${auth_issuer} ]] || die "several authorization_servers and no auth.issuer to choose one (section 3.1)"
        jq -e --arg i "${auth_issuer}" '.authorization_servers | index($i)' "${cache_dir}/protected-resource.json" >/dev/null ||
            die "auth.issuer '${auth_issuer}' isn't in authorization_servers"
        issuer=${auth_issuer}
    fi
    ;;
*)
    # section 3.2: no domain fallback after an error
    die "GET ${resource}/.well-known/oauth-protected-resource returned HTTP ${status}; not falling back to no issuer"
    ;;
esac

if [[ -z ${issuer} && -n ${auth_issuer} ]]; then
    die "poppy.json names auth.issuer but the domain lists no authorization server (section 3.2)"
fi
readonly issuer

# --- 4. authorization server metadata (RFC 8414, section 3.2) ---
if [[ -n ${issuer} ]]; then
    url_allowed "${issuer}" || die "issuer isn't an HTTPS URL: ${issuer}"
    # RFC 8414 section 3.1: insert the well-known segment between host and path, dropping a trailing /
    issuer_path=$(url_part "${issuer}" path)
    issuer_path=${issuer_path%/}
    as_url="$(url_part "${issuer}" scheme)://$(url_part "${issuer}" authority)/.well-known/oauth-authorization-server${issuer_path}"
    fetch "${as_url}" "${cache_dir}/authorization-server.json" 0
    [[ ${status} == 200 ]] || die "GET ${as_url} returned HTTP ${status}"

    as=${cache_dir}/authorization-server.json
    [[ $(jq -r '.issuer // empty' "${as}") == "${issuer}" ]] ||
        die "authorization server metadata issuer '$(jq -r '.issuer' "${as}")' doesn't match '${issuer}' exactly (section 3.2)"
    jq -e --arg r "${resource}" '.protected_resources // [] | map(ascii_downcase | rtrimstr("/")) | index($r | ascii_downcase)' "${as}" >/dev/null ||
        die "issuer's protected_resources doesn't list ${resource}; another domain could be claiming this issuer (section 3.2)"
    for field in token_endpoint revocation_endpoint; do
        jq -e --arg f "${field}" '.[$f] | strings' "${as}" >/dev/null || die "authorization server metadata has no ${field} (section 3.2)"
    done
    jq -e '.grant_types_supported // [] | index("refresh_token")' "${as}" >/dev/null ||
        die "grant_types_supported doesn't include refresh_token (section 3.2)"
fi

# --- 5. Session header destinations (section 5.2) ---
# OpenAPI request URLs come from each description's servers; relative ones resolve against it
declare -a destinations=()
while read -r api_url; do
    out="${cache_dir}/openapi-$(slug "${api_url}").json"
    fetch "${api_url}" "${out}" 0
    if [[ ${status} != 200 ]]; then
        echo >&2 "WARNING: GET ${api_url} returned HTTP ${status}; skipping that API"
        rm -f "${out}"
        continue
    fi
    origin="$(url_part "${api_url}" scheme)://$(url_part "${api_url}" authority)"
    while read -r server; do
        [[ ${server} == /* ]] && server="${origin}${server}"
        [[ ${server} == *"{"* ]] && continue
        url_allowed "${server}" && destinations+=("${server%/}")
    done < <(jq -r '.servers // [{"url":"/"}] | .[].url' "${out}")
done < <(jq -r '.apis // [] | .[] | select(.type == "openapi") | .url' "${poppy}")

while read -r d; do
    destinations+=("${d}")
done < <(jq -r '
    (.apis // [] | .[] | select(.type == "mcp") | .url),
    (.agent.protocols // [] | .[] | .endpoint),
    (.tasks.endpoint // empty),
    (.web.browser_session_endpoint // empty | . + "/authorize"),
    (.extensions // {} | .[] | .[] | .endpoint // empty)' "${poppy}")

# section 4.5: per-service tokens. The metadata URL inserts the well-known segment between the host and
# the path (RFC 9728 section 3.1), and counts only if its resource is the URL it was derived from.
declare resources='{}'
if [[ -n ${issuer} ]]; then
    for server in "${destinations[@]}"; do
        prm_url="$(url_part "${server}" scheme)://$(url_part "${server}" authority)/.well-known/oauth-protected-resource$(url_part "${server}" path)"
        prm_url=${prm_url%/}
        out="${cache_dir}/protected-resource-$(slug "${server}").json"
        fetch "${prm_url}" "${out}" 0
        if [[ ${status} == 200 ]] && [[ $(jq -r '.resource // ""' "${out}" 2>/dev/null) == "${server}" ]] && [[ ${server} != "${resource}" ]]; then
            resources=$(jq -c --arg s "${server}" '.[$s] = $s' <<<"${resources}")
        else
            rm -f "${out}"
        fi
    done
fi
readonly resources

# --- summary ---
declare company_id=${issuer}
[[ -z ${company_id} ]] && company_id=${resource}
readonly company_id

as_file=/dev/null
[[ -s ${cache_dir}/authorization-server.json ]] && as_file=${cache_dir}/authorization-server.json
prm_file=/dev/null
[[ -s ${cache_dir}/protected-resource.json ]] && prm_file=${cache_dir}/protected-resource.json

jq -n \
    --arg domain "${org_domain}" \
    --arg company_id "${company_id}" \
    --arg issuer "${issuer}" \
    --arg version "${chosen}" \
    --arg poppy_version "${POPPY_IMPLEMENTED_VERSION}" \
    --arg website "${resource}/" \
    --arg fetched_at "$(iso_now)" \
    --slurpfile poppy "${poppy}" \
    --slurpfile prm <(cat "${prm_file}") \
    --slurpfile as <(cat "${as_file}") \
    --argjson resources "${resources}" \
    --args \
    '
    ($poppy[0]) as $p | ($as[0] // null) as $a |
    ($a.grant_types_supported // []) as $g |
    {
        domain: $domain,
        company_id: $company_id,
        issuer: (if $issuer == "" then null else $issuer end),
        version: $version,
        poppy_version: $poppy_version,
        organization: $p.organization,
        sign_in: (
            if $a == null or ($p.auth.disabled // false) then {available: false}
            else {
                available: true,
                direct: (($g | index("authorization_code")) != null and ($a.authorization_endpoint != null)),
                par: ($a.pushed_authorization_request_endpoint != null),
                par_required: ($a.require_pushed_authorization_requests // false),
                dpop_algs: ($a.dpop_signing_alg_values_supported // [])
            } end),
        scopes_supported: ((($prm[0].scopes_supported // []) + ($a.scopes_supported // [])) | unique),
        destinations: $ARGS.positional,
        resources: $resources,
        website: $website,
        fetched_at: $fetched_at,
        poppy: $p,
        protected_resource: ($prm[0] // null),
        authorization_server: $a
    }' "${destinations[@]}" >"${summary_file}"

mkdir -p "${POPPY_STATE}"
echo "${org_domain}" >"${POPPY_STATE}/current-domain"

if [[ ${opt_quiet} -eq 0 ]]; then
    jq -r '
        "Company:      \(.organization.name) (\(.domain))",
        "Identifier:   \(.company_id)",
        "Version:      \(.version) (sending Poppy-Version \(.poppy_version))",
        "Sign-in:      \(if .sign_in.available then ([if .sign_in.direct then "direct" else empty end, if .sign_in.par then "par" else empty end] | join(", ")) else "none (signed-out Sessions only)" end)",
        "Agent:        \(.poppy.agent.protocols // [] | map("\(.type) \(.endpoint)") | join(", ") | if . == "" then "-" else . end)",
        "APIs:         \(.poppy.apis // [] | map("\(.type) \(.url)") | join(", ") | if . == "" then "-" else . end)",
        "Tasks:        \(.poppy.tasks.endpoint // "-")",
        "Destinations: \(.destinations | join(", "))"' "${summary_file}" >&2
fi

jq "${filter}" "${summary_file}"
