English | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Documentation index

This directory contains documentation for current usage and historical material that preserves past design decisions. Choose the appropriate source for your purpose.

## Current specification

| Document | Contents |
|---|---|
| [Project overview](../README.md) | Features, installation, and daily usage |
| [Configuration guide](configuration.md) | Configuration and troubleshooting for `.feedback/config.yaml` |
| [Script reference](../scripts/README.md) | Responsibilities, behavior, and exit codes for each script |
| [Rules for Codex and general-purpose agents](pointer_agents.md) | Rules inserted into target AGENTS.md files that support both Codex Plugin Hooks and the manual fallback |
| [Rules for Claude Code](pointer_claude.md) | Rules inserted into target CLAUDE.md files that support both Claude Code plugin Hooks and the init-only manual fallback |

## Historical material

| Directory | Purpose |
|---|---|
| `proposals/` | Pre-implementation proposals, including rejected ideas and approaches that changed later |
| `superpowers/specs/` | Specifications and rationale as they stood during design |
| `superpowers/plans/` | Implementation plans and verification procedures |
| `references/` | Translations and summaries of external sources consulted during design. The included Feedback Flywheel translation is in Simplified Chinese (`zh-CN`) |
| `../review/` | Dated code-review records. The findings have been addressed; the counts and line numbers are snapshots from the review date |

Dated historical material exists to preserve decisions made at that time. When it differs from the current implementation, prefer the documents listed under “Current specification” and the implementation itself.
