#!/bin/bash

# ============================================================
# ARO Website Build Script
# ============================================================
# Builds the static website into the dist/ folder
# ============================================================

set -e

echo "🏗️  Building ARO Website..."

# Create dist directory
mkdir -p dist
mkdir -p dist/docs

# Copy static files
echo "📄 Copying static files..."
cp src/index.html dist/
cp src/style.css dist/
cp src/fdd.html dist/
cp src/docs.html dist/
cp src/getting-started.html dist/

# Create a simple 404 page
cat > dist/404.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - ARO Programming Language</title>
    <link rel="stylesheet" href="/style.css">
</head>
<body>
    <div style="min-height: 100vh; display: flex; align-items: center; justify-content: center; text-align: center; padding: 24px;">
        <div>
            <h1 style="font-size: 6rem; margin-bottom: 16px; background: linear-gradient(135deg, #7c3aed 0%, #06b6d4 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;">404</h1>
            <p style="font-size: 1.5rem; color: #8888a0; margin-bottom: 32px;">This feature set doesn't exist yet.</p>
            <a href="/" style="display: inline-block; padding: 14px 28px; background: linear-gradient(135deg, #7c3aed 0%, #06b6d4 100%); color: white; text-decoration: none; border-radius: 8px; font-weight: 600;">Go Home</a>
        </div>
    </div>
</body>
</html>
EOF

# Create CNAME file if needed (for custom domain)
# echo "aro-lang.dev" > dist/CNAME

# Create .nojekyll for GitHub Pages
touch dist/.nojekyll

echo "✅ Build complete! Files are in dist/"
echo ""
echo "To preview locally:"
echo "  cd dist && python3 -m http.server 8080"
echo ""
echo "To deploy to gh-pages:"
echo "  ./deploy.sh"
