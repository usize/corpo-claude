# corpo-claude

![corpo-claude-logo](./corpo-claude.png)

Standardize Claude Code configuration across teams. A Bash CLI that
distributes skills and profiles through a unified registry model — like
`brew` for Claude Code configuration.

## Requirements

- [gum](https://github.com/charmbracelet/gum) — interactive TUI
- [yq](https://github.com/mikefarah/yq) — YAML parsing
- [jq](https://github.com/jqlang/jq) — JSON manipulation
- [gh](https://cli.github.com/) — GitHub CLI (required for remote registries)

```bash
brew install gum yq jq gh
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

| Command | What it does |
|---------|-------------|
| `skill search [query]` | Search available skills across registries |
| `skill install <name>` | Install a skill (prompts for scope) |
| `skill uninstall <name>` | Remove an installed skill |
| `skill list` | Show installed skills |
| `profile search [query]` | Search available profiles across registries |
| `profile install` | Apply a profile (prompts for scope) |
| `profile list` | Show available local profiles |
| `profile preview` | Show what a profile would write (read-only) |
| `registry add <owner/repo>` | Add a registry |
| `registry remove <owner/repo>` | Remove a registry |
| `registry list` | Show all registries |

Both `skill install` and `profile install` prompt you to choose between
project scope (`.claude/`) and global scope (`~/.claude/`). Use `--project`
or `--global` to skip the prompt.

### Examples

```bash
# Search for skills
./corpo-claude skill search
./corpo-claude skill search pdf

# Install a skill (will prompt for scope)
./corpo-claude skill install pdf

# Skip the prompt with --project or --global
./corpo-claude skill install multi-agent-team --project
./corpo-claude skill install pdf --global

# List / uninstall
./corpo-claude skill list
./corpo-claude skill uninstall pdf

# Search for profiles
./corpo-claude profile search
./corpo-claude profile list

# Apply a profile (will prompt for scope)
./corpo-claude profile install --profile usize

# Skip the prompt
./corpo-claude profile install --profile usize --global
./corpo-claude profile install --profile usize --project

# Preview without applying
./corpo-claude profile preview --profile usize

# Manage registries
./corpo-claude registry add myorg/claude-config
./corpo-claude registry list
```

## Registry Model

corpo-claude itself is a registry. Any GitHub repo with `skills/` and/or
`profiles/` at the root follows the same structure and can be used as a
registry.

### Registry structure

```
my-registry/
  skills/
    my-skill/
      SKILL.md              # skill manifest (Claude Code slash command)
  profiles/
    my-team/
      profile.yaml          # profile manifest
      CLAUDE.md             # referenced files travel with the profile
      commands/
        commit.md
      rules/
        conventions.md
```

### Registry tiers (searched in order)

1. **Local** — The corpo-claude repo itself (`skills/` and `profiles/`)
2. **Default remote** — `anthropics/skills` (always present, cannot be removed)
3. **User-added remotes** — Added via `corpo-claude registry add <owner/repo>`

### How it works

- `search` queries all registries and shows available skills and profiles
- `install` copies a skill directory to `~/.claude/commands/<skill>/` (user)
  or `.claude/commands/<skill>/` (project with `--project`)
- `init`/`scaffold` apply profiles — local profiles work directly, remote
  profiles are downloaded on the fly
- Remote content is fetched via the GitHub API using `gh`
- Indexes are cached for 1 hour; use `--refresh` to bypass the cache
- Installed state is tracked in `~/.corpo-claude/installed.json`

## Profile Reference

Profiles are self-contained directories: `profiles/<name>/profile.yaml`
plus any files it references. All file paths in `profile.yaml` are relative
to the profile directory, making profiles portable across registries.

```yaml
# Optional description shown in search results
description: My team's Claude Code configuration

# Provider — configures Claude Code to use Vertex AI or Bedrock
provider:
  type: vertex              # vertex | bedrock
  region: global            # GCP region or AWS region

# User-scope CLAUDE.md — relative to profile directory
claude_md: CLAUDE.md

# MCP servers — installed via `claude mcp add`
mcp_servers:
  - name: context-mode
    type: npx               # npx | uvx
    package: context-mode

# Skills — relative to profile directory
skills:
  - skills/review.md

# Hooks — written to ~/.claude/settings.json
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./hooks/block-prod.sh"

# Project template — used by `scaffold` command
project_template:
  claude_md: project-CLAUDE.md
  settings:
    permissions:
      deny:
        - "Bash(rm -rf *)"
  commands:
    - commands/commit.md
  rules:
    - rules/api-conventions.md
```

### Multiple Profiles

When multiple profiles are applied, they are merged:
- **Arrays** (mcp_servers, skills, hooks, commands, rules) are accumulated
- **Scalars** (provider type, region, claude_md) use last-wins

File paths from each profile are resolved to absolute paths before merging,
so profiles from different registries can be combined.

```bash
./corpo-claude init --profile company --profile team-backend
```

## Creating a Registry

Any GitHub repo can be a corpo-claude registry. Just follow the structure:

1. Create `skills/<name>/SKILL.md` for skills
2. Create `profiles/<name>/profile.yaml` for profiles
3. Include any files referenced by profiles inside their directory
4. Push to GitHub
5. Users add it with `corpo-claude registry add <owner>/<repo>`

The corpo-claude repo itself is an example — it bundles the
`multi-agent-team` skill and the `usize` profile.

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

## Auth Validation

After `init`, corpo-claude checks if cloud provider credentials are
configured:

- **Vertex**: runs `gcloud auth application-default print-access-token`
- **Bedrock**: runs `aws sts get-caller-identity`

These are warnings only — init will succeed even if auth isn't configured yet.
