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

// Which card today gets
//
// One card a day, every day, in a fixed order — so the set is a year-long
// sequence rather than something that depends on when the schedule last ran.
// The index is the day of the year, which makes the mapping obvious from the
// outside: the 1st of January is the first card and the 31st of December is
// the last.
//
// The modulo is not decoration. A leap year has a 366th day, and the set is
// written for 365; wrapping means the extra day repeats the first card
// instead of posting nothing. It also keeps the script correct while the set
// is being written, when there may be fewer cards than days.
function dayOfYear(date = new Date()) {
  const start = Date.UTC(date.getUTCFullYear(), 0, 1);
  const today = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
  return Math.floor((today - start) / (24 * 60 * 60 * 1000)) + 1;
}

// Load cards from facts.yaml
function loadCards() {
  const factsPath = path.join(__dirname, 'facts.yaml');
  const factsContent = fs.readFileSync(factsPath, 'utf8');
  const data = yaml.load(factsContent);
  return data.facts;
}

// Sorted by the week and day they are filed under, so the order is the order
// someone reading facts.yaml sees, not the order the parser happened to
// produce.
function cardForDay(allCards, doy) {
  if (allCards.length === 0) return null;
  const ordered = [...allCards].sort((a, b) => (a.week - b.week) || (a.day - b.day));
  return ordered[(doy - 1) % ordered.length];
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
// failing. On 2026-09-28 that was a full disk: the instance was returning the
// same thing to its own media_proxy fetches and inbox deliveries for hours.
//
// Waiting and asking again is the right response to a busy server, and the
// wrong response to a bad token — so `isTransient` decides, and a 401 still
// fails on the first attempt with the message the server sent.
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
// our doubling does. An unparseable value falls back rather than throwing.
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

    // Get today's card
    const allCards = loadCards();
    const doy = dayOfYear();
    const todayCard = cardForDay(allCards, doy);

    if (!todayCard) {
      console.log('facts.yaml has no cards - skipping post');
      return;
    }

    console.log(`Day ${doy} of the year, ${allCards.length} cards in the set`);
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
