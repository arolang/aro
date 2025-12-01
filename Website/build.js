const fs = require('fs');
const path = require('path');
const { marked } = require('marked');

// Ensure dist directory exists
if (!fs.existsSync('dist')) {
    fs.mkdirSync('dist', { recursive: true });
}
if (!fs.existsSync('dist/docs')) {
    fs.mkdirSync('dist/docs', { recursive: true });
}

// Copy static files
const filesToCopy = ['index.html', 'style.css', 'fdd.html', 'docs.html', 'getting-started.html'];
filesToCopy.forEach(file => {
    if (fs.existsSync(`src/${file}`)) {
        fs.copyFileSync(`src/${file}`, `dist/${file}`);
    }
});

// Convert markdown documentation to HTML
const docsDir = '../Documentation';
if (fs.existsSync(docsDir)) {
    const template = fs.readFileSync('src/doc-template.html', 'utf8');

    // Process StartWithARO.md
    if (fs.existsSync(`${docsDir}/StartWithARO.md`)) {
        const md = fs.readFileSync(`${docsDir}/StartWithARO.md`, 'utf8');
        const html = marked.parse(md);
        const page = template.replace('{{content}}', html).replace('{{title}}', 'Getting Started');
        fs.writeFileSync('dist/docs/getting-started.html', page);
    }
}

console.log('Build complete! Files written to dist/');
