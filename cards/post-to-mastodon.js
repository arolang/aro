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

// Retrying transient failures
//
// This runs once a day on a schedule, against one instance, and a single
// refused request meant no card that day and a red workflow run. The refusal
// is usually not about us: a media upload that fails is Mastodon answering
//
//   503 {"error":"There was a temporary problem serving your request…"}
//
// which it returns from `service_unavailable` — the handler it uses for, among
// others, `Seahorse::Client::NetworkingError`, i.e. its own object storage
// timing out. On the morning this was added the instance was returning that to
// 16 of its own `media_proxy` fetches and 20 `/inbox` deliveries as well, all
// of them at almost exactly five seconds.
//
// Waiting and asking again is the right response to that, and the wrong
// response to a bad token — so `isTransient` decides, and a 401 still fails on
// the first attempt with the message the server sent.
const MAX_ATTEMPTS = 5;
const BASE_DELAY_MS = 2000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 429 and 5xx are the server saying "not now"; 408 is it giving up on a slow
// request. Every other 4xx is this client being wrong — a bad token, an image
// over the size limit, a status over the character limit — and no number of
// retries changes any of them.
function isTransient(status) {
  return status === 408 || status === 429 || (status >= 500 && status <= 599);
}

// Honour `Retry-After` when the server sends one, since it knows better than
// our doubling does. Both forms are legal; only the seconds form is worth
// parsing here, and an unparseable value falls back rather than throwing.
function backoffFor(attempt, response) {
  const header = response && response.headers && response.headers.get('retry-after');
  if (header) {
    const seconds = Number(header);
    if (Number.isFinite(seconds) && seconds > 0) return Math.min(seconds * 1000, 60000);
  }
  return BASE_DELAY_MS * Math.pow(2, attempt - 1);
}

async function failureFor(what, response) {
  const body = await response.text();
  const error = new Error(`${what} failed: ${response.status} ${response.statusText} - ${body}`);
  error.retryable = isTransient(response.status);
  error.backoffMs = backoffFor(1, response);
  return error;
}

// `run` is a factory rather than a promise, deliberately: each attempt has to
// build its own request. A `FormData` holding a `createReadStream` cannot be
// sent twice — the stream is consumed by the first attempt — so retrying a
// prepared body would upload zero bytes and turn a transient failure into a
// permanent, confusing one.
async function withRetry(label, run) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await run();
    } catch (error) {
      // A thrown fetch is a network error — DNS, connection reset, TLS. Those
      // are transient by nature; a response-derived error says for itself.
      const retryable = error.retryable !== undefined ? error.retryable : true;
      if (!retryable || attempt >= MAX_ATTEMPTS) throw error;

      const wait = error.backoffMs ? error.backoffMs * Math.pow(2, attempt - 1)
                                   : BASE_DELAY_MS * Math.pow(2, attempt - 1);
      console.log(`${label} failed (attempt ${attempt} of ${MAX_ATTEMPTS}): ${error.message}`);
      console.log(`  retrying in ${Math.round(wait / 1000)}s`);
      await sleep(wait);
    }
  }
}

// Upload media to Mastodon
async function uploadMedia(imagePath) {
  return withRetry('Media upload', async () => {
    // Built inside the attempt: see `withRetry`.
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
      throw await failureFor('Media upload', response);
    }

    const data = await response.json();
    return data.id;
  });
}

// Post status to Mastodon
async function postStatus(text, mediaId) {
  return withRetry('Status post', async () => {
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
      throw await failureFor('Status post', response);
    }

    return await response.json();
  });
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
