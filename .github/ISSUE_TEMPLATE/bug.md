---
name: Bug
about: Something behaves wrongly
title: ''
labels: ''
---

## What happens

Observed behaviour. Include the exact text of any error.

## What should happen

## Repro

Smallest sequence that shows it. Note the damson version (`damson-cli --list-instances`
plus the About window) and whether it also happens in Terminal.app — that split alone
often separates a parser bug from a renderer bug.

For a rendering bug, capture the bytes rather than describing the picture:

```sh
DAMSON_DUMP_OUTPUT=/tmp/dump open -n /Applications/Damson.app
```

The dump records **every byte** a pane produced, so do not capture a window where you
type passwords or tokens, and delete the directory afterwards.

## Where it likely lives

Optional. A file, a function, a suspicion.
