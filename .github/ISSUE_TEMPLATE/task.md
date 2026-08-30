---
name: Task
about: A unit of work — a feature, a change, a piece of an epic
title: ''
labels: ''
---

## Why

What is missing or wrong, and who runs into it. One or two paragraphs. Write the
problem, not the solution.

## Scope

What this issue covers, and — just as important — what it deliberately leaves out.
If it belongs to an epic, link it: `epic: #N`.

## Constraints found in the code

Facts checked in the repo, with `file.swift:line`. Not guesses, not "we should be
careful about". This is the section that keeps an issue from turning into a generic
wish, and it is where the hours are saved: whoever picks this up should learn here
what would otherwise cost them an afternoon.

Leave the section out if there is nothing verified yet — an empty section is worse
than none.

## Done when

- [ ] Testable statements, not activities. "X survives a downgrade" rather than
      "handle downgrades".
- [ ] Include the compatibility check when the change touches persisted data or a
      wire format.
