#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

SITE_URL="${WORDPRESS_BASE_URL:-${WP_BASE_URL:-}}"
WP_USERNAME="${WORDPRESS_USERNAME:-${WP_API_USERNAME:-}}"
WP_APP_PASSWORD="${WORDPRESS_APPLICATION_PASSWORD:-${WP_API_PASSWORD:-}}"
WP_MCP_ENDPOINT="${WP_MCP_ENDPOINT:-${WP_API_URL:-}}"
WORDPRESS_PATH="${WORDPRESS_PATH:-}"
MCP_ADAPTER_ZIP_URL="${MCP_ADAPTER_ZIP_URL:-}"

CODEX_CONFIG="${CODEX_CONFIG:-${HOME}/.codex/config.toml}"
INSTALL_ROOT="${MCP_INSTALL_ROOT:-${HOME}/.local/share/mcp/wp-elementor-mcp}"
BIN_DIR="${BIN_DIR:-${HOME}/bin}"

ELEMENTOR_VERSION="${ELEMENTOR_VERSION:-1.7.1}"
ELEMENTOR_MODE="${ELEMENTOR_MCP_MODE:-standard}"
PROXY_PACKAGE="${WORDPRESS_PROXY_PACKAGE:-@automattic/mcp-wordpress-remote@latest}"
OAUTH_ENABLED="${OAUTH_ENABLED:-false}"
WORDPRESS_PROXY_LOG_LEVEL="${WORDPRESS_PROXY_LOG_LEVEL:-2}"
WORDPRESS_PROXY_LOG_FILE="${WORDPRESS_PROXY_LOG_FILE:-/tmp/wordpress-proxy.log}"

DRY_RUN=0
NON_INTERACTIVE=0
SKIP_ELEMENTOR_INSTALL=0
SKIP_CODEX_CONFIG=0
SKIP_WORDPRESS_SIDE=0
SKIP_VERIFY=0

usage() {
  cat <<EOF
${SCRIPT_NAME}

Install and configure both WordPress MCP paths discussed in this repo:

  1. wp-elementor-mcp, installed locally with a wrapper script.
  2. @automattic/mcp-wordpress-remote, configured through npx for the
     WordPress MCP Adapter endpoint.

Required values can be passed as flags or environment variables.

Usage:
  ${SCRIPT_NAME} --site-url https://example.com --wp-username ai_agent

Options:
  --site-url URL              WordPress base URL.
                              Env: WORDPRESS_BASE_URL or WP_BASE_URL
  --wp-username USER          WordPress username.
                              Env: WORDPRESS_USERNAME or WP_API_USERNAME
  --wp-app-password PASSWORD  WordPress application password.
                              Env: WORDPRESS_APPLICATION_PASSWORD or WP_API_PASSWORD
  --mcp-endpoint URL          MCP Adapter endpoint. Defaults to:
                              <site-url>/wp-json/mcp/mcp-adapter-default-server
                              Env: WP_MCP_ENDPOINT or WP_API_URL
  --codex-config PATH         Codex config.toml path.
                              Default: ~/.codex/config.toml
  --install-root PATH         Local wp-elementor-mcp install root.
                              Default: ~/.local/share/mcp/wp-elementor-mcp
  --bin-dir PATH              Directory for wrapper script.
                              Default: ~/bin
  --elementor-version VERSION wp-elementor-mcp version.
                              Default: 1.7.1
  --elementor-mode MODE       Elementor MCP mode: essential, standard,
                              advanced, or full. Default: standard
  --proxy-package PACKAGE     WordPress proxy package spec.
                              Default: @automattic/mcp-wordpress-remote@latest
  --wordpress-path PATH       Optional local WordPress install path. If set and
                              wp-cli is available, the script attempts
                              WordPress-side plugin installation/activation.
                              Env: WORDPRESS_PATH
  --mcp-adapter-zip-url URL   Optional MCP Adapter plugin zip URL for wp-cli
                              installation when the plugin is not already
                              installed. Env: MCP_ADAPTER_ZIP_URL
  --non-interactive           Fail instead of prompting for missing values.
  --dry-run                   Print actions without changing files.
  --skip-elementor-install    Do not install wp-elementor-mcp or wrapper.
  --skip-wordpress-side       Do not attempt WordPress-side plugin setup.
  --skip-codex-config         Do not update Codex config.toml.
  --skip-verify               Do not perform endpoint/package verification.
  -h, --help                  Show this help.

Example:
  WORDPRESS_BASE_URL="https://example.com" \\
  WORDPRESS_USERNAME="ai_agent" \\
  WORDPRESS_APPLICATION_PASSWORD="xxxx xxxx xxxx xxxx xxxx xxxx" \\
  ${SCRIPT_NAME}

WordPress-side prerequisites:
  - Create a dedicated WordPress user for agent access.
  - Create a WordPress application password for that user.
  - Install and activate Elementor for Elementor page operations.
  - Install and activate the WordPress MCP Adapter plugin for wordpress-proxy.
  - Confirm security plugins or host WAF rules allow authenticated REST calls.

If --wordpress-path is provided and wp-cli is installed, this script attempts
to install/activate Elementor and the MCP Adapter plugin. Without local wp-cli
access, it can only configure the agent side and verify reachable endpoints.
EOF
}

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run]' >&2
    local arg
    for arg in "$@"; do
      printf ' %q' "${arg}" >&2
    done
    printf '\n' >&2
  else
    "$@"
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

strip_trailing_slash() {
  local value="$1"
  while [[ "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "${value}"
}

prompt_if_missing() {
  local var_name="$1"
  local prompt="$2"
  local secret="${3:-0}"
  local current="${!var_name:-}"

  if [[ -n "${current}" ]]; then
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" == "1" || ! -t 0 ]]; then
    die "Missing ${var_name}. Provide it with a flag or environment variable."
  fi

  if [[ "${secret}" == "1" ]]; then
    read -r -s -p "${prompt}: " current
    printf '\n' >&2
  else
    read -r -p "${prompt}: " current
  fi

  if [[ -z "${current}" ]]; then
    die "${var_name} cannot be empty."
  fi

  printf -v "${var_name}" '%s' "${current}"
}

backup_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
    run cp "${path}" "${backup}"
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "Would back up ${path} to ${backup}"
    else
      log "Backed up ${path} to ${backup}"
    fi
  fi
}

replace_managed_block() {
  local path="$1"
  local block_name="$2"
  local block_file="$3"
  local start_marker="# BEGIN ${block_name}"
  local end_marker="# END ${block_name}"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "${path}" ]]; then
    awk -v start="${start_marker}" -v end="${end_marker}" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "${path}" > "${tmp}"
  fi

  local stripped
  stripped="$(mktemp)"
  awk '
    function is_target_table(line) {
      return line == "[mcp_servers.elementor_wordpress]" ||
             line == "[mcp_servers.wordpress-proxy]" ||
             line == "[mcp_servers.wordpress-proxy.env]"
    }
    is_target_table($0) { skip_table = 1; next }
    skip_table == 1 && $0 ~ /^\[/ { skip_table = 0 }
    skip_table != 1 { print }
  ' "${tmp}" > "${stripped}"
  mv "${stripped}" "${tmp}"

  {
    if [[ -s "${tmp}" ]]; then
      cat "${tmp}"
      printf '\n'
    fi
    printf '%s\n' "${start_marker}"
    cat "${block_file}"
    printf '%s\n' "${end_marker}"
  } > "${tmp}.new"

  run mv "${tmp}.new" "${path}"
  rm -f "${tmp}" "${tmp}.new"
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --site-url)
        SITE_URL="${2:-}"
        shift 2
        ;;
      --wp-username)
        WP_USERNAME="${2:-}"
        shift 2
        ;;
      --wp-app-password)
        WP_APP_PASSWORD="${2:-}"
        shift 2
        ;;
      --mcp-endpoint)
        WP_MCP_ENDPOINT="${2:-}"
        shift 2
        ;;
      --codex-config)
        CODEX_CONFIG="${2:-}"
        shift 2
        ;;
      --install-root)
        INSTALL_ROOT="${2:-}"
        shift 2
        ;;
      --bin-dir)
        BIN_DIR="${2:-}"
        shift 2
        ;;
      --elementor-version)
        ELEMENTOR_VERSION="${2:-}"
        shift 2
        ;;
      --elementor-mode)
        ELEMENTOR_MODE="${2:-}"
        shift 2
        ;;
      --proxy-package)
        PROXY_PACKAGE="${2:-}"
        shift 2
        ;;
      --wordpress-path)
        WORDPRESS_PATH="${2:-}"
        shift 2
        ;;
      --mcp-adapter-zip-url)
        MCP_ADAPTER_ZIP_URL="${2:-}"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --skip-elementor-install)
        SKIP_ELEMENTOR_INSTALL=1
        shift
        ;;
      --skip-wordpress-side)
        SKIP_WORDPRESS_SIDE=1
        shift
        ;;
      --skip-codex-config)
        SKIP_CODEX_CONFIG=1
        shift
        ;;
      --skip-verify)
        SKIP_VERIFY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_inputs() {
  have node || die "node is required."
  have npm || die "npm is required."
  have npx || die "npx is required."
  have awk || die "awk is required."
  have mktemp || die "mktemp is required."
  have tar || die "tar is required."

  prompt_if_missing SITE_URL "WordPress base URL"
  prompt_if_missing WP_USERNAME "WordPress username"
  prompt_if_missing WP_APP_PASSWORD "WordPress application password" 1

  SITE_URL="$(strip_trailing_slash "${SITE_URL}")"
  if [[ -z "${WP_MCP_ENDPOINT}" ]]; then
    WP_MCP_ENDPOINT="${SITE_URL}/wp-json/mcp/mcp-adapter-default-server"
  fi

  case "${ELEMENTOR_MODE}" in
    essential|standard|advanced|full) ;;
    *) die "Invalid --elementor-mode '${ELEMENTOR_MODE}'." ;;
  esac
}

verify_wordpress() {
  if [[ "${SKIP_VERIFY}" == "1" ]]; then
    log "Skipping WordPress endpoint verification."
    return 0
  fi

  if ! have curl; then
    log "curl not found; skipping WordPress endpoint verification."
    return 0
  fi

  log "Checking WordPress REST index: ${SITE_URL}/wp-json/"
  if ! curl -fsS --max-time 20 "${SITE_URL}/wp-json/" >/dev/null; then
    log "Warning: WordPress REST index check failed."
  fi

  log "Checking MCP Adapter endpoint: ${WP_MCP_ENDPOINT}"
  if ! curl -fsS --max-time 20 -u "${WP_USERNAME}:${WP_APP_PASSWORD}" "${WP_MCP_ENDPOINT}" >/dev/null; then
    log "Warning: MCP Adapter endpoint check failed. This may be normal if the server only accepts MCP POST traffic, but verify the WordPress-side plugin and WAF rules."
  fi
}

configure_wordpress_side() {
  if [[ "${SKIP_WORDPRESS_SIDE}" == "1" ]]; then
    log "Skipping WordPress-side plugin setup."
    return 0
  fi

  if [[ -z "${WORDPRESS_PATH}" ]]; then
    log "No --wordpress-path provided; skipping direct WordPress-side plugin setup."
    log "Manual WordPress-side requirements: activate Elementor and the WordPress MCP Adapter plugin."
    return 0
  fi

  if ! have wp; then
    log "wp-cli not found; skipping direct WordPress-side plugin setup."
    return 0
  fi

  log "Checking local WordPress install at ${WORDPRESS_PATH}"
  if ! run wp --path="${WORDPRESS_PATH}" core is-installed; then
    log "Warning: ${WORDPRESS_PATH} does not appear to be a valid WordPress install."
    return 0
  fi

  log "Ensuring Elementor is installed and active."
  if ! run wp --path="${WORDPRESS_PATH}" plugin is-installed elementor; then
    run wp --path="${WORDPRESS_PATH}" plugin install elementor
  fi
  run wp --path="${WORDPRESS_PATH}" plugin activate elementor

  log "Ensuring MCP Adapter is installed and active."
  if run wp --path="${WORDPRESS_PATH}" plugin is-installed mcp-adapter; then
    run wp --path="${WORDPRESS_PATH}" plugin activate mcp-adapter
  elif [[ -n "${MCP_ADAPTER_ZIP_URL}" ]]; then
    run wp --path="${WORDPRESS_PATH}" plugin install "${MCP_ADAPTER_ZIP_URL}" --activate
  elif run wp --path="${WORDPRESS_PATH}" plugin install mcp-adapter --activate; then
    log "Installed MCP Adapter using wordpress.org slug 'mcp-adapter'."
  else
    log "Warning: could not install MCP Adapter automatically."
    log "Install it manually from https://github.com/WordPress/mcp-adapter or rerun with --mcp-adapter-zip-url."
  fi

  if ! run wp --path="${WORDPRESS_PATH}" user get "${WP_USERNAME}" >/dev/null; then
    log "Warning: WordPress user '${WP_USERNAME}' was not found by wp-cli."
  fi
}

install_elementor_mcp() {
  if [[ "${SKIP_ELEMENTOR_INSTALL}" == "1" ]]; then
    log "Skipping wp-elementor-mcp local install."
    return 0
  fi

  local version_root="${INSTALL_ROOT}/versions/${ELEMENTOR_VERSION}"
  local wrapper="${BIN_DIR}/wp-elementor-mcp-local"
  local tmp
  tmp="$(mktemp -d)"

  log "Installing wp-elementor-mcp@${ELEMENTOR_VERSION} into ${version_root}"
  run mkdir -p "${INSTALL_ROOT}/versions" "${BIN_DIR}"

  if [[ "${DRY_RUN}" == "0" ]]; then
    (
      cd "${tmp}"
      local tarball
      tarball="$(npm pack "wp-elementor-mcp@${ELEMENTOR_VERSION}" | tail -n 1)"
      mkdir -p "${version_root}"
      tar -xzf "${tarball}" -C "${version_root}" --strip-components=1
      cd "${version_root}"
      npm install --omit=dev
    )
    ln -sfn "${version_root}" "${INSTALL_ROOT}/current"
  else
    run npm pack "wp-elementor-mcp@${ELEMENTOR_VERSION}"
    run mkdir -p "${version_root}"
    run ln -sfn "${version_root}" "${INSTALL_ROOT}/current"
  fi

  rm -rf "${tmp}"

  local env_file="${version_root}/.env"
  local env_tmp
  env_tmp="$(mktemp)"
  cat > "${env_tmp}" <<EOF
ELEMENTOR_MCP_MODE=${ELEMENTOR_MODE}
WORDPRESS_BASE_URL=${SITE_URL}
WORDPRESS_USERNAME=${WP_USERNAME}
WORDPRESS_APPLICATION_PASSWORD=${WP_APP_PASSWORD}
EOF
  if [[ -f "${env_file}" ]]; then
    backup_file "${env_file}"
  fi
  run mv "${env_tmp}" "${env_file}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    rm -f "${env_tmp}"
  fi

  local wrapper_tmp
  wrapper_tmp="$(mktemp)"
  cat > "${wrapper_tmp}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${HOME}/.local/share/mcp/wp-elementor-mcp/current"
SERVER_ENTRY="${SERVER_ROOT}/dist/index.js"

if [[ ! -f "${SERVER_ENTRY}" ]]; then
  echo "wp-elementor-mcp is not installed at ${SERVER_ENTRY}" >&2
  exit 1
fi

exec node "${SERVER_ENTRY}"
EOF
  if [[ "${wrapper}" != "${HOME}/bin/wp-elementor-mcp-local" ]]; then
    sed "s#\${HOME}/.local/share/mcp/wp-elementor-mcp/current#${INSTALL_ROOT}/current#g" "${wrapper_tmp}" > "${wrapper_tmp}.custom"
    mv "${wrapper_tmp}.custom" "${wrapper_tmp}"
  fi

  run mv "${wrapper_tmp}" "${wrapper}"
  run chmod +x "${wrapper}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    rm -f "${wrapper_tmp}"
  fi

  log "Elementor MCP wrapper: ${wrapper}"
}

warm_proxy_package() {
  if [[ "${SKIP_VERIFY}" == "1" ]]; then
    log "Skipping proxy package check."
    return 0
  fi

  log "Checking WordPress proxy package: ${PROXY_PACKAGE}"
  npm view "${PROXY_PACKAGE}" name version description >/dev/null
}

update_codex_config() {
  if [[ "${SKIP_CODEX_CONFIG}" == "1" ]]; then
    log "Skipping Codex config update."
    return 0
  fi

  local config_dir
  config_dir="$(dirname "${CODEX_CONFIG}")"
  run mkdir -p "${config_dir}"
  if [[ ! -f "${CODEX_CONFIG}" && "${DRY_RUN}" == "0" ]]; then
    touch "${CODEX_CONFIG}"
  fi
  backup_file "${CODEX_CONFIG}"

  local block_file
  block_file="$(mktemp)"
  cat > "${block_file}" <<EOF
[mcp_servers.elementor_wordpress]
command = "$(toml_escape "${BIN_DIR}/wp-elementor-mcp-local")"

[mcp_servers.wordpress-proxy]
command = "npx"
args = ["-y", "$(toml_escape "${PROXY_PACKAGE}")"]

[mcp_servers.wordpress-proxy.env]
WP_API_URL = "$(toml_escape "${WP_MCP_ENDPOINT}")"
WP_API_USERNAME = "$(toml_escape "${WP_USERNAME}")"
WP_API_PASSWORD = "$(toml_escape "${WP_APP_PASSWORD}")"
OAUTH_ENABLED = "$(toml_escape "${OAUTH_ENABLED}")"
LOG_LEVEL = "$(toml_escape "${WORDPRESS_PROXY_LOG_LEVEL}")"
LOG_FILE = "$(toml_escape "${WORDPRESS_PROXY_LOG_FILE}")"
EOF

  replace_managed_block "${CODEX_CONFIG}" "WORDPRESS MCP FULL SETUP" "${block_file}"
  rm -f "${block_file}"

  log "Updated Codex config: ${CODEX_CONFIG}"
}

print_next_steps() {
  cat <<EOF

Setup complete.

Configured:
  - Elementor MCP wrapper: ${BIN_DIR}/wp-elementor-mcp-local
  - Elementor MCP package: wp-elementor-mcp@${ELEMENTOR_VERSION}
  - WordPress proxy package: ${PROXY_PACKAGE}
  - Codex config: ${CODEX_CONFIG}
  - WordPress site: ${SITE_URL}
  - MCP Adapter endpoint: ${WP_MCP_ENDPOINT}
  - WordPress-side wp-cli path: ${WORDPRESS_PATH:-not provided}

Next steps:
  1. Restart Codex CLI so it reloads MCP server configuration.
  2. Verify the Elementor server by listing content or reading a known page.
  3. Verify wordpress-proxy by discovering MCP Adapter abilities.
  4. If wordpress-proxy has no page or cache abilities, add those abilities on
     the WordPress side; the proxy only exposes what the site registers.

Security:
  - ${CODEX_CONFIG} and the Elementor package .env contain the WordPress
    application password. Keep local file permissions tight and do not commit
    those files.
EOF
}

main() {
  parse_args "$@"
  validate_inputs
  verify_wordpress
  configure_wordpress_side
  install_elementor_mcp
  warm_proxy_package
  update_codex_config
  print_next_steps
}

main "$@"
