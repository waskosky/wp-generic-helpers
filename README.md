# WordPress Generic Helpers

General-case WordPress tools and AI agent guidance.

This repo is a place to collect reusable setup notes, MCP server configuration,
and operating guidance for AI agents working with WordPress sites. It is not
site-specific infrastructure. Instead, it should track what we learn is broadly
useful across WordPress, Elementor, WooCommerce, and related agent workflows.

## Current Scope

- WordPress MCP Adapter and Automattic remote proxy setup.
- Elementor WordPress MCP setup.
- Codex CLI `config.toml` examples for connecting agents to WordPress MCP
  servers.
- Agent guidance for safe discovery, backups, credential handling, and
  troubleshooting.

## Contributing Notes

Keep this repo generic. Site-specific URLs, usernames, application passwords,
campaign notes, and private implementation details belong in the local agent
workspace or the target site's private docs, not in this repository.

When adding a new pattern, include:

- what problem it solves
- WordPress-side setup
- agent-side setup
- safety or permission concerns
- a quick way to verify it works
