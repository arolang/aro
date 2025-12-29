import puppeteer from 'puppeteer';
import yaml from 'js-yaml';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Design tokens from the ARO website
const design = {
  dark: {
    background: '#0a0a0f',
    text: '#e8e8ed',
    textMuted: '#8888a0',
    gradientStart: '#7c3aed',
    gradientEnd: '#06b6d4',
    glowColor: 'rgba(124, 58, 237, 0.3)',
  },
  light: {
    background: '#f8f9fc',
    text: '#1a1a2e',
    textMuted: '#5c5c7a',
    gradientStart: '#6d28d9',
    gradientEnd: '#0891b2',
    glowColor: 'rgba(109, 40, 217, 0.15)',
  }
};

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
};

function generateCombinedHTML(fact) {
  const dark = design.dark;
  const light = design.light;
  const categoryColor = categoryColors[fact.category] || dark.gradientStart;

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      width: 1200px;
      height: 1200px;
      font-family: 'Space Grotesk', system-ui, sans-serif;
      display: flex;
      flex-direction: column;
    }

    /* ===== FRONT SECTION (Top Half - Dark) ===== */
    .front {
      width: 1200px;
      height: 600px;
      background: ${dark.background};
      color: ${dark.text};
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      position: relative;
      overflow: hidden;
      padding: 40px 60px;
    }

    .front .glow-1 {
      position: absolute;
      width: 500px;
      height: 500px;
      border-radius: 50%;
      background: radial-gradient(circle, ${dark.glowColor} 0%, transparent 70%);
      top: -150px;
      left: -100px;
      pointer-events: none;
    }

    .front .glow-2 {
      position: absolute;
      width: 400px;
      height: 400px;
      border-radius: 50%;
      background: radial-gradient(circle, rgba(6, 182, 212, 0.15) 0%, transparent 70%);
      bottom: -100px;
      right: -50px;
      pointer-events: none;
    }

    .front .content {
      position: relative;
      z-index: 1;
      width: 100%;
      height: 100%;
      display: flex;
      flex-direction: column;
      align-items: center;
    }

    .front .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      width: 100%;
      margin-bottom: auto;
    }

    .front .headline-wrapper {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      width: 100%;
    }

    .front .logo {
      font-size: 48px;
      font-weight: 700;
      background: linear-gradient(135deg, ${dark.gradientStart}, ${dark.gradientEnd});
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    .front .category {
      font-size: 20px;
      font-weight: 600;
      color: ${categoryColor};
      text-transform: uppercase;
      letter-spacing: 2px;
    }

    .front .headline {
      font-family: 'JetBrains Mono', 'Fira Code', monospace;
      font-size: 54px;
      font-weight: 600;
      line-height: 1.2;
      text-align: center;
      background: linear-gradient(135deg, ${dark.gradientStart}, ${dark.gradientEnd});
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    /* ===== BACK SECTION (Bottom Half - Light) ===== */
    .back {
      width: 1200px;
      height: 600px;
      background: ${light.background};
      color: ${light.text};
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      position: relative;
      overflow: hidden;
      padding: 40px 60px;
    }

    .back .glow-1 {
      position: absolute;
      width: 500px;
      height: 500px;
      border-radius: 50%;
      background: radial-gradient(circle, ${light.glowColor} 0%, transparent 70%);
      top: -150px;
      left: -100px;
      pointer-events: none;
    }

    .back .glow-2 {
      position: absolute;
      width: 400px;
      height: 400px;
      border-radius: 50%;
      background: radial-gradient(circle, rgba(6, 182, 212, 0.1) 0%, transparent 70%);
      bottom: -100px;
      right: -50px;
      pointer-events: none;
    }

    .back .content {
      position: relative;
      z-index: 1;
      width: 100%;
      height: 100%;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
    }

    .back .explanation {
      font-size: 36px;
      font-weight: 400;
      line-height: 1.4;
      text-align: center;
      color: ${light.text};
    }

    .back .footer {
      margin-top: 25px;
      font-size: 18px;
      color: ${light.textMuted};
    }

    /* Divider line between sections */
    .divider {
      width: 100%;
      height: 2px;
      background: linear-gradient(90deg,
        transparent 0%,
        ${dark.gradientStart} 20%,
        ${dark.gradientEnd} 80%,
        transparent 100%
      );
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

      <div class="footer">github.com/KrisSimon/ARO</div>
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
