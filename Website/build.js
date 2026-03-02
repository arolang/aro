const fs = require('fs');
const path = require('path');
const { marked } = require('marked');

// Ensure dist directories exist
const distDirs = ['dist', 'dist/docs', 'dist/docs/guide', 'dist/docs/reference'];
distDirs.forEach(dir => {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
});

// Read partials
const headPartial = fs.readFileSync('src/partials/head.html', 'utf8');
const footerPartial = fs.readFileSync('src/partials/footer.html', 'utf8');

// Copy animation files to dist
fs.copyFileSync('src/partials/animations.css', 'dist/animations.css');
fs.copyFileSync('src/partials/animations.js', 'dist/animations.js');
fs.copyFileSync('src/partials/subpage.css', 'dist/subpage.css');

// Copy social share image
fs.copyFileSync('../Graphics/social.png', 'dist/social.png');

// Process HTML file with partial injection
function processHtmlFile(srcPath, destPath, basePath = '') {
    if (!fs.existsSync(srcPath)) return;

    let content = fs.readFileSync(srcPath, 'utf8');

    // Check if file uses {{TEMPLATE:...}} syntax
    const templateMatch = content.match(/^\{\{TEMPLATE:([^}]+)\}\}/);
    if (templateMatch) {
        const templateName = templateMatch[1];
        const templatePath = path.join('src', templateName);

        if (fs.existsSync(templatePath)) {
            const template = fs.readFileSync(templatePath, 'utf8');

            // Extract title
            const titleMatch = content.match(/\{\{title:([^}]+)\}\}/);
            const title = titleMatch ? titleMatch[1] : 'Documentation';

            // Extract content (everything after {{content: until the closing }})
            const contentMatch = content.match(/\{\{content:([\s\S]*)\}\}\s*$/);
            const pageContent = contentMatch ? contentMatch[1].trim() : '';

            // Replace placeholders in template
            content = template
                .replace('{{title}}', title)
                .replace('{{content}}', pageContent);
        }
    }

    // Calculate stylesheet paths based on basePath
    const stylesheetPath = basePath + 'style.css';
    const animationsStylesheetPath = basePath + 'animations.css';
    const subpageStylesheetPath = basePath + 'subpage.css';

    // Replace {{head}} placeholder with head partial content
    let headContent = headPartial
        .replace('{{stylesheet}}', stylesheetPath)
        .replace('{{animations-stylesheet}}', animationsStylesheetPath)
        .replace('{{subpage-stylesheet}}', subpageStylesheetPath);
    content = content.replace('{{head}}', headContent);

    // Replace {{footer}} placeholder with footer partial content
    let footerContent = footerPartial.replace(/\{\{base\}\}/g, basePath);
    content = content.replace('{{footer}}', footerContent);

    fs.writeFileSync(destPath, content);
}

// Process main HTML files (at root level)
const mainHtmlFiles = ['index.html', 'fdd.html', 'docs.html', 'getting-started.html', 'disclaimer.html', 'tutorial.html', 'download.html', 'imprint.html'];
mainHtmlFiles.forEach(file => {
    processHtmlFile(`src/${file}`, `dist/${file}`, '');
});

// Process doc-template.html (one level deep)
processHtmlFile('src/doc-template.html', 'dist/doc-template.html', '../');

// Process docs subdirectory pages (one level deep)
const docsSubPages = [
    'event-driven.html',
    'state-transitions.html',
    'data-pipelines.html',
    'native-compilation.html',
    'language-proposals.html',
    'the-basics.html',
    'feature-sets.html',
    'actions.html',
    'application-lifecycle.html',
    'contract-first.html',
    'custom-actions.html',
    'http-services.html',
    'sockets.html',
    'websockets.html',
    'templates.html',
    'terminal-ui.html',
    'repositories.html',
    'services.html',
    'file-operations.html',
    'ai-development-guide.html',
    'format-aware-io.html',
    'working-with-dates.html',
    'set-operations.html',
    'packages.html',
    'writing-extensions.html'
];
docsSubPages.forEach(file => {
    processHtmlFile(`src/docs/${file}`, `dist/docs/${file}`, '../');
});

// Copy style.css
if (fs.existsSync('src/style.css')) {
    fs.copyFileSync('src/style.css', 'dist/style.css');
}

// Read template for markdown docs (1 level deep: /docs/)
const docTemplate = fs.readFileSync('src/doc-template.html', 'utf8');
const docHeadContent = headPartial
    .replace('{{stylesheet}}', '../style.css')
    .replace('{{animations-stylesheet}}', '../animations.css')
    .replace('{{subpage-stylesheet}}', '../subpage.css');
const docFooterContent = footerPartial.replace(/\{\{base\}\}/g, '../');
const processedDocTemplate = docTemplate
    .replace('{{head}}', docHeadContent)
    .replace('{{footer}}', docFooterContent);

// Template for nested pages (2 levels deep: /docs/guide/, /docs/reference/)
const nestedDocTemplate = fs.readFileSync('src/doc-template-nested.html', 'utf8');
const nestedHeadContent = headPartial
    .replace('{{stylesheet}}', '../../style.css')
    .replace('{{animations-stylesheet}}', '../../animations.css')
    .replace('{{subpage-stylesheet}}', '../../subpage.css');
const nestedFooterContent = footerPartial.replace(/\{\{base\}\}/g, '../../');
const processedNestedTemplate = nestedDocTemplate
    .replace('{{head}}', nestedHeadContent)
    .replace('{{footer}}', nestedFooterContent);

// Extract title from markdown content
function extractTitle(markdown) {
    const match = markdown.match(/^#\s+(.+)$/m);
    return match ? match[1] : 'Documentation';
}

// Process a markdown file to HTML
function processMarkdownFile(srcPath, destPath, template) {
    if (!fs.existsSync(srcPath)) return null;

    const md = fs.readFileSync(srcPath, 'utf8');
    const title = extractTitle(md);
    const html = marked.parse(md);
    const page = template
        .replace('{{content}}', html)
        .replace('{{title}}', title);

    fs.writeFileSync(destPath, page);
    return { title, srcPath, destPath };
}

// Documentation directory
const docsDir = '../Documentation';

// Process top-level documentation files
const topLevelDocs = [
    { src: 'GettingStarted.md', dest: 'getting-started.html' },
    { src: 'StartWithARO.md', dest: 'start-with-aro.html' },
    { src: 'LanguageTour.md', dest: 'language-tour.html' },
    { src: 'ActionDeveloperGuide.md', dest: 'action-developer-guide.html' },
    { src: 'README.md', dest: 'index.html' }
];

console.log('Processing top-level documentation...');
topLevelDocs.forEach(doc => {
    const srcPath = `${docsDir}/${doc.src}`;
    const destPath = `dist/docs/${doc.dest}`;
    if (fs.existsSync(srcPath)) {
        const result = processMarkdownFile(srcPath, destPath, processedDocTemplate);
        if (result) {
            console.log(`  - ${doc.src} -> ${doc.dest}`);
        }
    }
});

// Process LanguageGuide files
const languageGuideDir = `${docsDir}/LanguageGuide`;
if (fs.existsSync(languageGuideDir)) {
    console.log('Processing LanguageGuide...');
    const guideFiles = fs.readdirSync(languageGuideDir).filter(f => f.endsWith('.md'));

    guideFiles.forEach(file => {
        const srcPath = `${languageGuideDir}/${file}`;
        const destFile = file.replace('.md', '.html').toLowerCase().replace(/\s+/g, '-');
        const destPath = `dist/docs/guide/${destFile}`;

        const result = processMarkdownFile(srcPath, destPath, processedNestedTemplate);
        if (result) {
            console.log(`  - LanguageGuide/${file} -> guide/${destFile}`);
        }
    });
}

// Process LanguageReference files
const languageRefDir = `${docsDir}/LanguageReference`;
if (fs.existsSync(languageRefDir)) {
    console.log('Processing LanguageReference...');
    const refFiles = fs.readdirSync(languageRefDir).filter(f => f.endsWith('.md'));

    refFiles.forEach(file => {
        const srcPath = `${languageRefDir}/${file}`;
        const destFile = file.replace('.md', '.html').toLowerCase().replace(/\s+/g, '-');
        const destPath = `dist/docs/reference/${destFile}`;

        const result = processMarkdownFile(srcPath, destPath, processedNestedTemplate);
        if (result) {
            console.log(`  - LanguageReference/${file} -> reference/${destFile}`);
        }
    });
}

console.log('Build complete! Files written to dist/');
