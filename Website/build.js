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

// Read head partial
const headPartial = fs.readFileSync('src/partials/head.html', 'utf8');

// Process HTML file with head partial injection
function processHtmlFile(srcPath, destPath, stylesheetPath = 'style.css') {
    if (!fs.existsSync(srcPath)) return;

    let content = fs.readFileSync(srcPath, 'utf8');

    // Replace {{head}} placeholder with head partial content
    const headContent = headPartial.replace('{{stylesheet}}', stylesheetPath);
    content = content.replace('{{head}}', headContent);

    fs.writeFileSync(destPath, content);
}

// Process main HTML files (stylesheet at same level)
const mainHtmlFiles = ['index.html', 'fdd.html', 'docs.html', 'getting-started.html', 'disclaimer.html'];
mainHtmlFiles.forEach(file => {
    processHtmlFile(`src/${file}`, `dist/${file}`, 'style.css');
});

// Process doc-template.html (stylesheet at parent level)
processHtmlFile('src/doc-template.html', 'dist/doc-template.html', '../style.css');

// Process docs subdirectory pages
const docsSubPages = ['event-driven.html', 'state-transitions.html', 'data-pipelines.html', 'native-compilation.html'];
docsSubPages.forEach(file => {
    processHtmlFile(`src/docs/${file}`, `dist/docs/${file}`, '../style.css');
});

// Copy style.css
if (fs.existsSync('src/style.css')) {
    fs.copyFileSync('src/style.css', 'dist/style.css');
}

// Convert markdown documentation to HTML
const docsDir = '../Documentation';
if (fs.existsSync(docsDir)) {
    const template = fs.readFileSync('src/doc-template.html', 'utf8');
    const headContent = headPartial.replace('{{stylesheet}}', '../style.css');
    const processedTemplate = template.replace('{{head}}', headContent);

    // Process StartWithARO.md
    if (fs.existsSync(`${docsDir}/StartWithARO.md`)) {
        const md = fs.readFileSync(`${docsDir}/StartWithARO.md`, 'utf8');
        const html = marked.parse(md);
        const page = processedTemplate.replace('{{content}}', html).replace('{{title}}', 'Getting Started');
        fs.writeFileSync('dist/docs/getting-started.html', page);
    }
}

console.log('Build complete! Files written to dist/');
