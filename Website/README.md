# ARO Website

The official website for the ARO Programming Language.

## Structure

```
Website/
├── src/                  # Source files
│   ├── index.html        # Landing page
│   ├── style.css         # Styles
│   ├── fdd.html          # FDD history page
│   ├── docs.html         # Documentation index
│   ├── getting-started.html  # Getting started guide
│   └── doc-template.html # Template for markdown docs
├── dist/                 # Built files (generated)
├── build.sh              # Build script
├── deploy.sh             # Deploy to gh-pages
└── README.md             # This file
```

## Building

```bash
./build.sh
```

This will generate the static site in the `dist/` folder.

## Preview Locally

```bash
cd dist
python3 -m http.server 8080
```

Then open http://localhost:8080

## Deploy to GitHub Pages

```bash
./deploy.sh
```

This will:
1. Build the site
2. Push to the `gh-pages` branch
3. GitHub Pages will serve it automatically

## Design

The website features:
- Modern dark theme with colorful gradients
- Large, bold typography using Space Grotesk
- Code examples with JetBrains Mono
- Responsive design
- No JavaScript required (pure HTML/CSS)

## Pages

- **Home** - Landing page with hero, features, and AI section
- **FDD Story** - History of Feature-Driven Development
- **Getting Started** - 5-minute tutorial
- **Docs** - Documentation index linking to GitHub markdown files
