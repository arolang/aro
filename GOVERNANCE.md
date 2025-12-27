# Governance

This document describes how the ARO project is governed.

## Leadership

ARO follows a **Benevolent Dictator** model. The project maintainer has final say on all decisions, including feature direction, code acceptance, and community matters. This keeps decision-making simple and consistent.

## Proposing Changes

New features and significant changes should go through the formal proposal process:

1. Create a proposal document in the `Proposals/` directory
2. Use the format `ARO-XXXX-short-description.md` (next available number)
3. Follow the structure of existing proposals
4. Open a PR for discussion
5. The maintainer will review and decide on acceptance

For small fixes and improvements, a direct PR with a clear description is fine.

## Becoming a Maintainer

ARO welcomes new maintainers! If you're interested, here's the path:

1. **Contribute consistently** - Submit quality PRs over time
2. **Understand the vision** - Familiarize yourself with the proposals and language design
3. **Help the community** - Answer questions, review PRs, improve documentation
4. **Express interest** - Open an issue or reach out to discuss

There's no fixed timeline or quota. Maintainer status is granted based on trust, alignment with project goals, and demonstrated commitment.

## Versioning

ARO uses [Semantic Versioning](https://semver.org/):

- **Major** (X.0.0): Breaking changes to the language or runtime
- **Minor** (0.X.0): New features, backward-compatible
- **Patch** (0.0.X): Bug fixes and minor improvements

During the 0.x phase, the language is experimental and breaking changes may occur in minor versions.

## Deprecation

When features need to be removed:

1. **Announce** - Document the deprecation in release notes
2. **Warn** - Add compiler warnings for deprecated syntax/features
3. **Grace period** - Keep deprecated features for at least one minor version
4. **Remove** - Remove in a subsequent release with clear migration guidance

We aim to minimize breaking changes and provide clear upgrade paths.
