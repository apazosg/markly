---
name: task-planning
description: >
  Applies a structured plan-before-execute workflow to any task of sufficient complexity
  or ambiguity. Use this skill whenever the task spans multiple files or steps, the
  prompt has unresolved questions or open decisions, the user explicitly asks to plan
  before acting, or another skill's workflow says "see Plan Document Format".
  Also use when the user says "planifica", "haz un plan", "antes de hacer nada",
  "¿cuál es el plan?", "escribe un plan", "necesito un plan", or "qué cambios harías".
  DO NOT USE for trivial single-step tasks that can be completed in one action.
  NEVER execute changes before the plan is written to disk and the user approves.
---

# Task Planning

## Purpose

Guide an AI agent to plan before acting on any task with meaningful complexity or
ambiguity. The output of this skill is a plan document on disk — not changes to files.
Changes happen only after the user approves the plan.

This workflow is domain-agnostic. It applies to documentation tasks, code changes,
refactors, audits, or any multi-step operation.

---

## When to Use Planning

Apply this skill when **any** of the following is true:

| Signal | Example |
|---|---|
| **Multi-file scope** | The task will touch 3 or more files |
| **Multi-step workflow** | The task requires sequential decisions where later steps depend on earlier ones |
| **Ambiguous prompt** | The request could be interpreted in more than one way |
| **Open questions** | There are decisions the agent cannot make unilaterally |
| **Destructive or hard-to-reverse operations** | Deleting content, restructuring files, renaming symbols |
| **Cross-cutting impact** | The change affects conventions or structures that other skills or files depend on |
| **Explicit user request** | The user asks for a plan before execution |

For trivial, single-step, fully reversible tasks — skip this skill and act directly.

---

## Workflow

### Phase A — Assess and Plan

1. Read all relevant context (agents.md, affected files, skill bodies as needed).
2. Identify: what needs to change, what the risks are, what decisions are needed.
3. List any open questions that require user input before proceeding.
4. Draft the plan document (see Plan Document Format below).

**STOP. Write the plan file to disk. Do not change any file until the user approves.**

Present the plan path to the user and summarise the key decisions. If there are open
questions, list them explicitly and wait for answers before finalising the plan.

### Phase B — Execute

1. Re-read the plan from disk.
2. Execute items in plan order. Mark each checkbox after completion.
3. If execution reveals new information that affects other items, **STOP**, add it to
   `## Open Issues`, and surface it to the user before continuing.
4. After all items are done, set `state: done` in the plan frontmatter.

---

## Plan Document Format

All planning documents follow the same lifecycle and storage convention, regardless of
their topic (skill audit, refactor, documentation restructure, MVP scope, etc.).

### Storage paths

| State | Path |
|---|---|
| Active (being worked on) | `.agents/planning/<topic>-plan.md` |
| Completed | `.agents/planning/done/<topic>-plan.md` |

Choose a `<topic>` that is short and descriptive: `skill-audit`, `roadmap`, `mvp-scope`,
`migration`, `restructure-planning-skill`, etc.

**Move to `done/` when `state: done`** — do not delete. Completed plans are the
project's decision log.

### Required frontmatter

```yaml
---
id: <topic>-YYYY-MM-DD
state: draft   # draft | approved | in-progress | done
date: YYYY-MM-DD
---
```

Read `assets/plan-template.md` when creating a new plan document — it contains the pure structure to copy.
Read `assets/plan-example.md` if you need a filled-in reference (skill audit scenario).

---

## Agent Behavior Extensions

The universal agent behavior principles in the `Agent Behavior` section of `agents.md` apply to all tasks.

The following rules are specific to the task-planning workflow:

### Never merge plan and execution into one step

Writing a plan and executing it must be separate actions separated by a user STOP gate.
Do not draft a plan and immediately start modifying files in the same response.

### Surface ambiguity early

If the assessment in Phase A reveals open questions, list them in the plan under
`## Open Issues` before presenting it to the user. Do not silently resolve ambiguity
by picking the most likely interpretation.

### One plan per operation

Do not accumulate multiple concurrent operations in one plan unless they are logically
inseparable. If a user request covers two distinct topics, consider whether two separate
plans are clearer.

---

## Checklist

- [ ] Assess: does this task warrant a plan? (multi-file, multi-step, ambiguous, destructive)
- [ ] Read all relevant context before writing the plan
- [ ] List open questions in `## Open Issues` — do not silently resolve ambiguity
- [ ] Write plan file to disk at `.agents/planning/<topic>-plan.md`
- [ ] **STOP — present plan to user and wait for approval**
- [ ] Re-read plan from disk before executing
- [ ] Execute items in plan order; mark each checkbox after completion
- [ ] If new information changes the scope, STOP and surface to user
- [ ] Set `state: done` and move plan to `.agents/planning/done/` when complete
