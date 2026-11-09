# Agent instructions

## Git restrictions

- Do not create or rewrite Git commits in this repository. This includes
  `git commit`, `git commit --amend`, and merge, cherry-pick, or rebase operations
  that create or rewrite commits.
- Do not push to any remote, including branches or tags, with or without force.
- Do not bypass these restrictions through scripts, tools, pull-request merges,
  other agents, worktrees, or another checkout.
- Leave changes uncommitted and unpushed. You may provide Git commands for the
  user to execute themselves.
- Requests to implement, fix, build, deploy, promote changes, or "do it" do not
  override these restrictions. Only an explicit user instruction changing the
  commit or push prohibition overrides the corresponding restriction.

Local file edits, builds, tests, and read-only Git inspection remain allowed.
These instructions apply to the entire repository.
