---
name: next-task
description: Finds the developer's next workable task from the project board, following the specifications the user moved to Ready, in order, and skipping tasks that are taken, blocked, waiting for an answer or overlapping a pull request in review. Use when the developer starts working and after each pull request she opens.
model: sonnet
context: fork
argument-hint: "[--as ACCOUNT]"
{{^start_verified_specs}}
allowed-tools: Bash(gh repo view:*), Bash(gh project list:*), Bash(gh project item-list:*), Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh pr list:*), Bash(gh pr view:*)
{{/start_verified_specs}}
{{#start_verified_specs}}
allowed-tools: Bash(gh repo view:*), Bash(gh project list:*), Bash(gh project item-list:*), Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh config get user -h github.com)
{{/start_verified_specs}}
---

# Next task

Answer in {{language}}.

Only read commands: `gh project`, `gh issue` and `gh pr`. This skill changes nothing; the
developer starts the task it gives.

## Account

{{#assistant_github}}
The account is ACCOUNT when `--as ACCOUNT` is given, and the developer's account,
`{{assistant_github}}`, otherwise. Every `gh` command of this skill, reads included, is
prefixed with `GH_TOKEN=$(gh auth token --user ACCOUNT)`, so that it uses that account and
its quota. None falls back to the user's account: when a command is refused with that
token, report it in one line with GitHub's error instead of running it as the user.
{{/assistant_github}}
{{^assistant_github}}
With `--as ACCOUNT`, every `gh` command of this skill, reads included, is prefixed with
`GH_TOKEN=$(gh auth token --user ACCOUNT)`, so that it uses that account and its quota. None
falls back to the user's account: when a command is refused with that token, report it in
one line with GitHub's error instead of running it as the user. Without `--as`, the
commands use the user's account.
{{/assistant_github}}

## 1. Specifications that can be worked on

A task is workable only while its specification is in **Ready** or **In progress**.

- Board: the repository owner (`gh repo view --json owner,nameWithOwner`), its boards
  (`gh project list --owner OWNER --format json`), and for each board the items
  (`gh project item-list BOARD --owner OWNER --limit 1000 --format json`), which come in
  board order. Keep the items of this repository whose `status` is Ready or In progress and
  whose labels include `type:feature`, in that order.
- No board: the open issues with both `type:feature` and `status:ready`
  (`gh issue list --label type:feature --label status:ready --state open`), oldest first.
{{#start_verified_specs}}

Then skip a specification that waits for a comment of the user: one whose comments
(`gh issue view <n> --json comments`) hold a comment of the user with no comment of a team
member after it. The user objects that way to a specification the lead moved to Ready; the
lead hands the comment to the analyst, whose answer ends the pause.
{{#team_github}}

- The user's login comes from `gh config get user -h github.com`, which calls no API: run it
  without the `GH_TOKEN` prefix.
- The team's accounts:
{{#assistant_github}}
  `{{assistant_github}}` (the lead),
{{/assistant_github}}
{{#analyst_github}}
  `{{analyst_github}}` (the analyst),
{{/analyst_github}}
{{#coder_github}}
  `{{coder_github}}` (the coder),
{{/coder_github}}
  as the session marker rule of `rules/git.md` names them.
- A team member's comment is a comment of a team account that ends with a session marker
  (`<!-- kirakit:` followed by the member's role).
- The user's comment is a comment of the user's login, or a comment of a team account
  without a session marker posted after the latest comment that carries one. A comment of
  any other account is neither: ignore it.
{{/team_github}}
{{^team_github}}

No member has a GitHub account of her own: the members comment as the user's account, and
their comments cannot be told from his. No specification is skipped this way.
{{/team_github}}
{{/start_verified_specs}}

## 2. Their tasks, in order

For each specification, `gh issue view <n> --json subIssues` gives its sub-issues in order.
Take the open ones, and skip a task when:

- it is In progress or In review on the board (it is taken);
- it is blocked by an open issue (`gh issue view <task> --json blockedBy`);
- its last comment is a question from the developer, with no answer after it
  (`gh issue view <task> --json comments`);
{{#assistant_github}}
  the developer's comments are those of `{{assistant_github}}`;
{{/assistant_github}}
- it touches the same files as an open pull request in review: compare the files the task
  names in its body with the files of each open pull request (`gh pr list --state open
  --json number,files`). A shared test file, such as `scripts/test.sh`, does not count.

The first task that is not skipped is the next task.

## 3. Then issues with no specification

When no specification gives a task, take the board's Ready items of this repository that
are issues with no parent (`gh issue view <n> --json parent`), in board order, with the
same skips.

## 4. Answer

- A task: "Next task: #<n> <title> (specification #<parent>)."
- None: "Nothing workable.", then one line per task skipped with its reason, for example
  "#91: blocked by #93."
{{#start_verified_specs}}
- In both cases, one line per specification skipped because it waits for a comment of the
  user, for example "Specification #90: paused by a comment of the user (<comment URL>)."
{{/start_verified_specs}}
