#!/bin/bash
#
# ARO Construction Studies - PDF Builder
# Creates a Unix handbook-style PDF from markdown sources
#
# Requirements:
#   - pandoc (brew install pandoc)
#   - LaTeX (brew install --cask mactex-no-gui or basictex)
#   - Or: weasyprint for HTML-to-PDF (pip install weasyprint)
#   - Python 3 (for SVG extraction)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOK_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/output"
OUTPUT_PDF="$OUTPUT_DIR/ARO-Construction-Studies.pdf"
METADATA_FILE="$SCRIPT_DIR/metadata.yaml"
CSS_FILE="$BOOK_DIR/unix-style.css"
PROCESSED_DIR="$SCRIPT_DIR/processed"
IMAGES_DIR="$SCRIPT_DIR/images"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Extract SVGs from markdown files into separate files
echo "Extracting SVGs from markdown files..."
python3 "$SCRIPT_DIR/extract-svgs.py"

# Copy images to processed directory for pandoc to find them
mkdir -p "$PROCESSED_DIR/images"
cp "$IMAGES_DIR"/*.svg "$PROCESSED_DIR/images/" 2>/dev/null || true

# Check for required files
if [[ ! -f "$METADATA_FILE" ]]; then
    echo "Error: metadata.yaml not found at $METADATA_FILE"
    exit 1
fi

if [[ ! -f "$CSS_FILE" ]]; then
    echo "Error: unix-style.css not found at $CSS_FILE"
    exit 1
fi

# Check for pandoc
if ! command -v pandoc &> /dev/null; then
    echo "Error: pandoc is required but not installed."
    echo "Install with: brew install pandoc"
    exit 1
fi

# Dynamically build the ordered list of chapters from processed directory
echo "Discovering chapters..."

CHAPTERS=()

# Start with cover page if it exists
if [[ -f "$PROCESSED_DIR/Cover.md" ]]; then
    CHAPTERS+=("Cover.md")
fi

# Get all Chapter*.md files with proper sorting
cd "$PROCESSED_DIR"
while IFS= read -r file; do
    CHAPTERS+=("$file")
done < <(for f in Chapter*.md; do
    sortkey=$(echo "$f" | sed -E 's/Chapter([0-9]+)([A-Z])/Chapter\1.1\2/')
    echo "$sortkey|$f"
done | sort -t'|' -k1,1V | cut -d'|' -f2)

# Then, get all Appendix*.md files and sort them
while IFS= read -r file; do
    CHAPTERS+=("$file")
done < <(ls -1 Appendix*.md 2>/dev/null | sort -V)

cd "$SCRIPT_DIR"

echo "Found ${#CHAPTERS[@]} chapters/appendices"
echo ""

echo "Building ARO Construction Studies..."
echo ""

# Build the file list from processed directory
FILE_LIST=""
for chapter in "${CHAPTERS[@]}"; do
    if [[ -f "$PROCESSED_DIR/$chapter" ]]; then
        FILE_LIST="$FILE_LIST $PROCESSED_DIR/$chapter"
        echo "  + $chapter"
    else
        echo "  ! Missing: $chapter"
    fi
done

echo ""

# Try LaTeX PDF first (best quality)
if command -v pdflatex &> /dev/null || command -v xelatex &> /dev/null; then
    echo "Building PDF with LaTeX..."

    cd "$PROCESSED_DIR"
    pandoc \
        --metadata-file="$METADATA_FILE" \
        --pdf-engine=xelatex \
        -f markdown-yaml_metadata_block \
        --highlight-style=kate \
        --toc \
        --toc-depth=2 \
        -V geometry:margin=1in \
        -V fontsize=11pt \
        -o "$OUTPUT_PDF" \
        $FILE_LIST
    cd "$SCRIPT_DIR"

    echo ""
    echo "Created: $OUTPUT_PDF"

# Fallback to HTML if no LaTeX
else
    echo "LaTeX not found. Building HTML version..."

    HTML_OUTPUT="$OUTPUT_DIR/ARO-Construction-Studies.html"

    # Copy images to output for weasyprint
    mkdir -p "$OUTPUT_DIR/images"
    cp "$IMAGES_DIR"/*.svg "$OUTPUT_DIR/images/" 2>/dev/null || true

    # Build content files (without cover) for TOC generation
    CONTENT_FILES=""
    for chapter in "${CHAPTERS[@]}"; do
        if [[ "$chapter" != "Cover.md" && -f "$PROCESSED_DIR/$chapter" ]]; then
            CONTENT_FILES="$CONTENT_FILES $PROCESSED_DIR/$chapter"
        fi
    done

    # Build HTML with cover at top, then TOC, then content
    TEMP_HTML="$OUTPUT_DIR/temp-content.html"

    cd "$OUTPUT_DIR"
    pandoc \
        --standalone \
        --toc \
        --toc-depth=2 \
        --css="$CSS_FILE" \
        --metadata title="" \
        --from markdown+raw_html \
        -o "$TEMP_HTML" \
        $CONTENT_FILES
    cd "$SCRIPT_DIR"

    # Generate cover HTML to temp file
    COVER_TEMP="$OUTPUT_DIR/temp-cover.html"
    if [[ -f "$PROCESSED_DIR/Cover.md" ]]; then
        pandoc --from markdown+raw_html --to html "$PROCESSED_DIR/Cover.md" > "$COVER_TEMP"
    else
        echo "" > "$COVER_TEMP"
    fi

    # Inject cover after <body> tag by splitting and concatenating
    head -n "$(grep -n '<body>' "$TEMP_HTML" | head -1 | cut -d: -f1)" "$TEMP_HTML" > "$HTML_OUTPUT"
    cat "$COVER_TEMP" >> "$HTML_OUTPUT"
    tail -n +"$(($(grep -n '<body>' "$TEMP_HTML" | head -1 | cut -d: -f1) + 1))" "$TEMP_HTML" >> "$HTML_OUTPUT"
    rm -f "$COVER_TEMP"
    rm -f "$TEMP_HTML"

    echo ""
    echo "Created: $HTML_OUTPUT"

    # Try weasyprint for PDF
    if command -v weasyprint &> /dev/null; then
        echo ""
        echo "Converting to PDF with WeasyPrint..."
        cd "$OUTPUT_DIR"
        weasyprint "$HTML_OUTPUT" "$OUTPUT_PDF" 2>/dev/null || weasyprint "$HTML_OUTPUT" "$OUTPUT_PDF"
        cd "$SCRIPT_DIR"

        if [[ -f "$OUTPUT_PDF" ]]; then
            echo "Created: $OUTPUT_PDF"
        fi
    else
        echo ""
        echo "To create a PDF from HTML, you can:"
        echo "  1. Open the HTML in a browser and print to PDF"
        echo "  2. Install weasyprint: pip install weasyprint"
        echo "     Then run: weasyprint $HTML_OUTPUT $OUTPUT_PDF"
        echo "  3. Install LaTeX: brew install --cask mactex-no-gui"
        echo "     Then re-run this script"
    fi
fi

# Also generate HTML version for web viewing
echo ""
echo "Building HTML version for screen reading..."

HTML_OUTPUT="$OUTPUT_DIR/ARO-Construction-Studies.html"

# Copy CSS and images to output directory for HTML
cp "$CSS_FILE" "$OUTPUT_DIR/"
mkdir -p "$OUTPUT_DIR/images"
cp "$IMAGES_DIR"/*.svg "$OUTPUT_DIR/images/" 2>/dev/null || true

# Build content files (without cover) for TOC generation
CONTENT_FILES=""
for chapter in "${CHAPTERS[@]}"; do
    if [[ "$chapter" != "Cover.md" && -f "$PROCESSED_DIR/$chapter" ]]; then
        CONTENT_FILES="$CONTENT_FILES $PROCESSED_DIR/$chapter"
    fi
done

# Build HTML with cover at top, then TOC, then content
TEMP_HTML="$OUTPUT_DIR/temp-content.html"

cd "$OUTPUT_DIR"
pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata title="ARO: The Construction Studies" \
    --from markdown+raw_html \
    -o "$TEMP_HTML" \
    $CONTENT_FILES
cd "$SCRIPT_DIR"

# Generate cover HTML to temp file
COVER_TEMP="$OUTPUT_DIR/temp-cover.html"
if [[ -f "$PROCESSED_DIR/Cover.md" ]]; then
    pandoc --from markdown+raw_html --to html "$PROCESSED_DIR/Cover.md" > "$COVER_TEMP"
else
    echo "" > "$COVER_TEMP"
fi

# Inject cover after <body> tag by splitting and concatenating
head -n "$(grep -n '<body>' "$TEMP_HTML" | head -1 | cut -d: -f1)" "$TEMP_HTML" > "$HTML_OUTPUT"
cat "$COVER_TEMP" >> "$HTML_OUTPUT"
tail -n +"$(($(grep -n '<body>' "$TEMP_HTML" | head -1 | cut -d: -f1) + 1))" "$TEMP_HTML" >> "$HTML_OUTPUT"
rm -f "$COVER_TEMP"
rm -f "$TEMP_HTML"

echo "Created: $HTML_OUTPUT"
echo ""
echo "Done!"
echo ""
echo "Output files in: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
