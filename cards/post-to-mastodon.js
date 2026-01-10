import fs from 'fs';
import yaml from 'js-yaml';
import fetch from 'node-fetch';
import FormData from 'form-data';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration from environment
const MASTODON_INSTANCE = process.env.MASTODON_INSTANCE;
const ACCESS_TOKEN = process.env.MASTODON_ACCESS_TOKEN;
const START_DATE = new Date(process.env.START_DATE || '2026-01-01');

// Calculate current week and day
function getCurrentWeekAndDay() {
  const today = new Date();
  const msPerDay = 24 * 60 * 60 * 1000;
  const daysSinceStart = Math.floor((today - START_DATE) / msPerDay);
  const weekNumber = Math.floor(daysSinceStart / 7) + 1;
  const dayOfWeek = today.getDay(); // 0=Sunday, 1=Monday, ..., 6=Saturday

  // Convert to Monday=1, Tuesday=2, ..., Friday=5
  const weekday = dayOfWeek === 0 ? null : (dayOfWeek === 6 ? null : dayOfWeek);

  return { week: weekNumber, weekday };
}

// Load cards from facts.yaml
function loadCards() {
  const factsPath = path.join(__dirname, 'facts.yaml');
  const factsContent = fs.readFileSync(factsPath, 'utf8');
  const data = yaml.load(factsContent);
  return data.facts;
}

// Get cards for current week
function getWeekCards(allCards, weekNumber) {
  return allCards.filter(card => card.week === weekNumber);
}

// Distribute cards evenly across weekdays
function getCardForToday(weekCards, weekday) {
  if (!weekday || weekCards.length === 0) return null;

  // Sort by day to ensure correct order
  const sorted = weekCards.sort((a, b) => a.day - b.day);
  const cardCount = sorted.length;

  if (cardCount >= 5) {
    // 1:1 mapping - each weekday gets a card
    return sorted[weekday - 1] || null;
  }

  // Evenly distribute cards across 5 weekdays
  // Example: 3 cards → Monday (1), Wednesday (3), Friday (5)
  const spacing = 5 / cardCount;
  const targetIndex = Math.floor((weekday - 1) / spacing);

  return sorted[targetIndex] || null;
}

// Upload media to Mastodon
async function uploadMedia(imagePath) {
  const form = new FormData();
  form.append('file', fs.createReadStream(imagePath));

  const response = await fetch(`${MASTODON_INSTANCE}/api/v1/media`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${ACCESS_TOKEN}`
    },
    body: form
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Media upload failed: ${response.statusText} - ${errorText}`);
  }

  const data = await response.json();
  return data.id;
}

// Post status to Mastodon
async function postStatus(text, mediaId) {
  const response = await fetch(`${MASTODON_INSTANCE}/api/v1/statuses`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${ACCESS_TOKEN}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      status: text,
      media_ids: [mediaId]
    })
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Status post failed: ${response.statusText} - ${errorText}`);
  }

  return await response.json();
}

// Main execution
async function main() {
  try {
    // Validate configuration
    if (!MASTODON_INSTANCE || !ACCESS_TOKEN) {
      console.log('Missing Mastodon configuration - skipping post');
      console.log('Set MASTODON_INSTANCE and MASTODON_ACCESS_TOKEN environment variables');
      return;
    }

    // Get current week and day
    const { week, weekday } = getCurrentWeekAndDay();
    console.log(`Current: Week ${week}, Weekday ${weekday}`);

    if (!weekday) {
      console.log('Today is weekend - skipping post');
      return;
    }

    // Load all cards
    const allCards = loadCards();
    const weekCards = getWeekCards(allCards, week);
    console.log(`Found ${weekCards.length} cards for week ${week}`);

    if (weekCards.length === 0) {
      console.log('No cards for this week - skipping post');
      return;
    }

    // Get today's card
    const todayCard = getCardForToday(weekCards, weekday);
    if (!todayCard) {
      console.log('No card scheduled for today - skipping post');
      return;
    }

    console.log(`Selected card: ${todayCard.id} - ${todayCard.category}`);

    // Find card image file
    const outputDir = path.join(__dirname, 'output');
    const cardFiles = fs.readdirSync(outputDir);
    const cardFile = cardFiles.find(f => f.startsWith(`${todayCard.id}-`));

    if (!cardFile) {
      throw new Error(`Card image not found: ${todayCard.id}`);
    }

    const imagePath = path.join(outputDir, cardFile);
    console.log(`Card image: ${imagePath}`);

    // Upload image
    console.log('Uploading image to Mastodon...');
    const mediaId = await uploadMedia(imagePath);

    // Create post text
    const postText = `${todayCard.category}\n\nLearn more: https://github.com/arolang/aro/wiki\n#AROLang`;

    // Post to Mastodon
    console.log('Posting to Mastodon...');
    const status = await postStatus(postText, mediaId);

    console.log(`✅ Posted successfully: ${status.url}`);

  } catch (error) {
    console.error('Error posting to Mastodon:', error);
    process.exit(1);
  }
}

main();
