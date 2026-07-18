#!/usr/bin/env bash
#
# lint-unjustified-try.sh
#
# Enforces the CLAUDE.md "Silent fallbacks (try?)" policy for a curated set of
# audited files: every `try?` must carry a justifying comment on the line
# itself or somewhere in the contiguous block of preceding lines that belong to
# the same statement (i.e. the run of non-blank lines immediately above it, up
# to the previous blank line, opening brace, or statement start).
#
# A `try?` is considered JUSTIFIED when any of these lines contains `//`.
# This is intentionally simple and dependency-free (pure grep/bash, no
# SwiftLint) so it runs anywhere `swift test` runs and in CI.
#
# Scope: only the files listed in AUDITED_FILES below are checked. As the audit
# expands to more runtime files, add them to that list (and to the mirror list
# in Tests/AROuntimeTests/UnjustifiedTryLintTests.swift).
#
# Exit code: 0 if every `try?` in every audited file is justified, 1 otherwise.
# Offending sites are printed to stderr as "path:line: unjustified try?".

set -euo pipefail

# Resolve repo root from this script's location (Scripts/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Audited files. Paths are relative to the repo root. Add files here as the
# try? audit expands beyond the bridge layer (issue #322).
# ---------------------------------------------------------------------------
AUDITED_FILES=(
  "Sources/ARORuntime/Bridge/RuntimeBridge.swift"
  "Sources/ARORuntime/Bridge/ServiceBridge.swift"
)

violations=0

for rel in "${AUDITED_FILES[@]}"; do
  file="${REPO_ROOT}/${rel}"
  if [[ ! -f "${file}" ]]; then
    echo "lint-unjustified-try: audited file not found: ${rel}" >&2
    violations=$((violations + 1))
    continue
  fi

  # awk walks the file keeping a rolling record of the current statement block.
  # `block_has_comment` is true if any line since the last boundary contained
  # `//`. A boundary is a blank line or a line that is only an opening/closing
  # brace. When a line contains `try?` (and is not itself a pure comment line),
  # it is a violation unless the current block already has a comment or the
  # try? line itself carries an inline `//`.
  awk -v path="${rel}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      line = $0
      t = trim(line)

      # Reset the block at boundaries: blank lines and lone-brace lines.
      if (t == "" || t == "{" || t == "}" || t == "})" || t == "});") {
        block_has_comment = 0
        next
      }

      is_comment_line = (substr(t, 1, 2) == "//")
      has_comment = (index(line, "//") > 0)

      # Track whether this statement block carries any justification.
      if (has_comment) block_has_comment = 1

      # A pure comment line cannot itself be a violating try? site.
      if (is_comment_line) next

      if (index(line, "try?") > 0) {
        if (block_has_comment == 0) {
          printf "%s:%d: unjustified try?%s\n", path, NR, ""
          violated = 1
        }
      }
    }
    END { if (violated) exit 1 }
  ' "${file}" >&2 || violations=$((violations + 1))
done

if [[ "${violations}" -ne 0 ]]; then
  echo "lint-unjustified-try: FAILED — unjustified try? found in audited files (see above)." >&2
  echo "Add a comment justifying the ignored error, or rewrite to log/throw per CLAUDE.md." >&2
  exit 1
fi

echo "lint-unjustified-try: OK — all try? in audited files are justified."
