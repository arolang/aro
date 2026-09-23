#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CSS="$SCRIPT_DIR/../unix-style.css"
SOURCE="$SCRIPT_DIR/AROForDataEngineers.md"
HTML_OUT="$OUTPUT_DIR/ARO-For-Data-Engineers.html"
PDF_OUT="$OUTPUT_DIR/ARO-For-Data-Engineers.pdf"

mkdir -p "$OUTPUT_DIR"

# Build from a stamped copy of the source. `@ARO_VERSION@` and `@ARO_DATE@`
# become the release this build is for, and the shared install snippet in
# Book/Install.md is spliced in wherever the text asks for it. The checked-in
# markdown keeps its placeholders.
source "$SCRIPT_DIR/../book-release.sh"
SRC_DIR="$OUTPUT_DIR/staged"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cp "$SOURCE" "$SCRIPT_DIR/metadata.yaml" "$SRC_DIR/"
aro_book_stamp "$SRC_DIR"
SOURCE="$SRC_DIR/$(basename "$SOURCE")"
METADATA_FILE="$SRC_DIR/metadata.yaml"
echo "Release: ARO $ARO_VERSION ($ARO_DATE)"
cp "$CSS" "$OUTPUT_DIR/"
# Carry the screenshots into the output so the HTML can resolve relative
# image paths without breaking. The PDF engines embed them at render time;
# the HTML keeps the link.
if [ -d "$SCRIPT_DIR/screenshots" ]; then
    rm -rf "$OUTPUT_DIR/screenshots"
    cp -R "$SCRIPT_DIR/screenshots" "$OUTPUT_DIR/screenshots"
fi

echo "Building HTML..."
pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata-file="$METADATA_FILE" \
    -f markdown+raw_html \
    -o "$HTML_OUT" \
    "$SOURCE"

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
        --resource-path="$SCRIPT_DIR" \
        -V geometry:margin=1in \
        -V fontsize=11pt \
        --highlight-style=kate \
        -o "$PDF_OUT" \
        "$SOURCE"
    echo "Created: $PDF_OUT"
else
    echo "No PDF engine found (install weasyprint or mactex). HTML only."
fi

echo ""
echo "Done! Output in: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
