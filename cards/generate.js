import puppeteer from 'puppeteer';
import yaml from 'js-yaml';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load shared CSS
const cssContent = fs.readFileSync(path.join(__dirname, 'styles.css'), 'utf8');

// Category colors for visual distinction
const categoryColors = {
  'Syntax': '#7c3aed',
  'HTTP': '#06b6d4',
  'Events': '#f472b6',
  'Lifecycle': '#10b981',
  'Data': '#f59e0b',
  'Services': '#06b6d4',
  'DevOps': '#10b981',
  'Philosophy': '#a855f7',
  'Actions': '#ec4899',
  'Files': '#22c55e',
  'Testing': '#eab308',
  'Business': '#3b82f6',
  'Contract': '#0ea5e9',
  'API': '#14b8a6',
  'State': '#8b5cf6',
  'Sockets': '#f97316',
  'IDE': '#84cc16',
  'Compiler': '#ef4444',
  'Plugins': '#06d6a0',
  'Date': '#ff6b6b',
};

function generateCombinedHTML(fact) {
  const categoryColor = categoryColors[fact.category] || '#7c3aed';

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --category-color: ${categoryColor};
    }
    ${cssContent}
    /* Override for PNG generation - use body instead of .card */
    body {
      width: 1200px;
      height: 1200px;
      font-family: 'Space Grotesk', system-ui, sans-serif;
      display: flex;
      flex-direction: column;
      margin: 0;
      padding: 0;
    }
  </style>
</head>
<body>
  <!-- FRONT (Top Half - Dark) -->
  <div class="front">
    <div class="glow-1"></div>
    <div class="glow-2"></div>

    <div class="content">
      <div class="header">
        <div class="logo">ARO</div>
        <div class="category">${fact.category}</div>
      </div>

      <div class="headline-wrapper">
        <div class="headline">${escapeHtml(fact.headline)}</div>
      </div>
    </div>
  </div>

  <div class="divider"></div>

  <!-- BACK (Bottom Half - Light) -->
  <div class="back">
    <div class="glow-1"></div>
    <div class="glow-2"></div>

    <div class="content">
      <div class="explanation">${escapeHtml(fact.explanation)}</div>

      <div class="footer"><a href="https://github.com/arolang/aro">github.com/arolang/aro</a></div>
    </div>
  </div>
</body>
</html>`;
}

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function toTitleCase(str) {
  // Convert headline to PascalCase topic name
  return str
    .replace(/<[^>]+>/g, '') // Remove angle bracket tags
    .replace(/[^a-zA-Z0-9\s]/g, '') // Remove special chars
    .split(/\s+/)
    .filter(word => word.length > 0)
    .map(word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
}

async function generateCard(browser, fact, index) {
  const page = await browser.newPage();
  await page.setViewport({ width: 1200, height: 1200 });

  // Use explicit week/day (required for all entries)
  const week = String(fact.week).padStart(2, '0');
  const day = fact.day;

  const topic = toTitleCase(fact.headline);
  const baseName = `${week}-${day}-${fact.category}-${topic}`;

  // Generate combined card (front on top, back on bottom)
  console.log(`  Generating: ${baseName}.png`);
  const html = generateCombinedHTML(fact);
  await page.setContent(html, { waitUntil: 'networkidle0' });
  await page.screenshot({
    path: path.join(__dirname, 'output', `${baseName}.png`),
    type: 'png'
  });

  await page.close();
}

async function main() {
  console.log('ARO Card Generator');
  console.log('==================\n');
  console.log('Layout: Combined (Front top, Back bottom)');
  console.log('Dimensions: 1200x1200 (1:1 square)');
  console.log('Naming: Week-Day (01-1, 01-2, 02-1, ...)\n');

  // Load facts from YAML
  const yamlPath = path.join(__dirname, 'facts.yaml');
  const yamlContent = fs.readFileSync(yamlPath, 'utf8');
  const data = yaml.load(yamlContent);

  console.log(`Loaded ${data.facts.length} facts from facts.yaml\n`);

  // Ensure output directory exists
  const outputDir = path.join(__dirname, 'output');
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Clear existing output files
  const existingFiles = fs.readdirSync(outputDir).filter(f => f.endsWith('.png'));
  if (existingFiles.length > 0) {
    console.log(`Clearing ${existingFiles.length} existing PNG files...\n`);
    existingFiles.forEach(f => fs.unlinkSync(path.join(outputDir, f)));
  }

  // Launch browser
  console.log('Launching browser...\n');
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  try {
    // Generate cards for each fact
    for (let i = 0; i < data.facts.length; i++) {
      const fact = data.facts[i];
      console.log(`[Week ${fact.week} Day ${fact.day}] ${fact.id}`);
      await generateCard(browser, fact, i);
    }

    console.log('\n==================');
    console.log(`Generated ${data.facts.length} combined cards in ./output/`);
    console.log('Each card is 1200x1200 pixels (1:1)');
  } finally {
    await browser.close();
  }
}

main().catch(console.error);
