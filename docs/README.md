English | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Documentation index

This directory contains documentation for current usage and historical material that preserves past design decisions. Choose the appropriate source for your purpose.

## Current specification

| Document | Contents |
|---|---|
| [Shared development instructions](../AGENTS.md) | Required rules for every agent working on this repository (Japanese) |
| [Development guide](development-guide.md) | Rationale, examples, and the instruction migration map (Japanese) |
| [Project overview](../README.md) | Features, installation, and daily usage |
| [Configuration guide](configuration.md) | Configuration and troubleshooting for `.feedback/config.yaml` |
| [Script reference](../scripts/README.md) | Responsibilities, behavior, and exit codes for each script |
| [Rules for Codex and general-purpose agents](pointer_agents.md) | Target AGENTS.md guidance for Hooks or manual checks, including document destination selection and proposal formats without skills |
| [Rules for Claude Code](pointer_claude.md) | Target CLAUDE.md guidance for Hooks or manual checks, including document destination selection and proposal formats without skills |

## Historical material

| Directory | Purpose |
|---|---|
| [Development history](history/development-history.md) (`history/`) | Dated development decisions and changes (Japanese) |
| `proposals/` | Pre-implementation proposals, including rejected ideas and approaches that changed later |
| `superpowers/specs/` | Specifications and rationale as they stood during design |
| `superpowers/plans/` | Implementation plans and verification procedures |
| `references/` | Translations and summaries of external sources consulted during design. The included Feedback Flywheel translation is in Simplified Chinese (`zh-CN`) |
| `../review/` | Dated code-review records. The findings have been addressed; the counts and line numbers are snapshots from the review date |

Dated historical material exists to preserve decisions made at that time. When it differs from the current implementation, prefer the documents listed under “Current specification” and the implementation itself.
