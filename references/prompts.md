# Prompt templates for the peer

The peer is another AI coding agent (Codex or Claude Code). It cannot see your conversation with the user; it only sees the prompt you send and the code in the repository. Replace `<angle brackets>` with real content. The templates are a starting point and need not be copied word for word, but keep the reply-format requirements so you can reliably decide whether another round is needed.

## Contents
- Ask the peer to review (round 1)
- Re-review (round 2 and later)
- Task brief for the peer (round 1)
- Send review feedback (round 2 and later)

---

## Ask the peer to review (round 1)

```
You are the code reviewer for this change, called by another AI coding agent. You have no permission to modify files and do not need to; only give review feedback. Do not call any other AI agent.

## Background
<the user's original request, in a sentence or two>

## Scope of the change
<one line on what is being reviewed, e.g. "the changes since your last review" or "the whole feature branch">
Run `git diff <FROM> <TO>` to see the changes under review. <TO> is a snapshot of the current working tree, uncommitted and new files included, so the files on disk match it; read the surrounding code where needed.
Main files involved: <file list>

## Notes from the author
<approach, trade-offs made, known limitations, tests already run and their results>

## Please focus on
Correctness and edge cases, consistency with existing code, security issues, missing tests. Do not spend space on pure style preferences.

## Reply format
List the issues one by one, each starting with a severity and a location:
- [BLOCKER] path/to/file.ext:line — description of the problem; suggested fix
- [MAJOR] ...
- [MINOR] ...
- [NIT] ...
Omit severities with no issues. The last line must be on its own, either:
VERDICT: APPROVE
or
VERDICT: CHANGES_REQUESTED
```

## Re-review (round 2 and later)

The peer remembers the previous round, so send only what changed.

```
I made changes based on your feedback; please review again.

## Changed
- <which of your points>: <how it was addressed>

## Not adopted
- <which point>: <reason>

## New tests or verification
<if any>

Run `git diff <FROM> <NEW_TO>` to see the latest full change, or `git diff <PREVIOUS_TO> <NEW_TO>` for just this round's fixes. If you still stand by a point that was not adopted, explain why.
Use the same reply format as last round, with VERDICT on the last line.
```

---

## Task brief for the peer (round 1)

```
You are responsible for implementing the task below, called by another AI coding agent. When you are done, it will review your changes and send feedback, and you will keep revising in the same session. Do not call any other AI agent.

## Goal
<what should be achieved, the user-visible outcome>

## Constraints
- Only change these files or directories: <scope>; if you really need to change something else, explain why in your reply first
- Follow the repository's existing style and conventions (see <example file>)
- Do not git commit; leave the changes in the working tree
- <other constraints: no new dependencies, keep interfaces compatible, etc.>

## Acceptance criteria
- <checkable condition 1>
- <checkable condition 2>
- Test command: <command>. If you lack the permission or network to run it, skip it and say so in your reply; the reviewer will run it

## Reply format
1. Which files you changed and what each change does
2. Key design trade-offs
3. Which tests you ran and their results
4. Anything unfinished or uncertain
```

## Send review feedback (round 2 and later)

```
I reviewed your changes; please revise according to the feedback below.

## Required changes
- [BLOCKER] path/file.ext:line — <problem>; <expected fix or direction>
- [MAJOR] ...

## Suggested changes (use your judgment)
- [MINOR] ...

## Done well, please keep
- <one or two points, so revisions do not break what is right>

## Test results
<the test commands you ran and their results, with the key errors on failure>

If you disagree with a point, explain why instead of silently ignoring it. When done, reply in the same format as last round.
```
