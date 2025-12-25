#!/bin/bash
#
# ARO Language Guide - PDF Builder
# Creates a Unix handbook-style PDF from markdown sources
#
# Requirements:
#   - pandoc (brew install pandoc)
#   - LaTeX (brew install --cask mactex-no-gui or basictex)
#   - Or: weasyprint for HTML-to-PDF (pip install weasyprint)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
OUTPUT_PDF="$OUTPUT_DIR/ARO-Language-Guide.pdf"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check for pandoc
if ! command -v pandoc &> /dev/null; then
    echo "Error: pandoc is required but not installed."
    echo "Install with: brew install pandoc"
    exit 1
fi

# Ordered list of chapters
CHAPTERS=(
    "Chapter01-WhyARO.md"
    "Chapter02-MentalModel.md"
    "Chapter03-GettingStarted.md"
    "Chapter04-StatementAnatomy.md"
    "Chapter05-FeatureSets.md"
    "Chapter06-DataFlow.md"
    "Chapter07-HappyPath.md"
    "Chapter08-EventBus.md"
    "Chapter09-Lifecycle.md"
    "Chapter10-CustomEvents.md"
    "Chapter11-OpenAPI.md"
    "Chapter12-HTTPFeatureSets.md"
    "Chapter13-RequestResponse.md"
    "Chapter14-BuiltinServices.md"
    "Chapter15-CustomActions.md"
    "Chapter16-Plugins.md"
    "Chapter17-NativeCompilation.md"
    "Chapter18-MultiFile.md"
    "Chapter19-Patterns.md"
    "Chapter20-Modules.md"
    "AppendixA-ActionReference.md"
    "AppendixB-Prepositions.md"
    "AppendixC-Grammar.md"
)

# Create metadata file
cat > "$OUTPUT_DIR/metadata.yaml" << 'EOF'
---
title: "ARO: Business Logic as Language"
subtitle: "The Language Guide"
author: "ARO Project"
date: "December 2025"
lang: en
documentclass: book
classoption:
  - oneside
  - 11pt
geometry:
  - margin=1in
  - paperwidth=7in
  - paperheight=10in
fontfamily: courier
monofont: "Courier"
mainfont: "Palatino"
linestretch: 1.15
toc: true
toc-depth: 2
numbersections: false
colorlinks: true
linkcolor: NavyBlue
urlcolor: NavyBlue
header-includes:
  - |
    \usepackage{fancyhdr}
    \usepackage{titlesec}
    \usepackage{xcolor}
    \definecolor{chaptercolor}{RGB}{40, 40, 40}
    \definecolor{codebackground}{RGB}{248, 248, 248}
    \pagestyle{fancy}
    \fancyhf{}
    \fancyhead[L]{\small\leftmark}
    \fancyhead[R]{\small\thepage}
    \fancyfoot[C]{\small ARO Language Guide}
    \renewcommand{\headrulewidth}{0.4pt}
    \renewcommand{\footrulewidth}{0.4pt}
    \titleformat{\chapter}[display]
      {\normalfont\Large\bfseries\color{chaptercolor}}
      {\chaptertitlename\ \thechapter}{20pt}{\Huge}
    \titlespacing*{\chapter}{0pt}{-20pt}{40pt}
---
EOF

# Create CSS for HTML version (screen-optimized)
cat > "$OUTPUT_DIR/unix-style.css" << 'EOF'
/* ARO Language Guide - Unix Handbook Style for Screens */

@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Serif:wght@400;500;600&display=swap');

:root {
    --bg-color: #fdfdf8;
    --text-color: #1a1a1a;
    --heading-color: #0a0a0a;
    --code-bg: #f4f4f0;
    --code-border: #e0e0d8;
    --link-color: #1a4d80;
    --accent: #333;
    --chapter-num: #666;
}

@media (prefers-color-scheme: dark) {
    :root {
        --bg-color: #1a1a1a;
        --text-color: #e0e0e0;
        --heading-color: #ffffff;
        --code-bg: #2a2a2a;
        --code-border: #3a3a3a;
        --link-color: #6aafe6;
        --accent: #888;
        --chapter-num: #888;
    }
}

* {
    box-sizing: border-box;
}

html {
    font-size: 15px;
}

body {
    font-family: 'IBM Plex Serif', 'Palatino Linotype', 'Book Antiqua', Palatino, Georgia, serif;
    line-height: 1.65;
    color: var(--text-color);
    background-color: var(--bg-color);
    max-width: 42rem;
    margin: 0 auto;
    padding: 2rem;
}

/* Typography */
h1, h2, h3, h4, h5, h6 {
    font-family: 'IBM Plex Sans', 'Helvetica Neue', Helvetica, Arial, sans-serif;
    color: var(--heading-color);
    font-weight: 600;
    line-height: 1.3;
    margin-top: 2.5rem;
    margin-bottom: 1rem;
}

h1 {
    font-size: 2.2rem;
    border-bottom: 3px solid var(--accent);
    padding-bottom: 0.5rem;
    margin-top: 3rem;
    page-break-before: always;
}


h1::before {
    content: "§ ";
    color: var(--chapter-num);
    font-weight: 400;
}

h2 {
    font-size: 1.5rem;
    border-bottom: 1px solid var(--code-border);
    padding-bottom: 0.3rem;
}

h3 {
    font-size: 1.2rem;
}

h4 {
    font-size: 1.1rem;
    font-style: italic;
}

/* Epigraphs - the italic quotes under chapter titles */
h1 + p > em:only-child,
h2 + p > em:only-child {
    display: block;
    font-size: 1rem;
    color: var(--chapter-num);
    border-left: 3px solid var(--code-border);
    padding-left: 1rem;
    margin: 1rem 0 2rem 0;
}

p {
    margin: 1rem 0;
    text-align: justify;
    hyphens: auto;
}

/* Links */
a {
    color: var(--link-color);
    text-decoration: none;
}

a:hover {
    text-decoration: underline;
}

/* Code - clean minimal style */
code {
    font-family: 'IBM Plex Mono', 'Menlo', 'Monaco', 'Consolas', monospace;
    font-size: 0.85rem;
    padding: 0.1rem 0.3rem;
}

pre {
    font-family: 'IBM Plex Mono', 'Menlo', 'Monaco', 'Consolas', monospace;
    font-size: 0.8rem;
    line-height: 1.5;
    border-left: 3px solid var(--accent);
    padding: 0.8rem 1rem;
    overflow-x: auto;
    margin: 1.5rem 0;
}

pre code {
    background: none;
    border: none;
    padding: 0;
    font-size: inherit;
}

/* Tables - clean minimal style */
table {
    width: 100%;
    border-collapse: collapse;
    margin: 1.5rem 0;
    font-size: 0.9rem;
}

th, td {
    text-align: left;
    padding: 0.5rem 0.6rem;
    border-bottom: 1px solid var(--code-border);
}

th {
    font-family: 'IBM Plex Sans', sans-serif;
    font-weight: 600;
    border-bottom: 2px solid var(--accent);
}

/* Lists */
ul, ol {
    margin: 1rem 0;
    padding-left: 1.5rem;
}

li {
    margin: 0.3rem 0;
}

li > ul, li > ol {
    margin: 0.3rem 0;
}

/* Blockquotes */
blockquote {
    margin: 1.5rem 0;
    padding: 0.5rem 1rem;
    border-left: 3px solid var(--accent);
    font-style: italic;
}

blockquote p {
    margin: 0.5rem 0;
}

/* Horizontal rules - chapter separators */
hr {
    border: none;
    border-top: 1px solid var(--code-border);
    margin: 3rem 0;
}

hr::after {
    content: "* * *";
    display: block;
    text-align: center;
    margin-top: -0.7rem;
    background: var(--bg-color);
    color: var(--chapter-num);
    font-size: 0.9rem;
    width: 4rem;
    margin-left: auto;
    margin-right: auto;
}

/* Table of Contents */
#TOC {
    padding: 1rem 0;
    margin: 2rem 0;
    page-break-after: always;
}

#TOC::before {
    content: "Contents";
    font-family: 'IBM Plex Sans', sans-serif;
    font-size: 1.2rem;
    font-weight: 600;
    display: block;
    margin-bottom: 1rem;
    border-bottom: 1px solid var(--accent);
    padding-bottom: 0.5rem;
}

#TOC ul {
    list-style: none;
    padding-left: 0;
}

#TOC > ul > li {
    margin: 0.8rem 0;
    font-weight: 500;
}

#TOC > ul > li > ul {
    font-weight: 400;
    padding-left: 1.5rem;
    margin-top: 0.3rem;
}

#TOC > ul > li > ul > li {
    margin: 0.2rem 0;
    font-size: 0.95rem;
}

/* Print styles */
@media print {
    body {
        max-width: none;
        padding: 0;
        font-size: 11pt;
    }

    h1 {
        page-break-before: always;
    }

    h1:first-of-type {
        page-break-before: avoid;
    }

    pre, blockquote, table {
        page-break-inside: avoid;
    }

    a {
        color: inherit;
        text-decoration: none;
    }
}

/* Title page styling */
.title-block {
    text-align: center;
    margin: 4rem 0;
    padding: 2rem;
    border: 2px solid var(--accent);
}

.title {
    font-size: 2.5rem;
    margin-bottom: 0.5rem;
}

.subtitle {
    font-size: 1.3rem;
    color: var(--chapter-num);
}

.author, .date {
    margin-top: 1rem;
    font-size: 1rem;
}
EOF

echo "Building ARO Language Guide..."
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
        --metadata-file="$OUTPUT_DIR/metadata.yaml" \
        --pdf-engine=xelatex \
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

    HTML_OUTPUT="$OUTPUT_DIR/ARO-Language-Guide.html"

    pandoc \
        --standalone \
        --toc \
        --toc-depth=2 \
        --css="unix-style.css" \
        --metadata title="ARO: Business Logic as Language" \
        --metadata subtitle="The Language Guide" \
        --from markdown+raw_html \
        -o "$HTML_OUTPUT" \
        $FILE_LIST

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

HTML_OUTPUT="$OUTPUT_DIR/ARO-Language-Guide.html"

pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata title="ARO: Business Logic as Language" \
    --metadata subtitle="The Language Guide" \
    --from markdown+raw_html \
    --embed-resources \
    --self-contained \
    -o "$HTML_OUTPUT" \
    $FILE_LIST 2>/dev/null || \
pandoc \
    --standalone \
    --toc \
    --toc-depth=2 \
    --css="unix-style.css" \
    --metadata title="ARO: Business Logic as Language" \
    --metadata subtitle="The Language Guide" \
    --from markdown+raw_html \
    -o "$HTML_OUTPUT" \
    $FILE_LIST

echo "Created: $HTML_OUTPUT"
echo ""
echo "Done!"
echo ""
echo "Output files in: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
