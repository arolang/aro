// ARO Card Viewer - Arrow key navigation

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

let facts = [];
let currentIndex = 0;

// DOM elements
const categoryEl = document.getElementById('category');
const headlineEl = document.getElementById('headline');
const explanationEl = document.getElementById('explanation');
const counterEl = document.getElementById('counter');

// Escape HTML to prevent XSS
function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

// Render the current card
function renderCard(index) {
  if (facts.length === 0) return;

  // Wrap around
  if (index < 0) index = facts.length - 1;
  if (index >= facts.length) index = 0;
  currentIndex = index;

  const fact = facts[index];

  // Set category color CSS variable
  const color = categoryColors[fact.category] || '#7c3aed';
  document.documentElement.style.setProperty('--category-color', color);

  // Update content
  categoryEl.textContent = fact.category;
  headlineEl.innerHTML = escapeHtml(fact.headline);
  explanationEl.innerHTML = escapeHtml(fact.explanation);

  // Update counter
  counterEl.textContent = `${index + 1} / ${facts.length}`;

  // Update URL with query parameter for deep linking
  const url = new URL(window.location);
  url.searchParams.set('card', index + 1);
  window.history.replaceState({}, '', url);
}

// Navigation functions
function nextCard() {
  renderCard(currentIndex + 1);
}

function prevCard() {
  renderCard(currentIndex - 1);
}

// Keyboard navigation
document.addEventListener('keydown', (e) => {
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
    nextCard();
  } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
    prevCard();
  } else if (e.key === 'Home') {
    renderCard(0);
  } else if (e.key === 'End') {
    renderCard(facts.length - 1);
  }
});

// Touch/swipe support
let touchStartX = 0;
document.addEventListener('touchstart', (e) => {
  touchStartX = e.touches[0].clientX;
});

document.addEventListener('touchend', (e) => {
  const touchEndX = e.changedTouches[0].clientX;
  const diff = touchStartX - touchEndX;

  if (Math.abs(diff) > 50) {
    if (diff > 0) {
      nextCard();
    } else {
      prevCard();
    }
  }
});

// Click navigation (left/right halves of screen)
document.addEventListener('click', (e) => {
  const screenWidth = window.innerWidth;
  if (e.clientX < screenWidth / 3) {
    prevCard();
  } else if (e.clientX > (screenWidth * 2 / 3)) {
    nextCard();
  }
});

// Initialize
async function init() {
  try {
    const response = await fetch('facts.yaml');
    if (!response.ok) throw new Error('Failed to load facts.yaml');

    const yamlText = await response.text();
    const data = jsyaml.load(yamlText);
    facts = data.facts;

    // Check for query parameter to jump to specific card
    const params = new URLSearchParams(window.location.search);
    const cardParam = params.get('card');
    if (cardParam) {
      const cardNum = parseInt(cardParam, 10) - 1;
      if (cardNum >= 0 && cardNum < facts.length) {
        currentIndex = cardNum;
      }
    }

    renderCard(currentIndex);
  } catch (error) {
    console.error('Error loading cards:', error);
    headlineEl.textContent = 'Error loading cards';
    explanationEl.textContent = error.message;
  }
}

init();
