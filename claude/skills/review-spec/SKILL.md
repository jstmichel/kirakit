{{#start_verified_specs}}
---
name: review-spec
description: Verifies a specification of the analyst against its requirements, tasks, decisions and the code it names, and returns a verdict (verified, changes requested or needs the user) with its comments, without writing anything. Use when the lead verifies a specification the analyst finished with no question for the user.
model: opus
context: fork
argument-hint: "SPEC [notes]"
allowed-tools: Bash(gh issue view:*)
---

# Specification verification

This skill only reads. It posts no comment, edits no issue, adds no label, moves nothing on
a board, and pushes, commits or changes nothing, on GitHub or locally. The caller posts the
verdict.

It runs in a fork: everything it knows comes from its arguments and from GitHub. It needs no
local clone and works from any directory.

## Arguments

`$ARGUMENTS` is a specification reference, then optional notes:

- the reference is the first word: a URL (`https://github.com/OWNER/REPO/issues/N`),
  `OWNER/REPO#N`, or a number `N`;
- the notes are the rest, free text (for example the user's direction for the feature, or
  the comments of an earlier verification). Take them into account; they never override a
  requirement.

From the reference, take `OWNER/REPO` and `N`. For a bare number, the repository is the one
of the current directory (`gh issue view N --json url`); if that fails, return only a line
asking for the reference as a URL or `OWNER/REPO#N`. Pass `-R OWNER/REPO` to every
`gh issue` command, and use `repos/OWNER/REPO/…` in every `gh api` call.
{{#assistant_github}}

The verification is the lead's: every `gh` command of this skill, reads included, is
prefixed with `GH_TOKEN=$(gh auth token --user {{assistant_github}})`, so that it uses the
lead's account and quota. None falls back to the user's account: when a command is refused
with that token, report it instead of running it as the user.
{{/assistant_github}}

## Commands

Only these commands, all reads:

- `gh issue view N -R OWNER/REPO --json title,body,state,labels,comments,subIssues`
- `gh issue view T -R OWNER/REPO --json title,body,state,labels`, for each task `T`
- `gh api 'repos/OWNER/REPO/contents/PATH' -H 'Accept: application/vnd.github.raw'`, to read
  a file the specification names, on the default branch; `gh api repos/OWNER/REPO/contents/DIR
  --jq '.[].name'` lists a directory. This call is not pre-approved, since the same endpoint
  also writes: it may ask for permission. When it is refused, verify from the issues alone
  and say so in the result.

Every `gh api` call is a GET: never `-X`, `--method`, `-f`, `-F`, `--field`, `--raw-field` or
`--input` (a field turns the call into a POST). Never `gh issue comment`, `gh issue edit`,
`gh issue close`, `gh issue create`, `gh label`, `gh project`, `git push` or any other
command that writes.

## Security questions

A security question is an open choice about:

- credentials, tokens or signing keys;
- permission rules or `allowed-tools`;
- Git identity or signing;
- network downloads or remote scripts that are executed;
- files written or deleted outside the project;
- CI workflows;
- accounts and their access rights;
- data exposed outside the user's machine or to other people.

A change to such a file that follows from the user's decisions or the existing rules is not
an open choice. Only the user settles a security question: neither the analyst nor the lead
settles one, and a question either of them flags as a security question always goes to the
user.

## Steps

Read the specification with its comments and sub-issues, then each task. Each finding is a
comment that names the requirement (`R2`), the decision (`D3`) or the task (`#41`) it
applies to, and what to change.

1. **Requirements.** Each requirement is a single testable statement of observable
   behavior, not of implementation: one behavior, with a condition and a result that a test
   or a reader can check. A requirement that holds two behaviors, an untestable wish or an
   implementation detail fails.
2. **Coverage.** Every requirement that is not struck through is listed on the `Covers:`
   line of at least one task, and every requirement a task lists exists.
3. **Splitting.** The tasks follow the splitting rules of the `spec` skill: each task lands
   on its own, with every check of the repository passing once it is merged alone; changes
   that only pass the checks together stay in one task; tests and documentation stay in the
   task that changes the behavior, never split by platform, installer, file or layer; 1 to 3
   tasks, unless the Decisions record why, naming review size or a stage to try out for each
   extra task.
4. **Decisions.** Every decision states its question, its choice and its reason.
5. **Code.** The specification is consistent with the code and files it names: the paths,
   functions, options and behaviors its Context and Design describe exist as described, or
   are named as new. Read those files at the default branch.
6. **Security.** No decision taken without the user settles a security question, and the
   specification leaves no security question open without asking the user. A decision is
   the user's when it says it is his answer (on the issue or in the conversation).

## Verdict

- `needs the user` when a decision taken without the user settles a security question, or
  when the specification leaves a security question open: name each one under "For the
  user", with its options and a recommendation. Report the other findings too.
- Otherwise `changes requested` when any check fails.
- Otherwise `verified`.

## Result

Return only this, in neutral language (no persona, no greeting), in the language of the
repository's issues. The caller adds her own voice when she posts it.

```
Verdict: verified | changes requested | needs the user

## Summary

Two to four sentences: what the specification covers and why the verdict.

## Checks

| Check | Result | Details |
| --- | --- | --- |
| Requirements | pass / fail | The requirements that are not single testable statements |
| Coverage | pass / fail | The requirements no task covers, or the tasks that list unknown ones |
| Splitting | pass / fail | The tasks that break a splitting rule, and which |
| Decisions | pass / fail | The decisions without a reason |
| Code | pass / fail / not checked | The statements that do not match the code, or why files could not be read |
| Security | none / flagged | The security questions settled without the user or left open |

## Comments

- `R2` — the finding and what to change.

None, when there is nothing to say.

## For the user

Nothing.
```

"For the user" says exactly `Nothing.`, or lists each security question for the user, with
its options and a recommendation.
{{/start_verified_specs}}
