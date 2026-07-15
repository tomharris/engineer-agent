---
name: answer-slack
description: "Draft an answer to a Slack question about code, implementation, or project status. Use this skill when processing a slack-question queue item or when asked to draft a Slack response."
version: 1.0.0
model: sonnet
---

# Draft a Slack Answer

Generate a concise, helpful answer to a Slack question by researching the codebase and context.

## Tools Needed

- `Bash` — `spy thread <channel> <ts> --json -w <workspace>` ([Spy](https://github.com/tomharris/spy) Slack CLI) to read full thread context
- `Read` — read queue items, config, and source code files
- `Write` — write draft answer
- `Grep`, `Glob` — search local codebase

## Input

A queue item file in `~/.local/share/engineer-agent/queue/incoming/` with type `slack-question`, containing the message text and thread context.

## Steps

### 1. Understand the Question

Read the queue item file. Extract the `project` field from frontmatter. Analyze:
- What specifically is being asked?
- Is this about code implementation, architecture, status, or something else?
- Is there enough context to give a good answer?

### 2. Research

Read `~/.local/share/engineer-agent/engineer.yaml` to find the project's path at `projects.<project>.path`.

If you need more thread context than the queue item already contains, read it with
`spy thread <channel_id> <ts> --json -w <workspace>`, resolving the Spy binary
(`agent.slack.bin`, default `spy`) and workspace (`projects.<project>.slack.workspace` ??
`agent.slack.workspace`) from config.

Based on the question type:

**Code/implementation questions:**
- Use `Grep` to search for relevant code patterns in the project's local codebase (at the project path)
- Use `Read` to read specific files referenced in the question
- Check git history if the question is about intent or history ("why was this done?")

**Status questions:**
- Check recent PRs, commits, and queue items for relevant activity
- Look at Jira ticket status if referenced

**Architecture questions:**
- Read the target project's CLAUDE.md for documented decisions
- Find relevant code patterns in the codebase

### 3. Draft the Answer

Write a concise Slack-appropriate response:

- **Be direct** — answer the question first, then provide context
- **Keep it short** — 1-3 paragraphs for most answers
- **Include code references** — link to specific files/lines when relevant
- **Use Slack formatting** — `code blocks`, *bold* for emphasis, bullet lists
- **Acknowledge uncertainty** — if you're not sure about something, say so

If the question cannot be answered confidently:
- Draft a response that says what you do know
- Flag what's uncertain
- Set priority to `urgent` so the human reviews it quickly

### 4. Write the Draft

Update the queue item file:

1. Add the `## Draft Response` section:

```markdown
## Draft Response

### Proposed Slack Message

{the message to post in the thread}

### Confidence

{high | medium | low} — {brief explanation of confidence level}

### Sources

- {file or link referenced}
- {another source}
```

2. Update frontmatter `status` to `drafted`
3. If confidence is low, update `priority` to `urgent`
4. Move the file from `~/.local/share/engineer-agent/queue/incoming/` to `~/.local/share/engineer-agent/queue/drafts/`

### 5. Report

Report: "Slack answer drafted for question from @{author} in #{channel_name}. Confidence: {level}."
