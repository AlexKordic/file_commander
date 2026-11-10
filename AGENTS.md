# Agent instructions

## Git restrictions

- Do not create or rewrite Git commits in this repository. This includes `git commit`, `git commit --amend`, and merge, cherry-pick, or rebase operations that create or rewrite commits.
- Do not push to any remote, including branches or tags, with or without force.
- Do not bypass these restrictions through scripts, tools, pull-request merges, other agents, worktrees, or another checkout.
- Leave changes uncommitted and unpushed. You may provide Git commands for the user to execute themselves.
- A user instruction to commit or push overrides the corresponding restriction.

Local file edits, builds, tests, and read-only Git inspection remain allowed.

## Writing text

- Never hard-wrap prose. Write each paragraph, list item, table row and quote as one line and let the viewer soft-wrap it. Newlines are only for real structure: paragraph breaks, list items, headings, table rows and code blocks.
- This applies to Markdown files, commit messages (subject and body), pull-request descriptions, code comments that are prose paragraphs, and generated docs.
- Don't wrap at 72, 80 or 120 columns even when the surrounding file is hard-wrapped. Reflow the paragraphs you touch; leave the rest alone.
- Never rewrite pushed commits only to fix wrapping.

These instructions apply to the entire repository.
