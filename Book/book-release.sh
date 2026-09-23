#!/bin/bash
#
# Shared release metadata for every book under Book/.
#
# Each book's build script sources this file and then calls `aro_book_stamp`
# on whatever markdown it is about to hand to pandoc. Two things happen there:
#
#   * `@ARO_VERSION@` and `@ARO_DATE@` are replaced with the release this
#     build is for, so no chapter and no metadata.yaml carries a hand-written
#     "0.9.x, March 2026" that nobody remembers to update;
#
#   * an `<!-- ARO:INCLUDE Install.md -->` … `<!-- /ARO:INCLUDE -->` block is
#     replaced by the contents of Book/Install.md, so all nine books give the
#     same install instructions and there is one place to change them.
#
# The version comes from the release tag, falling back so that a build in a
# shallow clone, an exported tarball, or a checkout with no tags still
# produces something sane rather than failing or printing a literal
# `@ARO_VERSION@`.
#
# Usage from a build script:
#
#     source "$BOOK_DIR/book-release.sh"
#     aro_book_stamp "$PROCESSED_DIR"        # a directory of .md, or
#     aro_book_stamp "$STAGED_FILE"          # individual files
#
# Stamp copies, never the checked-in sources: every book either builds from a
# `processed/` directory or stages into its output directory first.

# Resolve once; both functions and the caller may read these.
ARO_BOOK_DIR="${ARO_BOOK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ARO_INSTALL_SNIPPET="$ARO_BOOK_DIR/Install.md"

# The release this build documents.
#
# Precedence: an explicit ARO_VERSION in the environment (what CI passes when
# it builds the books for a tag), then the newest tag reachable from HEAD,
# then "dev". Tags are written both as `0.12.1` and as `v0.2.0-beta.8` in this
# repository's history, so a leading `v` is stripped.
if [[ -z "${ARO_VERSION:-}" ]]; then
    ARO_VERSION="$(git -C "$ARO_BOOK_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
    ARO_VERSION="${ARO_VERSION#v}"
fi
: "${ARO_VERSION:=dev}"

# The date this build documents: the tagged release's date when there is a
# tag, otherwise today. `%B %Y` — "September 2026" — is the form the covers
# and the metadata files have always used.
if [[ -z "${ARO_DATE:-}" ]]; then
    if [[ "$ARO_VERSION" != "dev" ]]; then
        _aro_tag_epoch="$(git -C "$ARO_BOOK_DIR" log -1 --format=%ct "$ARO_VERSION" 2>/dev/null \
            || git -C "$ARO_BOOK_DIR" log -1 --format=%ct "v$ARO_VERSION" 2>/dev/null || true)"
    fi
    if [[ -n "${_aro_tag_epoch:-}" ]]; then
        # BSD date wants -r, GNU date wants -d @.
        ARO_DATE="$(date -r "$_aro_tag_epoch" "+%B %Y" 2>/dev/null \
            || date -d "@$_aro_tag_epoch" "+%B %Y" 2>/dev/null || true)"
    fi
    unset _aro_tag_epoch
fi
: "${ARO_DATE:=$(date "+%B %Y")}"

export ARO_VERSION ARO_DATE

# Rewrite the given markdown files (or every *.md under the given
# directories) in place. Safe to call more than once: after the first pass
# there are no placeholders and no include markers left to act on.
aro_book_stamp() {
    local targets=()
    local path
    for path in "$@"; do
        if [[ -d "$path" ]]; then
            while IFS= read -r file; do
                targets+=("$file")
            done < <(find "$path" -name '*.md' -o -name '*.yaml')
        elif [[ -f "$path" ]]; then
            targets+=("$path")
        fi
    done

    [[ ${#targets[@]} -eq 0 ]] && return 0

    ARO_VERSION="$ARO_VERSION" ARO_DATE="$ARO_DATE" \
    ARO_INSTALL_SNIPPET="$ARO_INSTALL_SNIPPET" \
    python3 - "${targets[@]}" <<'PYTHON'
import os
import re
import sys

version = os.environ["ARO_VERSION"]
date = os.environ["ARO_DATE"]
snippet_path = os.environ["ARO_INSTALL_SNIPPET"]

# The snippet's own leading HTML comment is guidance for whoever edits it,
# not something a reader should meet in the middle of a chapter.
snippet = ""
if os.path.exists(snippet_path):
    with open(snippet_path, encoding="utf-8") as handle:
        snippet = handle.read()
    snippet = re.sub(r"\A\s*<!--.*?-->\s*", "", snippet, flags=re.DOTALL)
    snippet = snippet.replace("@ARO_VERSION@", version).replace("@ARO_DATE@", date)
    snippet = snippet.strip() + "\n"

include = re.compile(
    r"<!--\s*ARO:INCLUDE\s+Install\.md\s*-->.*?<!--\s*/ARO:INCLUDE\s*-->",
    re.DOTALL,
)

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        original = handle.read()

    updated = original
    if snippet:
        updated = include.sub(lambda _: snippet, updated)
    updated = updated.replace("@ARO_VERSION@", version).replace("@ARO_DATE@", date)

    if updated != original:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)
PYTHON
}
