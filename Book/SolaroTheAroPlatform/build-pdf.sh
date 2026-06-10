#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CSS="$SCRIPT_DIR/../unix-style.css"
SOURCE="$SCRIPT_DIR/SolaroTheAroPlatform.md"
HTML_OUT="$OUTPUT_DIR/ARO-Solaro-Platform.html"
PDF_OUT="$OUTPUT_DIR/ARO-Solaro-Platform.pdf"

mkdir -p "$OUTPUT_DIR"
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
    --metadata-file="$SCRIPT_DIR/metadata.yaml" \
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
        --metadata-file="$SCRIPT_DIR/metadata.yaml" \
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
