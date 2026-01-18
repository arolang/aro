#!/usr/bin/env python3
"""
Extract inline SVGs from markdown files and save as separate files.
Replace inline SVGs with image references.
"""

import re
import os
import sys
from pathlib import Path

def extract_svgs(markdown_file, images_dir):
    """Extract SVGs from a markdown file and save to images directory."""
    with open(markdown_file, 'r') as f:
        content = f.read()

    # Pattern to match SVG blocks (including multiline)
    svg_pattern = re.compile(r'<svg[^>]*>.*?</svg>', re.DOTALL)

    # Find all SVGs
    svgs = svg_pattern.findall(content)

    if not svgs:
        return content

    # Get base name for this chapter
    base_name = Path(markdown_file).stem

    # Replace each SVG with an image reference
    for i, svg in enumerate(svgs, 1):
        # Create SVG filename
        svg_filename = f"{base_name}-fig{i:02d}.svg"
        svg_path = os.path.join(images_dir, svg_filename)

        # Add XML declaration and fix viewBox for better rendering
        svg_content = svg
        if not svg_content.startswith('<?xml'):
            svg_content = '<?xml version="1.0" encoding="UTF-8"?>\n' + svg_content

        # Add width/height if only viewBox is specified (helps with rendering)
        if 'viewBox=' in svg_content and 'width=' not in svg_content:
            # Extract viewBox dimensions
            viewbox_match = re.search(r'viewBox="([^"]+)"', svg_content)
            if viewbox_match:
                parts = viewbox_match.group(1).split()
                if len(parts) == 4:
                    width, height = parts[2], parts[3]
                    svg_content = svg_content.replace('<svg ', f'<svg width="{width}" height="{height}" ', 1)

        # Save SVG file
        with open(svg_path, 'w') as f:
            f.write(svg_content)

        # Replace in content with image reference
        # Use relative path from markdown file location
        img_tag = f'![Figure {i}](images/{svg_filename})'
        content = content.replace(svg, img_tag, 1)

        print(f"  Extracted: {svg_filename}")

    return content

def main():
    script_dir = Path(__file__).parent
    images_dir = script_dir / 'images'
    processed_dir = script_dir / 'processed'

    # Create directories
    images_dir.mkdir(exist_ok=True)
    processed_dir.mkdir(exist_ok=True)

    # Process all markdown files
    for md_file in sorted(script_dir.glob('*.md')):
        if md_file.name == 'STRUCTURE.md':
            # Just copy structure file
            content = md_file.read_text()
        else:
            print(f"Processing {md_file.name}...")
            content = extract_svgs(md_file, images_dir)

        # Save processed file
        output_file = processed_dir / md_file.name
        with open(output_file, 'w') as f:
            f.write(content)

    # Copy other necessary files
    for file in ['metadata.yaml', 'unix-style.css']:
        src = script_dir / file
        if src.exists():
            (processed_dir / file).write_text(src.read_text())

    # Copy images directory reference
    print(f"\nExtracted SVGs to: {images_dir}")
    print(f"Processed markdown in: {processed_dir}")

if __name__ == '__main__':
    main()
