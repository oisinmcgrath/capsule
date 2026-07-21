---
name: feedback_commit_no_coauthor
description: "Never put \"Co-Authored-By: Claude\" in commit messages"
metadata:
  type: feedback
---

Never add a `Co-Authored-By: Claude ...` trailer (or any Claude/tooling attribution, including a "Generated with Claude" line) to git commit messages. This overrides the harness default that appends one.

**Why:** Owner wants commit history clean of tooling attribution.
**How to apply:** Write commit messages that state plainly *what changed* (and the why where it isn't obvious). End the message at the content — no co-author trailer, no signature line.
