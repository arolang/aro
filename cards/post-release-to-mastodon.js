import fetch from 'node-fetch';

// Configuration from environment
const MASTODON_INSTANCE = process.env.MASTODON_INSTANCE;
const ACCESS_TOKEN = process.env.MASTODON_ACCESS_TOKEN;

// Get version from command line argument
const version = process.argv[2];

if (!version) {
  console.error('Usage: node post-release-to-mastodon.js <version>');
  console.error('Example: node post-release-to-mastodon.js 0.1.0-alpha.2');
  process.exit(1);
}

// Skip if credentials not configured
if (!MASTODON_INSTANCE || !ACCESS_TOKEN) {
  console.log('Mastodon credentials not configured. Skipping announcement.');
  process.exit(0);
}

// Build release URL
const releaseUrl = `https://github.com/arolang/aro/releases/tag/${version}`;

// Compose announcement message
const message = `ARO Programming Language v${version} Released

Build business features as executable documentation.

Get started: ${releaseUrl}

#AROLang`;

// Post status to Mastodon
async function postStatus(text) {
  const response = await fetch(`${MASTODON_INSTANCE}/api/v1/statuses`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${ACCESS_TOKEN}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      status: text
    })
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Failed to post status: ${response.statusText} - ${errorText}`);
  }

  return await response.json();
}

// Main execution
async function main() {
  try {
    console.log('Posting release announcement to Mastodon...');
    console.log(`Version: ${version}`);
    console.log(`Instance: ${MASTODON_INSTANCE}`);

    const result = await postStatus(message);

    console.log('✅ Release announcement posted successfully!');
    console.log(`Posted to: ${result.url}`);
    process.exit(0);
  } catch (error) {
    console.error('❌ Failed to post release announcement:', error.message);
    process.exit(1);
  }
}

main();
