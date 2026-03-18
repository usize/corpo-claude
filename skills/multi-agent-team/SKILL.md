---
name: multi-agent-team
description: Coordinate multiple Claude agents working in parallel via git worktrees
---

# Multi-Agent Team Coordination

You are the **lead agent** coordinating a team of Claude agents working on a shared codebase. Follow this workflow to divide work, prevent conflicts, and integrate results.

## 1. Create the coordination directory

Create a `.team/` directory in the project root with these files:

```
.team/
  PLAN.md        # Overall plan, interface contracts, task breakdown
  STATUS.md      # Per-agent progress tracking
  agents/        # One file per agent defining its role and scope
```

### PLAN.md template

```markdown
# Team Plan

## Objective
[What the team is building/fixing]

## Interface Contracts
[Define shared interfaces, APIs, types, or file boundaries BEFORE agents start.
This prevents integration conflicts.]

- **Contract 1**: [e.g., API endpoint shape, shared type definitions]
- **Contract 2**: [e.g., Database schema, event names]

## Task Breakdown
| Task | Agent | Files/Directories | Status |
|------|-------|-------------------|--------|
| ...  | ...   | ...               | ...    |
```

### STATUS.md template

```markdown
# Team Status

## agent-1: [role]
- [ ] Task description
- Current: [what they're working on]
- Blockers: [none or description]

## agent-2: [role]
- [ ] Task description
- Current: [what they're working on]
- Blockers: [none or description]
```

## 2. Define agent scopes

For each agent, create `.team/agents/<agent-name>.md`:

```markdown
# Agent: [name]

## Role
[What this agent is responsible for]

## Owned Files
[List of files/directories this agent may modify — NO overlap with other agents]

## Inputs
[What this agent needs from other agents or contracts]

## Outputs
[What this agent produces for others]
```

**Critical rule**: Agent file scopes must NOT overlap. If two agents need to modify the same file, either:
- Split the file first
- Assign one agent as owner and have the other produce a patch/suggestion

## 3. Set up git worktrees

Create a worktree per agent so they can work in parallel without stepping on each other:

```bash
# From the main repo
git worktree add ../<project>-agent-1 -b agent-1
git worktree add ../<project>-agent-2 -b agent-2
```

Each agent works in its own worktree on its own branch.

## 4. Launch agents

Start each agent in its worktree with a prompt that includes:
1. The contents of `.team/PLAN.md` (interface contracts)
2. The contents of their `.team/agents/<name>.md` (scope and role)
3. Instructions to update `.team/STATUS.md` in the main worktree when they complete milestones

## 5. Integration workflow

When agents finish their tasks, the **lead agent** integrates:

```bash
# In the main worktree
git merge agent-1 --no-ff -m "Integrate agent-1: [description]"
git merge agent-2 --no-ff -m "Integrate agent-2: [description]"
```

If there are conflicts:
1. Review the interface contracts in PLAN.md
2. The agent whose scope owns the conflicting file resolves
3. If scope is ambiguous, the lead agent resolves

## 6. Cleanup

After integration:

```bash
git worktree remove ../<project>-agent-1
git worktree remove ../<project>-agent-2
git branch -d agent-1 agent-2
```

## Guidelines

- **Plan first**: Always complete PLAN.md with interface contracts before any agent starts coding
- **Non-overlapping scopes**: Never assign the same file to multiple agents
- **Small, focused agents**: Each agent should have 1-3 clear tasks, not a vague mandate
- **Status updates**: Agents write to STATUS.md so the lead can track progress
- **Contract-driven**: When agents depend on each other, define the contract (types, API shape, file format) upfront in PLAN.md
- **Incremental merges**: Merge frequently rather than letting branches diverge far
