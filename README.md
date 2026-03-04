# corpo-claude

Standardize Claude Code configuration across teams. A Bash CLI that reads
profile YAML files and writes Claude Code configuration to the correct
scopes — no tokens, no LLM, just file operations.

## Requirements

- [gum](https://github.com/charmbracelet/gum) — interactive TUI
- [yq](https://github.com/mikefarah/yq) — YAML parsing
- [jq](https://github.com/jqlang/jq) — JSON manipulation

```bash
brew install gum yq jq
```

## Installation

```bash
git clone <repo-url> corpo-claude
cd corpo-claude
chmod +x corpo-claude
```

Run directly from the cloned repo:

```bash
./corpo-claude --help
```

## Usage

### Commands

| Command | What it does | Scope |
|---------|-------------|-------|
| `init` | Set up provider, MCP servers, user CLAUDE.md, hooks, skills | User (`~/.claude/`) |
| `scaffold` | Generate `.claude/` folder in current directory | Project (`./.claude/`) |
| `preview` | Show what would be written without doing it | Read-only |

### Examples

```bash
# Preview what a profile will do
./corpo-claude preview --profile backend

# Apply a profile to user scope
./corpo-claude init --profile backend

# Apply multiple profiles (arrays accumulate, scalars last-wins)
./corpo-claude init --profile company --profile backend

# Scaffold project-scope config
./corpo-claude scaffold --profile backend

# Interactive mode — omit --profile for a picker menu
./corpo-claude init
```

## Profile YAML Reference

Profiles live in `profiles/` as `.yaml` files. Each profile can configure
any combination of the sections below.

```yaml
# Provider — configures Claude Code to use Vertex AI or Bedrock
provider:
  type: vertex              # vertex | bedrock
  region: global            # GCP region or AWS region

# User-scope CLAUDE.md — copied to ~/.claude/CLAUDE.md
claude_md: templates/company/CLAUDE.md

# MCP servers — installed via `claude mcp add`
mcp_servers:
  - name: context-mode
    type: npx               # npx | uvx
    package: context-mode

# Skills — copied to ~/.claude/commands/
skills:
  - templates/skills/review.md

# Hooks — written to ~/.claude/settings.json
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./hooks/block-prod.sh"

# Project template — used by `scaffold` command
project_template:
  claude_md: templates/backend/project-CLAUDE.md
  settings:
    permissions:
      deny:
        - "Bash(rm -rf *)"
  commands:
    - templates/commands/commit.md
  rules:
    - templates/rules/api-conventions.md
```

### Multiple Profiles

When multiple profiles are applied, they are merged:
- **Arrays** (mcp_servers, skills, hooks, commands, rules) are accumulated
- **Scalars** (provider type, region, claude_md) use last-wins

```bash
./corpo-claude init --profile company --profile team-backend
```

## What Gets Written Where

### `init` (user scope: `~/.claude/`)

| Profile field | Destination |
|--------------|-------------|
| `provider` | `~/.claude/settings.json` (env vars) |
| `claude_md` | `~/.claude/CLAUDE.md` |
| `mcp_servers` | Installed via `claude mcp add` |
| `hooks` | `~/.claude/settings.json` (hooks section) |
| `skills` | `~/.claude/commands/` |

### `scaffold` (project scope: `./.claude/`)

| Profile field | Destination |
|--------------|-------------|
| `project_template.claude_md` | `./.claude/CLAUDE.md` |
| `project_template.settings` | `./.claude/settings.json` |
| `project_template.commands` | `./.claude/commands/` |
| `project_template.rules` | `./.claude/rules/` |

## Creating Profiles

1. Create a YAML file in `profiles/`, e.g. `profiles/my-team.yaml`
2. Add the sections you need (all are optional)
3. Add any referenced templates/files to `templates/`
4. Test with `./corpo-claude preview --profile my-team`
5. Apply with `./corpo-claude init --profile my-team`

## Auth Validation

After `init`, corpo-claude checks if cloud provider credentials are
configured:

- **Vertex**: runs `gcloud auth application-default print-access-token`
- **Bedrock**: runs `aws sts get-caller-identity`

These are warnings only — init will succeed even if auth isn't configured yet.
