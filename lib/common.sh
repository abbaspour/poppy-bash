# shellcheck shell=bash
# shellcheck disable=SC2034

##########################################################################################
# Author: Amin Abbaspour
# Date: 2026-11-17
# License: LGPL 2.1
#
# common.sh: shared settings and helpers for poppy-bash scripts. Sourced, never executed.
# Loads .env from the repo root, then defines where state lives and a handful of helpers
# (base64url, random IDs, URL parsing, state paths) that every protocol step needs.
##########################################################################################

POPPY_HOME="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
readonly POPPY_HOME

# POPPY_ENV_FILE points at another env file, eg. for an isolated test run; scripts it calls inherit it
: "${POPPY_ENV_FILE:=${POPPY_HOME}/.env}"
export POPPY_ENV_FILE
# shellcheck disable=SC1090
[[ -f "${POPPY_ENV_FILE}" ]] && . "${POPPY_ENV_FILE}"

# --- settings (override in .env) ---
: "${POPPY_STATE:=${POPPY_HOME}/.state}"        # User IDs, Sessions, delegated keys, tokens
: "${POPPY_CACHE:=${POPPY_HOME}/.cache}"        # discovery documents, per Company domain
: "${POPPY_USER:=default}"                      # the local User this agent acts for
: "${POPPY_IMPLEMENTED_VERSION:=1.0}"           # protocol version this agent implements (§3.4)
: "${POPPY_DELEGATION_TTL:=3600}"               # delegation lifetime in seconds, at most 86400 (§5.2)
: "${POPPY_DEV_ALLOW_HTTP:=0}"                  # 1 = allow http://localhost for local testing only (§3)
: "${AGENT_BASE_URL:=}"                         # public HTTPS base of web/public, eg. the tunnel host
: "${CLIENT_ID:=${AGENT_BASE_URL:+${AGENT_BASE_URL}/cimd.json}}"
: "${AGENT_EC_KEY:=${POPPY_HOME}/keys/agent-ec-private.pem}"     # signs delegations (and ES256 assertions)
: "${AGENT_RSA_KEY:=${POPPY_HOME}/keys/agent-rsa-private.pem}"   # signs PS256/RS256 client assertions
: "${CLIENT_ASSERTION_ALG:=ES256}"
: "${COMPANY_DOMAIN:=}"

# --- encoding ---
function b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

function b64url_decode() {
    local _s="${1//-/+}"
    _s="${_s//_//}"
    case $(( ${#_s} % 4 )) in
        2) _s="${_s}==" ;;
        3) _s="${_s}=" ;;
    esac
    printf '%s' "${_s}" | openssl base64 -d -A
}

# 16 random bytes, base64url: 22 characters from the ID alphabet of §8.2
function rand_id() { openssl rand 16 | b64url; }

function die() { echo >&2 "ERROR: $*"; exit 1; }

# filesystem-safe name for a URL or domain
function slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# --- URLs ---
# url_part <url> <scheme|authority|path|query>; authority is lowercase host[:port], with
# the default port removed, as organization.domain expects (§3.1)
function url_part() {
    local _url=$1 _part=$2
    [[ ${_url} =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$ ]] || return 1
    local _scheme _authority _path _query
    _scheme=$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")
    _authority=$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[2]##*@}")
    _path=${BASH_REMATCH[3]}
    _query=${BASH_REMATCH[4]}
    [[ ${_scheme} == https ]] && _authority=${_authority%:443}
    [[ ${_scheme} == http ]] && _authority=${_authority%:80}
    case ${_part} in
        scheme) echo "${_scheme}" ;;
        authority) echo "${_authority}" ;;
        path) echo "${_path:-/}" ;;
        query) echo "${_query}" ;;
    esac
}

# the URL without query or fragment, for htm/htu (§5.2, RFC 9449 §4.2)
function url_htu() {
    echo "$(url_part "$1" scheme)://$(url_part "$1" authority)$(url_part "$1" path)"
}

# succeeds when the URL is one this agent may use: HTTPS, or http to loopback in dev mode
function url_allowed() {
    local _scheme _authority _host
    _scheme=$(url_part "$1" scheme) || return 1
    _authority=$(url_part "$1" authority)
    _host=${_authority%:*}
    if [[ ${_scheme} == https ]]; then
        # §3: no loopback, private or link-local addresses unless configured on purpose
        if [[ ${POPPY_DEV_ALLOW_HTTP} != 1 ]] &&
            [[ ${_host} == localhost || ${_host} =~ ^(127|10|0)\. || ${_host} =~ ^192\.168\. ||
                ${_host} =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || ${_host} =~ ^169\.254\. || ${_host} == \[* ]]; then
            return 1
        fi
        return 0
    fi
    [[ ${_scheme} == http && ${POPPY_DEV_ALLOW_HTTP} == 1 && ( ${_host} == localhost || ${_host} == 127.0.0.1 ) ]]
}

# curl --proto values matching url_allowed
function curl_protos() {
    if [[ ${POPPY_DEV_ALLOW_HTTP} == 1 ]]; then echo "=http,https"; else echo "=https"; fi
}

# --- Company and User state ---
# the Company domain: explicit argument, else COMPANY_DOMAIN, else the last one discovered
function resolve_domain() {
    local _d=${1:-${COMPANY_DOMAIN}}
    [[ -z ${_d} && -f "${POPPY_STATE}/current-domain" ]] && _d=$(cat "${POPPY_STATE}/current-domain")
    [[ -n ${_d} ]] || die "no Company domain: pass -d, set COMPANY_DOMAIN, or run discover.sh first"
    _d=${_d#https://}
    _d=${_d#http://}
    _d=${_d%%/*}
    tr '[:upper:]' '[:lower:]' <<<"${_d}"
}

function discovery_file() { echo "${POPPY_CACHE}/$(slug "$1")/discovery.json"; }

# path of the cached discovery summary for a domain, running discover.sh on a cache miss
function load_discovery() {
    local _f
    _f=$(discovery_file "$1")
    [[ -s ${_f} ]] || "${POPPY_HOME}/discover.sh" -q -d "$1" >/dev/null || die "discovery failed for $1"
    echo "${_f}"
}

# per-User, per-Company state directory. User IDs are scoped by the Company identifier, not the
# domain (§5.1), so domains that share an issuer share this directory.
function company_dir() {
    echo "${POPPY_STATE}/users/$(slug "${POPPY_USER}")/$(slug "$1")"
}

function iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- OAuth (§4) ---
# oidc-bash does the plain OAuth requests. It never reads its own .env here: everything it needs
# is passed as flags, so its settings can't leak into a Poppy sign-in.
export OIDC_BASH_NO_DOTENV=1

function oidc_bash() {
    local _dir=${OIDC_BASH_DIR:-../oidc-bash}
    [[ ${_dir} == /* ]] || _dir="${POPPY_HOME}/${_dir}"
    [[ -x "${_dir}/authorize.sh" ]] || die "oidc-bash not found at ${_dir}; run setup.sh or set OIDC_BASH_DIR"
    echo "${_dir}"
}

# the key that signs client assertions (§4.1): the EC key for ES256, the RSA key otherwise
function assertion_key() {
    case ${CLIENT_ASSERTION_ALG} in
    ES256) echo "${AGENT_EC_KEY}" ;;
    RS256 | PS256) echo "${AGENT_RSA_KEY}" ;;
    *) die "CLIENT_ASSERTION_ALG must be ES256, PS256 or RS256" ;;
    esac
}

# the issuer's host, which oidc-bash takes as its domain
function issuer_host() { url_part "$1" authority; }

# Resources to name in the request that starts sign-in, comma separated: URLs, or "default" for
# https://{organization.domain}. Poppy says not to (§4.5): a sign-in without resource covers every
# service. Set it only for an issuer that needs a resource to pick the token's audience.
: "${POPPY_SIGN_IN_RESOURCES:=}"

# refresh and access tokens for this User at this Company; one account per User and Company
function tokens_file() { echo "$(company_dir "$1")/tokens.json"; }

# copies stdin to the clipboard; fails when there's no clipboard tool
function copy_to_clipboard() {
    if command -v pbcopy >/dev/null; then pbcopy
    elif command -v wl-copy >/dev/null; then wl-copy
    elif command -v xclip >/dev/null; then xclip -selection clipboard
    else return 1; fi
}
