---
name: spec
description: Turns an idea into a feature specification (context, requirements, design, decisions, tasks) in a GitHub issue, settling on its own the questions that have a good answer and asking only about real trade-offs, and creates each task as a sub-issue. Starts from an idea issue, an existing specification to resume, a specification file, or a description. Use when the user asks to specify, spec out, clarify or plan a feature or an idea.
model: opus
argument-hint: "[issue number or URL, path to a specification file, or a description]"
allowed-tools: Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh label list:*), Bash(gh repo view:*), Bash(git log:*), Bash(git status:*), Read, Grep, Glob
---

# Feature specification

Answer in {{language}}. The specification itself is written in neutral English, unless the
repository already uses another language. The comments posted on the issue
follow the member's own voice, in the repository's language.
{{#analyst_github}}

The analyst's work is done on GitHub as the analyst's own account, `{{analyst_github}}`,
whoever runs this skill: every `gh` command of this skill, reads included, is prefixed with
`GH_TOKEN=$(gh auth token --user {{analyst_github}})`, for example
`GH_TOKEN=$(gh auth token --user {{analyst_github}}) gh issue create …`. None falls back to
the user's account: when a command is refused with that token, report it instead of running
it as the user. Every comment this skill posts, its comment files included, ends with the
analyst's session marker, alone on its last line: `<!-- kirakit:analyst -->`
(`rules/git.md`). Issue bodies stay unmarked.
{{/analyst_github}}
{{^analyst_github}}
{{#assistant_github}}

This work is done on GitHub as the developer's own account, `{{assistant_github}}`: every
`gh` command of this skill, reads included, is prefixed with
`GH_TOKEN=$(gh auth token --user {{assistant_github}})`, for example
`GH_TOKEN=$(gh auth token --user {{assistant_github}}) gh issue create …`. None falls back
to the user's account: when a command is refused with that token, report it instead of
running it as the user. Every comment this skill posts, its comment files included, ends
with the assistant's session marker, alone on its last line: `<!-- kirakit:assistant -->`
(`rules/git.md`). Issue bodies stay unmarked.
{{/assistant_github}}
{{/analyst_github}}

## Format

The specification lives in one issue, the parent. Its title states the feature, without a
prefix. Its body uses these sections, in this order, with the same headings as the
"Feature request" issue form. A section not written yet holds `_To be written._`.

```markdown
### Context

The problem to solve and why it matters now.

### Requirements

- **R1** — When …, the … shall …
- **R2** — …

### Design

How the requirements will be met, and the trade-offs considered.

### Decisions

- **D1** — <question>: <choice>. <reason>

### Tasks

Tracked as sub-issues.

### Open questions

- …
```

- **Requirements** are numbered `R1`, `R2`, … and never renumbered: a dropped requirement
  stays, struck through (`~~**R3** — …~~`), so references to it keep their meaning. Each one
  is a single testable statement of observable behavior, not of implementation.
- **Design** names the modules touched, the data and interfaces, and the alternatives
  rejected with the reason. It stays short; link files as `path:line` when useful.
- **Decisions** records every question settled without the user (step 2), and the user's
  answers, with the question, the choice and the reason. They are numbered `D1`, `D2`, …
  and never renumbered, like the requirements; `None` when there are none.
- **Open questions** lists what is still undecided, or `None`.

Each task is a sub-issue of the parent:

- Title: imperative, specific, at most 72 characters (e.g. "Parse the retry delay from
  the config file").
- Body:

  ```markdown
  Part of #<parent>.

  Covers: R1, R3

  <What to change, in a few lines.>

  ### Done when

  - <Observable result, usually the test that proves it.>
  ```

- Each task lists the requirements it covers. Every requirement is covered by at least one
  task.

### Splitting into tasks

- Each task lands on its own: once merged alone on `main`, every check of the repository
  passes, and no task waits for another to make its change usable or consistent.
- Changes that only pass the repository's checks together (such as the sh and PowerShell
  sides of an installer change held by a parity check) stay in the same task.
- The tests and the documentation of a behavior stay in the task that changes that
  behavior, never in a task of their own. Never split by platform, by installer, by file or
  by layer (code, tests, documentation).
- Start from one task covering the whole specification. Split off a part only when it lands
  on its own and either the single pull request would be too large to review in one pass,
  or the user gains from using that part before the rest (a stage to try out). As a
  guideline, not a limit, a pull request of more than about 400 changed lines outside tests,
  or one that mixes unrelated areas a reviewer must load separately, is too large for one
  pass.
- A specification has 1 to 3 tasks by default. Beyond 3, its Decisions record why, naming
  for each extra task the reason that keeps it separate (review size or a stage to try
  out).

Labels: the parent has `type:feature`, plus `status:specified` once its tasks are
published; sub-issues have `type:task`.

## 1. Start from the input

Read `$ARGUMENTS`:

- **An issue** (`#12` or a URL): `gh issue view <n> --json number,title,body,labels,assignees,parent,subIssues`.
  - An **idea** (label `type:idea`, a `[IDEA] ` title, or the headings of the "Idea" form:
    Problem or opportunity, Desired outcome, …): start with step 2.
{{#analyst_github}}
    When the idea is not assigned to `{{analyst_github}}`, the owner of ideas, add it before
    posting questions or publishing, and leave the other assignees in place:
    `gh issue edit <n> --add-assignee {{analyst_github}}`.
{{/analyst_github}}
{{^analyst_github}}
{{#assistant_github}}
    When the idea is not assigned to `{{assistant_github}}`, the owner of ideas, add it before
    posting questions or publishing, and leave the other assignees in place:
    `gh issue edit <n> --add-assignee {{assistant_github}}`.
{{/assistant_github}}
{{/analyst_github}}
  - A **specification**: resume at the first phase whose section is missing, empty, or
    `_To be written._`. Show what is already there in two or three lines first.
  - Read its comments too (`gh issue view <n> --comments`). When the user answered a
    comment of questions (step 2), take those answers and resume where the questions
    stopped, without asking for them again in the conversation.
{{#team_github}}
    A comment is the user's answer under the rule of `rules/git.md` ("Session marker and
    the user's replies"): written by the user's account, or by a team member's account
    without a session marker after the latest marked comment of the issue, never by
    another account. An answer posted from a team account is attributed to the user in the
    next comment, as that rule says.
{{/team_github}}
{{#analyst}}
  - Answers the lead relays from the conversation are the user's answers: record them under
    Decisions as the user's, noted "answered in the conversation", and resume from them.
{{/analyst}}
- **A file** (a specification kept in the repository): read it and map its content onto
  the format, then resume like a specification. Once the issue exists, offer to delete the
  file in a separate commit.
- **A description** or nothing: ask what the feature is for, in one or two questions at
  most, then go to step 3.

Read the code that the feature touches before writing anything, so the specification
matches the repository.

## 2. Settle the questions

Before writing any requirement, compare the idea with the code: what already exists, what
is missing (`path:line`). Then take the idea's open questions and the ones the analysis
raised, and sort each one:

{{^start_verified_specs}}
- **Settle it** when it has a good answer: the code, an existing convention, the text of
  the idea or an earlier decision settles it, or its options are easy to change later.
  Record the choice and its reason under Decisions.
- **Ask the user** only when its options trade off things the user values (scope, cost,
  experience), when the choice is hard to reverse (public interface, data, accounts,
  permissions, security, release), or when it goes beyond the idea.
{{/start_verified_specs}}
{{#start_verified_specs}}
- **Settle it** when it is not a security question: take the logical option, the one the
  code, an existing convention, the text of the idea or an earlier decision points to.
  Hard-to-reverse choices (public interface, data format, file layout users depend on) and
  scope are settled too. Record each choice and its reason under Decisions. For scope
  beyond the idea, take the narrower option, and record the extension under Open questions
  as a possible follow-up.
- **Ask the user** every security question, and only those. A security question is an
  open choice about:
  - credentials, tokens or signing keys;
  - permission rules or `allowed-tools`;
  - Git identity or signing;
  - network downloads or remote scripts that are executed;
  - files written or deleted outside the project;
  - CI workflows;
  - accounts and their access rights;
  - data exposed outside the user's machine or to other people.

  Never settle a security question yourself, even with a clear recommendation: give it
  with its options and your recommendation. A change to such a file that follows from the
  user's decisions or the existing rules is not an open choice, and goes on. A question
  the lead flags as a security question in a verification always goes to the user too.
{{/start_verified_specs}}

Ask those questions all at once, in a single comment of their own on the issue (`gh issue
comment <n> --body-file <file>`) that mentions the user (`@<login>`, from `gh config get user
-h github.com`) and holds only the questions: each one with its options and your
recommendation, most important first, ending with a short question such as "Can I go on?".
When you also post what you understood or the questions you settled, post that first, in a
separate comment that does not mention the user and keeps its usual level of detail, so
that the comment mentioning him is the later of the two (`rules/git.md`). In the
conversation, show only one line with the comment's link. Without an issue yet, ask them in
the conversation instead.
{{#analyst}}
When running in the background for the lead, without an issue yet, return them to the lead
instead, with their options and your recommendation: the lead asks the user and relays the
answers.
{{/analyst}}

Wait only for the answers that block the specification; the other questions go to Open
questions with your recommendation, and the writing goes on. The idea's content feeds the
specification: problem and outcome go to Context, together with who is affected and why
now.

## 3. Write the specification

Write the three phases in one pass, without stopping for approval:

1. **Context and requirements.**
2. **Design and decisions.**
3. **Tasks**: the list of sub-issues, with their titles, the requirements each one covers
   and their "Done when". Check that every requirement is covered. Before publishing, check
   each task against the splitting rules: merge any task that cannot land without another.

When the user asks to work phase by phase, show each phase in the conversation and wait for
their approval before the next one.

## 4. Publish

Publish when the specification is written, or after any approved phase when working phase
by phase; the phases not written yet hold `_To be written._`. Publish without asking for
confirmation:

- Parent: `gh issue create --title "<title>" --body-file <file>`, or
  `gh issue edit <n> --title "<title>" --body-file <file>` for an existing issue. An idea
  becomes the specification in place: same issue, `[IDEA] ` removed from the title, body
  rewritten in the format above.
{{#analyst_github}}
- An idea whose issue was not written by `{{analyst_github}}` (its `author.login`) cannot
  be edited by the analyst. Write the specification in a new issue instead, with the
  idea's content moved into it and its Context starting with "From the idea #<idea>.".
  Then close the idea with a comment pointing to it, ending with the marker:
  `gh issue close <idea> --comment "$(printf 'Specified in #<new>.\n\n<!-- kirakit:analyst -->')"`.
{{/analyst_github}}
{{#assistant_github}}
- Assign the parent to `{{assistant_github}}`, the owner of specifications, when it is first
  published (when `type:idea` becomes `type:feature`), and leave the other assignees in
  place: `--assignee {{assistant_github}}` on `gh issue create` for a new issue, and for an
  idea that becomes the specification in place:
{{#analyst_github}}
  `gh issue edit <n> --add-assignee {{assistant_github}} --remove-assignee {{analyst_github}}`.
{{/analyst_github}}
{{^analyst_github}}
  `gh issue edit <n> --add-assignee {{assistant_github}}`.
{{/analyst_github}}
  An idea closed for a specification in a new issue keeps its assignees.
{{/assistant_github}}
- Labels on the parent, with `gh issue edit --add-label / --remove-label`:
  - add `type:feature`, and remove `type:idea`;
  - once the tasks are published, add `status:specified` and remove
    `status:needs-clarification`.
- Sub-issues, in the order they should be done: `gh issue create --parent <parent> --title
  "<title>" --body-file <file> --label type:task`. An existing issue becomes a sub-issue
  with `gh issue edit <parent> --add-sub-issue <n>`, and gets the same label. Tasks stay in
  Backlog, without `status:ready`: the user starts a specification by moving it to Ready,
{{#start_verified_specs}}
  or the lead does once she has verified it,
{{/start_verified_specs}}
  and then all its tasks can be worked on.
{{#coder}}
- Hard tasks run on the coder with Opus, the others on Sonnet. A task is hard when it
  changes concurrent or asynchronous behavior; security-sensitive files (credentials, tokens
  and signing keys; permission rules and `allowed-tools`; Git identity and signing; network
  downloads and executed remote scripts; files written or deleted outside the project; CI
  workflows); a data format or a migration; or an interface other repositories use; or when
  its design leaves the coder a choice between approaches. Add the label `model:opus` to
  each hard task, and give the reason in one line of its body: `Model: Opus — <reason>.`
{{/coder}}
{{#assistant_github}}
- Assign every sub-issue to the developer's account: `--assignee {{assistant_github}}`.
{{/assistant_github}}
- Before adding a label, check it with `gh label list`, and create a missing one without
  asking (`gh label create`).
- Write bodies to temporary files outside the repository, never into the working tree.
- Once the tasks are published, move the parent to Specified with the `board-status` skill
  (`board-status <parent> Specified`). A parent on no board is left as it is: its
  `status:specified` label marks it. When the board has no Specified option, say so in one
  line in the summary comment and in the closing lines.
{{#analyst_github}}
- Pass the analyst's account, so that the board is read and written as `{{analyst_github}}`:
  `board-status <parent> Specified --as {{analyst_github}}`. The skill reports a move that
  `{{analyst_github}}` cannot make, without using the user's account.
{{/analyst_github}}
{{^analyst_github}}
{{#assistant_github}}
- Pass the developer's account, so that the board is read and written as
  `{{assistant_github}}`: `board-status <parent> Specified --as {{assistant_github}}`. The
  skill reports a move that `{{assistant_github}}` cannot make, without using the user's
  account.
{{/assistant_github}}
{{/analyst_github}}

{{^start_verified_specs}}
Once the tasks are published, post a summary comment on the parent: the tasks (number,
title, requirements covered), the decisions made alone (number and one line each) and the
development order. Then:

- With no questions for the user, post it without mentioning the user and ask nothing:
  moving it to Ready is the user's choice of timing, and the board already shows it in
  Specified. End with "Ready for you: move it to Ready when you want the team to start."
{{/start_verified_specs}}
{{#start_verified_specs}}
Once the tasks are published, post a summary comment on the parent: the tasks (number,
title, requirements covered), the decisions taken without the user (number and one line
each), the hard-to-reverse ones first (public interface, data format, file layout users
depend on, scope) under their own heading, and the development order. Then:

- With no questions for the user, post it without mentioning the user and ask nothing: the
  specification goes to the lead, who verifies it and moves it to Ready when it is
  verified. End with "Sent to Kira for verification."
{{/start_verified_specs}}
- With questions for the user, post the summary comment above without mentioning the user,
  then the questions in a second comment of their own that mentions the user (`@<login>`),
  lists them with their options and your recommendation, and ends with a short question,
  as in step 2.

End with the parent's URL, the list of sub-issues (number and title) if any, "Questions for
the user: none." or the list of questions, and the next phase to write if the specification
is not complete.

## Changing a specification

When the user asks to change a published specification, or reverses a decision on the
issue, edit the parent body and the affected sub-issues the same way, without asking for
confirmation:

- A reversed decision stays, struck through (`~~**D2** — …~~`), and a new one records the
  user's choice.
- A change to the requirements updates the "Covers" line of every task concerned.
- The splitting rules apply to specifications written after them: a change does not regroup
  the existing tasks of a published specification, unless the user asks for it.
- Assignees are left as they are: changing a specification, moving it on the board or
  closing it adds or removes none.
{{#start_verified_specs}}
- When the lead hands back a verification's comments, address each one in the
  specification, settle or ask under step 2, and post a comment on the parent, without
  mentioning the user, that lists what changed for each comment. With no question left for
  the user, end it with "Sent to Kira for verification."; with one, ask it as in step 2.
- When the lead hands over a comment the user posted on a specification in Ready or In
  progress, answer it on the issue, or change the specification as it asks, so that the
  user's comment no longer comes last.
{{/start_verified_specs}}
