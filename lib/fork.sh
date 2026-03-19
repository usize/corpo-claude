#!/usr/bin/env bash
# lib/fork.sh — Parallel agents via git worktrees + Docker containers
#
# Uses plain docker run with a locally-built Claude Code image.

CLAUDE_CODE_IMAGE="${CLAUDE_CODE_IMAGE:-corpo-claude:latest}"

# ── Image management ──────────────────────────────────────────

# Build the corpo-claude Docker image if it doesn't exist.
_ensure_image() {
  if docker image inspect "$CLAUDE_CODE_IMAGE" &>/dev/null; then
    return 0
  fi

  info "Building $CLAUDE_CODE_IMAGE image (first run only)..."
  local dockerfile_dir
  dockerfile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ ! -f "$dockerfile_dir/Dockerfile" ]]; then
    error "Dockerfile not found at $dockerfile_dir/Dockerfile"
    return 1
  fi

  docker build -t "$CLAUDE_CODE_IMAGE" "$dockerfile_dir" || {
    error "Failed to build Docker image"
    return 1
  }
  success "Built $CLAUDE_CODE_IMAGE"
}

# ── Container helpers ─────────────────────────────────────────

# Get the status of a container by name. Returns empty string if not found.
_container_status() {
  local name="$1"
  docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true
}

# Check if a container exists by name.
_container_exists() {
  local name="$1"
  docker inspect "$name" &>/dev/null
}

# ── Command router ────────────────────────────────────────────

cmd_fork() {
  local subcmd="${1:-}"

  case "$subcmd" in
    status)
      shift
      cmd_fork_status "$@"
      ;;
    attach)
      shift
      cmd_fork_attach "$@"
      ;;
    review)
      shift
      cmd_fork_review "$@"
      ;;
    clean)
      shift
      cmd_fork_clean "$@"
      ;;
    --help|-h)
      _fork_usage
      ;;
    "")
      # No args — fork all tasks in .tasks/
      cmd_fork_run
      ;;
    --dangerously-skip-permissions)
      cmd_fork_run "$@"
      ;;
    *)
      # Treat as task file path or unknown subcommand
      if [[ -f "$subcmd" || "$subcmd" == *.md ]]; then
        cmd_fork_run "$@"
      else
        error "Unknown fork subcommand: $subcmd"
        echo ""
        _fork_usage
        exit 1
      fi
      ;;
  esac
}

_fork_usage() {
  cat <<EOF
Usage:
  corpo-claude fork [task.md]        Fork one task or all in .tasks/
  corpo-claude fork status           Show running/completed forks
  corpo-claude fork attach <name>    Attach to a running sandbox
  corpo-claude fork review [name]    Review and merge/reject completed forks
  corpo-claude fork clean            Remove finished worktrees

Examples:
  corpo-claude fork                              # Fork all tasks in .tasks/
  corpo-claude fork .tasks/refactor-auth.md      # Fork a single task
  corpo-claude fork status
  corpo-claude fork attach refactor-auth
  corpo-claude fork review                          # Review all completed forks
  corpo-claude fork review refactor-auth            # Review a single fork
  corpo-claude fork clean
EOF
}

# ── fork run ──────────────────────────────────────────────────

cmd_fork_run() {
  check_sandbox_dependencies || exit 1
  _ensure_image || exit 1

  # Must be inside a git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    error "Not inside a git repository. fork requires a git repo."
    return 1
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  # ── Parse arguments ───────────────────────────────────────
  local task_file=""
  local skip_permissions_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dangerously-skip-permissions)
        skip_permissions_flag=true
        shift
        ;;
      --help|-h)
        _fork_usage
        return 0
        ;;
      *)
        if [[ -z "$task_file" ]]; then
          task_file="$1"
        else
          error "Unexpected argument: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  # ── Resolve task files ────────────────────────────────────
  # Picks up .md (pending) and .md.started (interrupted). Skips .md.complete.
  local task_files=()

  if [[ -n "$task_file" ]]; then
    if [[ ! -f "$task_file" ]]; then
      error "Task file not found: $task_file"
      return 1
    fi
    task_files+=("$(cd "$(dirname "$task_file")" && pwd)/$(basename "$task_file")")
  else
    local tasks_dir="$repo_root/.tasks"
    if [[ ! -d "$tasks_dir" ]]; then
      error "No .tasks/ directory found. Create .tasks/*.md files or specify a task file."
      return 1
    fi

    # Gather pending (.md) and interrupted (.md.started) tasks
    local found=false
    for f in "$tasks_dir"/*.md "$tasks_dir"/*.md.started; do
      [[ -f "$f" ]] || continue
      task_files+=("$f")
      found=true
    done

    if [[ "$found" == false ]]; then
      error "No task files found in .tasks/ (all may be .md.complete)"
      return 1
    fi
  fi

  header "corpo-claude fork"
  echo ""
  info "Tasks: ${#task_files[@]}"

  # ── Skip-permissions: flag or interactive prompt ────────
  local skip_permissions="$skip_permissions_flag"
  if [[ "$skip_permissions" == false && -t 0 ]]; then
    if gum confirm "Skip permission prompts in sandboxes? (--dangerously-skip-permissions)"; then
      skip_permissions=true
    fi
  fi

  # ── Launch a fork per task ────────────────────────────────
  local launched_names=()
  for tf in "${task_files[@]}"; do
    _launch_fork "$repo_root" "$tf" "$skip_permissions"
  done

  echo ""
  success "All forks launched."
  echo ""

  if [[ ${#launched_names[@]} -gt 0 ]]; then
    info "Attach to manage each sandbox:"
    for name in "${launched_names[@]}"; do
      gum style --foreground 250 "  corpo-claude fork attach $name"
    done
    echo ""
  fi

  info "Check progress with: corpo-claude fork status"
}

# ── Launch one fork ──────────────────────────────────────────

_launch_fork() {
  local repo_root="$1"
  local task_file="$2"
  local skip_permissions="${3:-false}"

  # ── Derive name and paths ─────────────────────────────────
  # Strip both .md and .md.started extensions to get the base name
  local task_filename
  task_filename="$(basename "$task_file")"

  local task_basename="${task_filename%.md.started}"
  task_basename="${task_basename%.md}"

  local tasks_dir
  tasks_dir="$(dirname "$task_file")"
  local pending_file="$tasks_dir/$task_basename.md"
  local started_file="$tasks_dir/$task_basename.md.started"
  local complete_file="$tasks_dir/$task_basename.md.complete"

  local worktree_dir="$repo_root/.worktrees/$task_basename"
  local branch_name="fork/$task_basename"
  local container_name="fork-$task_basename"

  echo ""
  info "Task: $task_basename"

  # ── Check file-based state ────────────────────────────────
  # .md.complete → done, skip
  if [[ -f "$complete_file" ]]; then
    success "Complete — skipping"
    return 0
  fi

  # .md.started → interrupted, resume
  local resume=false
  if [[ -f "$started_file" ]]; then
    # Check if container is still running
    local container_state
    container_state="$(_container_status "$container_name")"

    if [[ "$container_state" == "running" ]]; then
      warn "Still running — skipping"
      return 0
    fi

    # Remove old container if it exists
    docker rm -f "$container_name" &>/dev/null || true

    warn "Interrupted — resuming with --continue"
    resume=true
    task_file="$started_file"
  fi

  # ── Create worktree if needed ─────────────────────────────
  if [[ -d "$worktree_dir" ]]; then
    [[ "$resume" == true ]] || warn "Worktree already exists: $worktree_dir (skipping creation)"
  else
    if ! git worktree add "$worktree_dir" -b "$branch_name" 2>/dev/null; then
      # Branch may already exist — try without -b
      if ! git worktree add "$worktree_dir" "$branch_name" 2>/dev/null; then
        error "Failed to create worktree for $task_basename"
        return 1
      fi
    fi
    success "Created worktree: $worktree_dir (branch: $branch_name)"
  fi

  # Copy task content into worktree root as TASK.md
  cp "$task_file" "$worktree_dir/TASK.md"

  # ── Rename task file to .started ──────────────────────────
  if [[ "$resume" == false ]]; then
    mv "$task_file" "$started_file"
    task_file="$started_file"
  fi

  # ── Build docker run command ─────────────────────────────
  local docker_cmd=("docker" "run" "-d" "--name" "$container_name"
    "--user" "$(id -u):$(id -g)")

  # Forward provider env vars from host
  local env_var
  for env_var in \
    ANTHROPIC_API_KEY \
    CLAUDE_CODE_USE_VERTEX CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID \
    CLAUDE_CODE_USE_BEDROCK AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
    NODE_EXTRA_CA_CERTS; do
    if [[ -n "${!env_var:-}" ]]; then
      docker_cmd+=("-e" "$env_var=${!env_var}")
    fi
  done

  # Mount worktree as workspace
  docker_cmd+=("-v" "$worktree_dir:/workspace")
  docker_cmd+=("-w" "/workspace")

  # Mount gcloud ADC if present (for Vertex auth)
  local gcloud_adc="$HOME/.config/gcloud/application_default_credentials.json"
  if [[ -f "$gcloud_adc" ]]; then
    docker_cmd+=("-v" "$HOME/.config/gcloud:/home/claude/.config/gcloud:ro")
  fi

  # Mount ~/.claude for settings/auth (read-only — container writes to its own home)
  if [[ -d "$HOME/.claude" ]]; then
    docker_cmd+=("-v" "$HOME/.claude:/home/claude/.claude:ro")
  fi

  # Mount NODE_EXTRA_CA_CERTS file if set (for corporate proxies)
  if [[ -n "${NODE_EXTRA_CA_CERTS:-}" && -f "$NODE_EXTRA_CA_CERTS" ]]; then
    docker_cmd+=("-v" "$NODE_EXTRA_CA_CERTS:$NODE_EXTRA_CA_CERTS:ro")
  fi

  # Image
  docker_cmd+=("$CLAUDE_CODE_IMAGE")

  # Claude args
  if [[ "$skip_permissions" == true ]]; then
    docker_cmd+=("--dangerously-skip-permissions")
  fi

  if [[ "$resume" == true ]]; then
    docker_cmd+=("--continue")
  fi

  docker_cmd+=("-p" "$(cat "$task_file")")

  # Launch
  local display_cmd="${docker_cmd[*]}"
  # Redact secrets from display
  for env_var in ANTHROPIC_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    if [[ -n "${!env_var:-}" ]]; then
      display_cmd="${display_cmd//${!env_var}/***}"
    fi
  done
  gum style --foreground 250 "  $display_cmd"
  "${docker_cmd[@]}" >/dev/null
  success "Launched container: $container_name"

  # Track for attach instructions
  launched_names+=("$task_basename")

  # ── Background watcher: rename to .complete on clean exit ─
  (
    exit_code="$(docker wait "$container_name" 2>/dev/null || echo 1)"
    if [[ "$exit_code" == "0" ]]; then
      mv "$started_file" "$complete_file" 2>/dev/null || true
    fi
  ) &
}

# ── fork status ──────────────────────────────────────────────

cmd_fork_status() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    error "Not inside a git repository."
    return 1
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local tasks_dir="$repo_root/.tasks"

  header "corpo-claude fork status"
  echo ""

  if [[ ! -d "$tasks_dir" ]]; then
    info "No .tasks/ directory found."
    return 0
  fi

  # Gather all task files across states
  local found=false

  printf "%-25s %-12s %-25s %s\n" "TASK" "STATE" "CONTAINER" "COMMITS"
  printf "%-25s %-12s %-25s %s\n" "----" "-----" "---------" "-------"

  for f in "$tasks_dir"/*.md "$tasks_dir"/*.md.started "$tasks_dir"/*.md.complete; do
    [[ -f "$f" ]] || continue
    found=true

    local filename
    filename="$(basename "$f")"

    # Derive task name by stripping extensions
    local task_name="${filename%.md.complete}"
    task_name="${task_name%.md.started}"
    task_name="${task_name%.md}"

    local branch_name="fork/$task_name"
    local container_name="fork-$task_name"

    # File-based state
    local state
    case "$filename" in
      *.md.complete) state="complete" ;;
      *.md.started)  state="started" ;;
      *.md)          state="pending" ;;
    esac

    # Container info
    local container_info="—"
    local container_state
    container_state="$(_container_status "$container_name")"
    if [[ -n "$container_state" ]]; then
      container_info="$container_state"
    fi

    # Commit count
    local commit_count="—"
    if git rev-parse --verify "$branch_name" &>/dev/null; then
      commit_count="$(git rev-list HEAD.."$branch_name" --count 2>/dev/null || echo "?")"
    fi

    printf "%-25s %-12s %-25s %s\n" "$task_name" "$state" "$container_info" "$commit_count"
  done

  if [[ "$found" == false ]]; then
    info "No task files found."
  fi
}

# ── fork attach ──────────────────────────────────────────────

cmd_fork_attach() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    error "Usage: corpo-claude fork attach <name>"
    return 1
  fi

  check_sandbox_dependencies || exit 1

  local container_name="fork-$name"

  # Check container exists
  if ! _container_exists "$container_name"; then
    error "Container not found: $container_name"
    info "Run 'corpo-claude fork status' to see available containers."
    return 1
  fi

  info "Attaching to $container_name..."
  exec docker attach "$container_name"
}

# ── fork review ──────────────────────────────────────────────

cmd_fork_review() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    error "Not inside a git repository."
    return 1
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local worktrees_dir="$repo_root/.worktrees"
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"

  local target_name="${1:-}"

  # ── Single fork by name ──────────────────────────────────
  if [[ -n "$target_name" ]]; then
    local wt_dir="$worktrees_dir/$target_name"
    if [[ ! -d "$wt_dir" ]]; then
      error "Worktree not found: $target_name"
      echo ""
      info "Available worktrees:"
      if [[ -d "$worktrees_dir" ]]; then
        for d in "$worktrees_dir"/*/; do
          [[ -d "$d" ]] && info "  $(basename "$d")"
        done
      else
        info "  (none)"
      fi
      return 1
    fi

    REVIEW_RESULT=""
    _review_single_fork "$repo_root" "$target_name" "$current_branch"
    return 0
  fi

  # ── Review all completed forks ───────────────────────────
  if [[ ! -d "$worktrees_dir" ]]; then
    info "No .worktrees/ directory found. Nothing to review."
    return 0
  fi

  local has_forks=false
  for d in "$worktrees_dir"/*/; do
    [[ -d "$d" ]] && has_forks=true && break
  done

  if [[ "$has_forks" == false ]]; then
    info "No forks to review."
    return 0
  fi

  header "corpo-claude fork review"
  echo ""

  local count_accept=0 count_pr=0 count_reject=0 count_skip=0

  for wt_dir in "$worktrees_dir"/*/; do
    [[ -d "$wt_dir" ]] || continue

    local task_name
    task_name="$(basename "$wt_dir")"
    local container_name="fork-$task_name"

    # Skip running containers
    local container_state
    container_state="$(_container_status "$container_name")"
    if [[ "$container_state" == "running" ]]; then
      warn "Skipping $task_name — container is still running"
      echo ""
      continue
    fi

    REVIEW_RESULT=""
    _review_single_fork "$repo_root" "$task_name" "$current_branch"

    case "$REVIEW_RESULT" in
      accept) count_accept=$((count_accept + 1)) ;;
      pr)     count_pr=$((count_pr + 1)) ;;
      reject) count_reject=$((count_reject + 1)) ;;
      skip)   count_skip=$((count_skip + 1)) ;;
    esac
  done

  echo ""
  success "Review complete: $count_accept accepted, $count_pr PR, $count_reject rejected, $count_skip skipped"
}

_review_single_fork() {
  local repo_root="$1"
  local task_name="$2"
  local current_branch="$3"

  local branch_name="fork/$task_name"
  local worktree_dir="$repo_root/.worktrees/$task_name"

  # ── Header ───────────────────────────────────────────────
  gum style --bold --border rounded --padding "0 2" --border-foreground 39 "Reviewing: $task_name"
  info "Branch: $branch_name"

  # ── Verify branch exists ─────────────────────────────────
  if ! git rev-parse --verify "$branch_name" &>/dev/null; then
    warn "Branch $branch_name does not exist — skipping"
    REVIEW_RESULT="skip"
    echo ""
    return 0
  fi

  # ── Auto-commit uncommitted work ─────────────────────────
  _auto_commit_worktree "$worktree_dir" "$task_name"

  # ── Show summary ─────────────────────────────────────────
  _show_fork_summary "$branch_name" "$current_branch"

  # ── Offer diff view ──────────────────────────────────────
  if gum confirm "View diff?"; then
    _show_fork_diff "$branch_name" "$current_branch"
  fi

  # ── Choose action ────────────────────────────────────────
  local action
  action=$(gum choose --header "Action for \"$task_name\":" \
    "Accept (merge into $(git rev-parse --abbrev-ref HEAD))" \
    "PR (push branch and open pull request)" \
    "Reject (delete branch and worktree)" \
    "Skip (decide later)")

  case "$action" in
    Accept*)
      _accept_fork "$repo_root" "$task_name" "$branch_name" "$current_branch"
      REVIEW_RESULT="accept"
      ;;
    PR*)
      _pr_fork "$repo_root" "$task_name" "$branch_name"
      REVIEW_RESULT="pr"
      ;;
    Reject*)
      if gum confirm "Delete branch, worktree, and container for $task_name?"; then
        _reject_fork "$repo_root" "$task_name" "$branch_name"
        REVIEW_RESULT="reject"
      else
        info "Skipped"
        REVIEW_RESULT="skip"
      fi
      ;;
    Skip*)
      info "Skipped — fork remains for later review"
      REVIEW_RESULT="skip"
      ;;
  esac

  echo ""
}

_auto_commit_worktree() {
  local worktree_dir="$1"
  local task_name="$2"

  # Remove TASK.md (runtime artifact, not deliverable)
  rm -f "$worktree_dir/TASK.md"

  # Check for uncommitted changes
  local status_output
  status_output="$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)"

  if [[ -z "$status_output" ]]; then
    return 0
  fi

  info "Auto-committing uncommitted agent work..."
  git -C "$worktree_dir" add -A
  git -C "$worktree_dir" commit -m "fork($task_name): agent work" --no-verify --quiet
  local stat
  stat="$(git -C "$worktree_dir" diff --stat HEAD~1 2>/dev/null || true)"
  success "Committed: $stat"
}

_show_fork_summary() {
  local branch_name="$1"
  local current_branch="$2"

  local commit_count
  commit_count="$(git rev-list "$current_branch".."$branch_name" --count 2>/dev/null || echo 0)"

  echo ""
  if [[ "$commit_count" -eq 0 ]]; then
    info "No new commits on $branch_name"
  else
    info "$commit_count commit(s) ahead of $current_branch"
  fi

  local diffstat
  diffstat="$(git diff --stat "$current_branch"..."$branch_name" 2>/dev/null || true)"
  if [[ -n "$diffstat" ]]; then
    echo "$diffstat"
  else
    info "No file changes"
  fi
  echo ""
}

_show_fork_diff() {
  local branch_name="$1"
  local current_branch="$2"

  git diff "$current_branch"..."$branch_name" | gum pager --soft-wrap
}

_accept_fork() {
  local repo_root="$1"
  local task_name="$2"
  local branch_name="$3"
  local current_branch="$4"

  info "Merging $branch_name into $current_branch..."

  if ! git merge --no-ff "$branch_name" -m "Merge $branch_name" 2>/dev/null; then
    error "Merge conflict! Resolve manually, then run:"
    gum style --foreground 250 "  git merge --continue"
    gum style --foreground 250 "  corpo-claude fork clean"
    warn "Leaving branch and worktree intact for conflict resolution."
    return 1
  fi

  success "Merged $branch_name"
  _cleanup_fork "$repo_root" "$task_name" "$branch_name"
}

_pr_fork() {
  local repo_root="$1"
  local task_name="$2"
  local branch_name="$3"

  # Check for gh CLI
  if ! command -v gh &>/dev/null; then
    error "gh CLI is required for PR creation."
    gum style --foreground 250 "  Install: brew install gh  (https://cli.github.com/)"
    info "Skipping — fork remains for later review"
    REVIEW_RESULT="skip"
    return 0
  fi

  # Check for remote
  if ! git remote get-url origin &>/dev/null; then
    error "No git remote 'origin' found. Cannot push branch."
    info "Consider using Accept to merge locally instead."
    REVIEW_RESULT="skip"
    return 0
  fi

  info "Pushing $branch_name to origin..."
  git push -u origin "$branch_name"

  info "Creating pull request..."
  local pr_url
  pr_url=$(gh pr create \
    --title "fork: $task_name" \
    --body "Automated agent work from \`corpo-claude fork\`." \
    --head "$branch_name" 2>&1) || {
    error "Failed to create PR: $pr_url"
    REVIEW_RESULT="skip"
    return 0
  }

  success "PR created: $pr_url"

  # Clean up worktree and container only (keep branch since it's remote-tracked)
  local container_name="fork-$task_name"
  if _container_exists "$container_name"; then
    docker rm -f "$container_name" &>/dev/null || true
  fi
  git worktree remove "$repo_root/.worktrees/$task_name" --force 2>/dev/null || true
}

_reject_fork() {
  local repo_root="$1"
  local task_name="$2"
  local branch_name="$3"

  _cleanup_fork "$repo_root" "$task_name" "$branch_name"
  success "Rejected and cleaned up: $task_name"
}

_cleanup_fork() {
  local repo_root="$1"
  local task_name="$2"
  local branch_name="$3"

  local container_name="fork-$task_name"

  # Remove container if it exists
  if _container_exists "$container_name"; then
    docker rm -f "$container_name" &>/dev/null || true
  fi

  # Remove worktree
  git worktree remove "$repo_root/.worktrees/$task_name" --force 2>/dev/null || true

  # Delete branch
  git branch -D "$branch_name" &>/dev/null || true

  # Remove task completion marker
  rm -f "$repo_root/.tasks/$task_name.md.complete"
}

# ── fork clean ───────────────────────────────────────────────

cmd_fork_clean() {
  check_sandbox_dependencies || exit 1

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    error "Not inside a git repository."
    return 1
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local worktrees_dir="$repo_root/.worktrees"

  if [[ ! -d "$worktrees_dir" ]]; then
    info "No .worktrees/ directory found. Nothing to clean."
    return 0
  fi

  header "corpo-claude fork clean"
  echo ""

  local cleaned=0

  for wt_dir in "$worktrees_dir"/*/; do
    [[ ! -d "$wt_dir" ]] && continue

    local task_name
    task_name="$(basename "$wt_dir")"
    local container_name="fork-$task_name"
    local branch_name="fork/$task_name"

    # Check if container is still running
    local container_state
    container_state="$(_container_status "$container_name")"

    if [[ "$container_state" == "running" ]]; then
      warn "Skipping $task_name — container is still running"
      continue
    fi

    info "Cleaning $task_name (container: ${container_state:-gone})"

    # Remove the container if it exists
    if [[ -n "$container_state" ]]; then
      docker rm -f "$container_name" &>/dev/null || true
    fi

    # Remove worktree
    git worktree remove "$worktrees_dir/$task_name" --force 2>/dev/null || {
      warn "Could not remove worktree: $task_name"
      continue
    }
    success "Removed worktree: $task_name"

    # Prompt to delete branch
    if git rev-parse --verify "$branch_name" &>/dev/null; then
      if gum confirm "Delete branch $branch_name?"; then
        git branch -D "$branch_name" &>/dev/null
        success "Deleted branch: $branch_name"
      else
        info "Keeping branch: $branch_name"
      fi
    fi

    cleaned=$((cleaned + 1))
  done

  echo ""
  if [[ "$cleaned" -eq 0 ]]; then
    info "Nothing to clean."
  else
    success "Cleaned $cleaned fork(s)."
  fi
}
