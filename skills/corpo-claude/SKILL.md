---
name: corpo-claude
description: Use corpo-claude to manage skills, profiles, registries, and fork parallel agents
---

# corpo-claude

corpo-claude is a Bash CLI that standardizes Claude Code configuration across teams. It distributes skills and profiles through a unified registry model. When the user asks you to use corpo-claude, run the commands below via Bash.

## Commands

### Skills

```bash
# Search for available skills across all registries
corpo-claude skill search [query]

# Install a skill (will prompt for scope: project or global)
corpo-claude skill install <name>
corpo-claude skill install <name> --project   # skip prompt, project scope
corpo-claude skill install <name> --global    # skip prompt, user scope

# List installed skills
corpo-claude skill list

# Uninstall a skill
corpo-claude skill uninstall <name>
```

### Profiles

```bash
# Search for available profiles
corpo-claude profile search [query]

# List available local profiles
corpo-claude profile list

# Apply a profile (will prompt for scope)
corpo-claude profile install --profile <name>
corpo-claude profile install --profile <name> --global
corpo-claude profile install --profile <name> --project

# Preview what a profile would write without applying
corpo-claude profile preview --profile <name>
```

### Fork — parallel sandboxed agents

Fork launches parallel Claude Code agents, each in its own git worktree and Docker Desktop sandbox. Create `.tasks/*.md` files describing units of work, then fork them.

```bash
# Fork all tasks in .tasks/
corpo-claude fork

# Fork a single task
corpo-claude fork .tasks/<task>.md

# Fork with a profile for provider credentials
corpo-claude fork .tasks/<task>.md --profile <name>

# Show running/completed forks
corpo-claude fork status

# Attach to a running sandbox
corpo-claude fork attach <name>

# Review completed forks — merge, PR, reject, or skip
corpo-claude fork review [name]

# Clean up finished worktrees (prompts to delete branches)
corpo-claude fork clean
```

Each task gets:
- A git worktree at `.worktrees/<task>` on branch `fork/<task>`
- A `TASK.md` copied into the worktree root
- A Docker sandbox with the task content as the prompt
- Provider credentials injected from the profile or auto-detected from the host

### Registries

```bash
# Add a remote registry (any GitHub repo with skills/ or profiles/ dirs)
corpo-claude registry add <owner/repo>

# List all registries
corpo-claude registry list

# Remove a registry
corpo-claude registry remove <owner/repo>
```

## Key concepts

- **Skills** are Claude Code slash commands (markdown files) installed to `~/.claude/commands/` (global) or `.claude/commands/` (project)
- **Profiles** bundle provider config, CLAUDE.md, MCP servers, hooks, and skills into a single installable unit
- **Registries** are GitHub repos with `skills/` and/or `profiles/` directories — corpo-claude itself is a registry
- **Fork** creates isolated git worktrees + Docker sandboxes for parallel agent execution
