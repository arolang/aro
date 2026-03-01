#!/bin/bash
#
# ARO By Example - PDF Builder
# Creates a Unix handbook-style PDF from markdown sources
#
# Requirements:
#   - pandoc (brew install pandoc)
#   - LaTeX (brew install --cask mactex-no-gui or basictex)
#   - Or: weasyprint for HTML-to-PDF (pip install weasyprint)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOK_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/output"
OUTPUT_PDF="$OUTPUT_DIR/ARO-By-Example.pdf"
METADATA_FILE="$SCRIPT_DIR/metadata.yaml"
CSS_FILE="$BOOK_DIR/unix-style.css"

# Create output directory
mkdir -p "$OUTPUT_DIR"

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

# Dynamically build the ordered list of chapters
# Sort order: Cover, Chapter01, Chapter02, ..., Chapter06, Chapter06A, Chapter06B, ..., Appendix*
# Sub-chapters (like 06A, 16B) come after their parent chapter (06, 16)
echo "Discovering chapters..."

CHAPTERS=()

# Start with cover page if it exists
if [[ -f "$SCRIPT_DIR/Cover.md" ]]; then
    CHAPTERS+=("Cover.md")
fi

# Get all Chapter*.md files with proper sorting
# Transform ChapterXXY to ChapterXX.1Y for sorting so 06 < 06A < 07
cd "$SCRIPT_DIR"
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

echo "Found ${#CHAPTERS[@]} chapters/appendices"
echo ""

echo "Building ARO By Example..."
echo ""

# Build the file list
FILE_LIST=""
for chapter in "${CHAPTERS[@]}"; do
    if [[ -f "$SCRIPT_DIR/$chapter" ]]; then
        FILE_LIST="$FILE_LIST $SCRIPT_DIR/$chapter"
        echo "  + $chapter"
    else
        echo "  ! Missing: $chapter"
    fi
done

echo ""

# Try LaTeX PDF first (best quality)
if command -v pdflatex &> /dev/null || command -v xelatex &> /dev/null; then
    echo "Building PDF with LaTeX..."

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

    echo ""
    echo "Created: $OUTPUT_PDF"

# Fallback to HTML if no LaTeX
else
    echo "LaTeX not found. Building HTML version..."

    HTML_OUTPUT="$OUTPUT_DIR/ARO-By-Example.html"

    # Build content files (without cover) for TOC generation
    CONTENT_FILES=""
    for chapter in "${CHAPTERS[@]}"; do
        if [[ "$chapter" != "Cover.md" && -f "$SCRIPT_DIR/$chapter" ]]; then
            CONTENT_FILES="$CONTENT_FILES $SCRIPT_DIR/$chapter"
        fi
    done

    # Build HTML with cover at top, then TOC, then content
    # Generate TOC and content with pandoc --standalone, then inject cover at top
    TEMP_HTML="$OUTPUT_DIR/temp-content.html"

    pandoc \
        --standalone \
        --toc \
        --toc-depth=2 \
        --css="$CSS_FILE" \
        --metadata title="" \
        --from markdown+raw_html \
        -o "$TEMP_HTML" \
        $CONTENT_FILES

    # Generate cover HTML to temp file
    COVER_TEMP="$OUTPUT_DIR/temp-cover.html"
    if [[ -f "$SCRIPT_DIR/Cover.md" ]]; then
        pandoc --from markdown+raw_html --to html "$SCRIPT_DIR/Cover.md" > "$COVER_TEMP"
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
        weasyprint "$HTML_OUTPUT" "$OUTPUT_PDF" 2>/dev/null || true

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

HTML_OUTPUT="$OUTPUT_DIR/ARO-By-Example.html"

# Copy CSS to output directory for HTML
cp "$CSS_FILE" "$OUTPUT_DIR/"

# Build content files (without cover) for TOC generation
CONTENT_FILES=""
for chapter in "${CHAPTERS[@]}"; do
    if [[ "$chapter" != "Cover.md" && -f "$SCRIPT_DIR/$chapter" ]]; then
        CONTENT_FILES="$CONTENT_FILES $SCRIPT_DIR/$chapter"
    fi
done

# Build HTML with cover at top, then TOC, then content
TEMP_HTML="$OUTPUT_DIR/temp-content.html"

pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata title="ARO: Business Logic as Language" \
    --from markdown+raw_html \
    --embed-resources \
    --self-contained \
    -o "$TEMP_HTML" \
    $CONTENT_FILES 2>/dev/null || \
pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata title="ARO: Business Logic as Language" \
    --from markdown+raw_html \
    -o "$TEMP_HTML" \
    $CONTENT_FILES

# Generate cover HTML to temp file
COVER_TEMP="$OUTPUT_DIR/temp-cover.html"
if [[ -f "$SCRIPT_DIR/Cover.md" ]]; then
    pandoc --from markdown+raw_html --to html "$SCRIPT_DIR/Cover.md" > "$COVER_TEMP"
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
