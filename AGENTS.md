# WordPress Generic Helpers

This repository documents reusable WordPress MCP setup and AI agent operating
guidance. Keep it general-purpose. Do not commit site credentials, application
passwords, customer data, analytics exports, campaign details, or private URLs
unless the repository has explicitly become private and the data is intended to
live here.

## Current MCP Servers

These notes cover two useful MCP paths:

1. `wp-elementor-mcp`
   - Purpose: direct WordPress and Elementor page-building operations.
   - Source: `wp-elementor-mcp` by Jason Miller.
   - Repository: `https://github.com/Huetarded/wp-elementor-mcp`
   - NPM package: `wp-elementor-mcp`
   - Typical tools: get Elementor data, list elements, update widgets, update
     complete Elementor JSON, create containers, duplicate/delete elements, and
     clear Elementor cache.

2. `@automattic/mcp-wordpress-remote`
   - Purpose: generic proxy from an AI agent MCP client to a WordPress MCP
     endpoint.
   - Source: Automattic.
   - Repository: `https://github.com/Automattic/mcp-wordpress-remote`
   - NPM package: `@automattic/mcp-wordpress-remote`
   - WordPress-side dependency: the WordPress MCP Adapter plugin.
   - Typical tools: whatever abilities the target WordPress site registers
     through MCP Adapter. The ability list is site-dependent.

Use the Elementor server when the task is specifically page structure,
Elementor widgets, Elementor templates, or Elementor cache. Use the WordPress
proxy when the site exposes generic MCP Adapter abilities such as plugin
settings, WooCommerce reports, cart-abandonment data, custom operational
actions, or other registered server abilities.

## WordPress-Side Setup

### Shared Prerequisites

For any WordPress MCP setup:

1. Confirm the WordPress REST API is reachable.
2. Create a dedicated WordPress user for agent access, for example
   `ai_agent` or `ai_codex`.
3. Grant only the permissions needed for the intended work.
4. Create a WordPress application password for that user from:
   `Users -> Profile -> Application Passwords`.
5. Store the generated application password in the agent host config only.
   Never commit it to this repo.
6. Check security plugins, WAF rules, and hosting firewalls. They can block
   automated REST requests and produce misleading 401 or 403 errors.

### Elementor MCP Server

WordPress side requirements:

1. Install and activate Elementor.
2. Install and activate Elementor Pro only if the workflow needs Pro-only
   template or global-setting features.
3. Ensure the agent WordPress user can read and edit the post types it will
   work on, usually `page`, `post`, and any relevant custom post types.
4. Ensure application passwords are enabled on the site.
5. Confirm the REST API can return pages and post meta for the agent user.

The Elementor MCP server itself does not require a custom WordPress plugin
besides Elementor. It connects through WordPress REST APIs using the configured
WordPress base URL, username, and application password.

Recommended verification:

1. Start the agent with the Elementor MCP server enabled.
2. Call the equivalent of `list_all_content`.
3. Pick a known Elementor page ID and call the equivalent of
   `get_elementor_elements`.
4. Before any edit, call the equivalent of `backup_elementor_data`.
5. After a small test edit, clear Elementor cache for the post and then check
   the public page in a browser or with `curl`.

### WordPress MCP Adapter And Remote Proxy

WordPress side requirements:

1. Install and activate the WordPress MCP Adapter plugin.
   - Repository: `https://github.com/WordPress/mcp-adapter`
   - The default server route is normally:
     `/wp-json/mcp/mcp-adapter-default-server`
2. Confirm the full endpoint URL for the target site, for example:
   `https://example.com/wp-json/mcp/mcp-adapter-default-server`
3. Configure authentication. The remote proxy supports OAuth, JWT, custom
   headers, and WordPress application passwords. Application passwords are the
   simplest starting point for self-hosted WordPress sites.
4. Install or enable WordPress plugins that register the abilities the agent
   needs. MCP Adapter is the transport and ability registry. It does not
   automatically mean every WordPress admin action exists as a tool.
5. Confirm ability discovery works before assuming a capability exists.

Recommended verification:

1. Start the agent with the WordPress proxy enabled.
2. Call the equivalent of `mcp_adapter_discover_abilities`.
3. Inspect a specific ability with the equivalent of
   `mcp_adapter_get_ability_info`.
4. Only execute write abilities after checking the ability schema and whether
   the ability is destructive or non-idempotent.

## Codex CLI Configuration

Codex CLI MCP servers are configured in:

```text
~/.codex/config.toml
```

Keep credentials in that local file or in environment variables. Do not commit
real credentials to this repository.

## Agent-Side Download And Install

The fastest install path is to let Codex start the package with `npx` from
`config.toml`. For reproducible hosts, pin versions instead of using `latest`.

For a first-pass automated setup, use:

```bash
./mcp_full_setup.sh --help
```

The script installs the local Elementor MCP wrapper, configures the WordPress
proxy in Codex `config.toml`, and can attempt WordPress-side plugin activation
when run with `wp-cli` access to a local WordPress install.

Check package metadata:

```bash
npm view wp-elementor-mcp name version description repository
npm view @automattic/mcp-wordpress-remote name version description repository
```

Optional global installs:

```bash
npm install -g wp-elementor-mcp@1.7.1
npm install -g @automattic/mcp-wordpress-remote
```

Optional local package downloads for auditing:

```bash
npm pack wp-elementor-mcp@1.7.1
npm pack @automattic/mcp-wordpress-remote
```

### Option A: Elementor MCP With `npx`

This is the simplest general setup.

```toml
[mcp_servers.elementor_wordpress]
command = "npx"
args = ["-y", "wp-elementor-mcp@1.7.1"]

[mcp_servers.elementor_wordpress.env]
ELEMENTOR_MCP_MODE = "standard"
WORDPRESS_BASE_URL = "https://example.com"
WORDPRESS_USERNAME = "ai_agent"
WORDPRESS_APPLICATION_PASSWORD = "xxxx xxxx xxxx xxxx xxxx xxxx"
```

Useful mode values:

```text
ELEMENTOR_MCP_MODE = "essential"
ELEMENTOR_MCP_MODE = "standard"
ELEMENTOR_MCP_MODE = "advanced"
ELEMENTOR_MCP_MODE = "full"
```

Use `standard` unless the site needs advanced or Pro-specific tools.

### Option B: Elementor MCP With A Pinned Local Wrapper

Use this when you want deterministic local installs and do not want every agent
startup to resolve through `npx`.

Example wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${HOME}/.local/share/mcp/wp-elementor-mcp/current"
SERVER_ENTRY="${SERVER_ROOT}/dist/index.js"

if [[ ! -f "${SERVER_ENTRY}" ]]; then
  echo "wp-elementor-mcp is not installed at ${SERVER_ENTRY}" >&2
  exit 1
fi

exec node "${SERVER_ENTRY}"
```

Example Codex config:

```toml
[mcp_servers.elementor_wordpress]
command = "/home/YOUR_USER/bin/wp-elementor-mcp-local"
```

If the package root contains a `.env`, use placeholders like this and keep the
file local:

```dotenv
ELEMENTOR_MCP_MODE=standard
WORDPRESS_BASE_URL=https://example.com
WORDPRESS_USERNAME=ai_agent
WORDPRESS_APPLICATION_PASSWORD=xxxx xxxx xxxx xxxx xxxx xxxx
```

### WordPress Proxy With MCP Adapter

Recommended generic setup:

```toml
[mcp_servers.wordpress-proxy]
command = "npx"
args = ["-y", "@automattic/mcp-wordpress-remote@latest"]

[mcp_servers.wordpress-proxy.env]
WP_API_URL = "https://example.com/wp-json/mcp/mcp-adapter-default-server"
WP_API_USERNAME = "ai_agent"
WP_API_PASSWORD = "xxxx xxxx xxxx xxxx xxxx xxxx"
OAUTH_ENABLED = "false"
LOG_LEVEL = "2"
LOG_FILE = "/tmp/wordpress-proxy.log"
```

For OAuth or JWT setups, follow the proxy package documentation and avoid
putting long-lived secrets into checked-in files.

## Agent Workflow Guidance

Before doing WordPress work:

1. Identify which MCP server is appropriate.
2. Discover the live tool or ability surface.
3. Confirm whether the requested action is read-only or persistent.
4. For Elementor pages, create an Elementor data backup before edits.
5. For proxy abilities, inspect the ability info before running writes.
6. Prefer small, reversible changes and verify the public result.
7. If public HTML does not match saved Elementor data, suspect cache or render
   sync layers before assuming the edit failed.

For Elementor edits:

1. Use element listing tools to find widget and section IDs.
2. Read the exact widget or page data before patching.
3. Preserve unrelated Elementor JSON.
4. Back up the page data.
5. Apply the smallest possible widget or element update.
6. Clear Elementor cache for the specific post, then globally if needed.
7. Verify through WordPress REST and the public rendered page.

For WordPress proxy abilities:

1. Run ability discovery.
2. Read ability details and schema.
3. Treat settings updates and operational actions as persistent.
4. Do not assume page, post, cache, WooCommerce, or Elementor actions exist
   unless discovery shows them.
5. If a needed action is missing, add or enable a WordPress-side ability rather
   than overloading an unrelated tool.

## Troubleshooting

Common failure modes:

- `401 Unauthorized`: wrong username, wrong application password, insufficient
  user permissions, or authentication method mismatch.
- `403 Forbidden`: WAF/security plugin/host firewall blocking automated REST
  traffic, user lacks capability, or application passwords are disabled.
- Empty ability list: MCP Adapter is installed but no public abilities are
  registered for the authenticated user.
- Missing page tools in `wordpress-proxy`: expected unless a WordPress-side
  ability registers page operations.
- Elementor saved data differs from public page: clear Elementor cache and then
  inspect host/page/cache layers.
- `npx` startup failures: check Node version, network access, and package name.

## Repository Maintenance

When adding a new WordPress MCP pattern:

1. Keep examples generic and credential-free.
2. Include source repository and package names.
3. Include WordPress-side setup and agent-side `config.toml` setup.
4. Include verification steps.
5. Add safety notes for persistent or destructive operations.
