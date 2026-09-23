#!/bin/bash
#
# The Interactive Dialog - PDF builder
#
# This book had no build script, which is why its cover and its REPL banner
# carried hand-written version strings that nothing kept current. It builds
# like the other short books: stage the chapters, stamp the release, render.
#
# Requirements: pandoc, plus either weasyprint or a LaTeX engine for the PDF.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CSS="$SCRIPT_DIR/../unix-style.css"
HTML_OUT="$OUTPUT_DIR/ARO-Interactive-Dialog.html"
PDF_OUT="$OUTPUT_DIR/ARO-Interactive-Dialog.pdf"

mkdir -p "$OUTPUT_DIR"
cp "$CSS" "$OUTPUT_DIR/"

# Build from a stamped copy of the sources. `@ARO_VERSION@` and `@ARO_DATE@`
# become the release this build is for, and the shared install snippet in
# Book/Install.md is spliced in wherever a chapter asks for it. The checked-in
# markdown keeps its placeholders.
source "$SCRIPT_DIR/../book-release.sh"
SRC_DIR="$OUTPUT_DIR/staged"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cp "$SCRIPT_DIR"/*.md "$SRC_DIR/"
cp "$SCRIPT_DIR/metadata.yaml" "$SRC_DIR/"
aro_book_stamp "$SRC_DIR"
METADATA_FILE="$SRC_DIR/metadata.yaml"
echo "Release: ARO $ARO_VERSION ($ARO_DATE)"

# Cover, epigraph, chapters in order, then appendices.
FILES=()
for name in Cover.md Epigraph.md; do
    [[ -f "$SRC_DIR/$name" ]] && FILES+=("$SRC_DIR/$name")
done
while IFS= read -r file; do
    FILES+=("$file")
done < <(ls -1 "$SRC_DIR"/Chapter*.md 2>/dev/null | sort -V)
while IFS= read -r file; do
    FILES+=("$file")
done < <(ls -1 "$SRC_DIR"/Appendix*.md 2>/dev/null | sort -V)

echo "Building HTML..."
pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata-file="$METADATA_FILE" \
    -f markdown+raw_html \
    -o "$HTML_OUT" \
    "${FILES[@]}"

echo "Created: $HTML_OUT"

if command -v weasyprint &> /dev/null; then
    echo "Building PDF with WeasyPrint..."
    cd "$OUTPUT_DIR"
    weasyprint "$HTML_OUT" "$PDF_OUT"
    echo "Created: $PDF_OUT"
elif command -v pdflatex &> /dev/null || command -v xelatex &> /dev/null; then
    echo "Building PDF with LaTeX..."
    pandoc \
        --pdf-engine=xelatex \
        --metadata-file="$METADATA_FILE" \
        --toc \
        --toc-depth=2 \
        -V geometry:margin=1in \
        -V fontsize=11pt \
        --highlight-style=kate \
        -o "$PDF_OUT" \
        "${FILES[@]}"
    echo "Created: $PDF_OUT"
else
    echo "No PDF engine found (install weasyprint or mactex). HTML only."
fi

echo ""
echo "Done! Output in: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
