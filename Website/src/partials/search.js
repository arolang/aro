/* =============================================================
   search.js — docs site static client-side search (⌘K) — #449
   Zero dependencies, zero external calls: fetches a static
   search-index.json (built by build.js) and ranks it in-browser.
   Keeps the site's privacy posture (no Algolia, ADR-015).
   ============================================================= */
(function () {
    'use strict';

    var root = document.getElementById('aro-search');
    if (!root) return;
    var base = root.getAttribute('data-base') || '';

    var index = null;      // lazy-loaded array of {url,title,section,headings,text}
    var loading = false;
    var overlay, input, resultsEl;
    var active = -1;       // highlighted result index
    var current = [];      // current result set

    // ---- Index loading -------------------------------------------------
    function loadIndex(then) {
        if (index) { then(); return; }
        if (loading) { return; }
        loading = true;
        fetch(base + 'search-index.json')
            .then(function (r) { return r.ok ? r.json() : []; })
            .then(function (data) { index = Array.isArray(data) ? data : []; then(); })
            .catch(function () { index = []; then(); });
    }

    // ---- Ranking -------------------------------------------------------
    function tokenize(s) {
        return (s || '').toLowerCase().match(/[a-z0-9]+/g) || [];
    }

    function scoreEntry(entry, tokens, rawQuery) {
        var title = (entry.title || '').toLowerCase();
        var section = (entry.section || '').toLowerCase();
        var headings = (entry.headings || '').toLowerCase();
        var text = (entry.text || '').toLowerCase();
        var score = 0;
        for (var i = 0; i < tokens.length; i++) {
            var t = tokens[i];
            if (!t) continue;
            var hitTitle = title.indexOf(t) !== -1;
            var hitHead = headings.indexOf(t) !== -1;
            var hitText = text.indexOf(t) !== -1;
            if (!hitTitle && !hitHead && !hitText) return 0; // every token must appear somewhere
            if (hitTitle) score += 12;
            if (title.split(/\s+/).indexOf(t) !== -1) score += 8; // whole-word title bonus
            if (hitHead) score += 5;
            if (hitText) score += 1;
        }
        if (rawQuery && title.indexOf(rawQuery) !== -1) score += 15; // exact phrase in title
        if (section === 'docs') score += 1; // gently favour docs pages
        return score;
    }

    function snippetFor(entry, tokens) {
        var text = entry.text || '';
        var lower = text.toLowerCase();
        var pos = -1;
        for (var i = 0; i < tokens.length; i++) {
            var p = lower.indexOf(tokens[i]);
            if (p !== -1 && (pos === -1 || p < pos)) pos = p;
        }
        if (pos === -1) return text.slice(0, 140);
        var start = Math.max(0, pos - 50);
        var slice = text.slice(start, start + 160);
        return (start > 0 ? '…' : '') + slice + '…';
    }

    function escapeHtml(s) {
        return s.replace(/[&<>"]/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
        });
    }

    function highlight(text, tokens) {
        var out = escapeHtml(text);
        var uniq = tokens.filter(function (t, i) { return t && tokens.indexOf(t) === i; });
        uniq.sort(function (a, b) { return b.length - a.length; });
        for (var i = 0; i < uniq.length; i++) {
            var re = new RegExp('(' + uniq[i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'ig');
            out = out.replace(re, '<mark>$1</mark>');
        }
        return out;
    }

    function search(query) {
        var raw = query.trim().toLowerCase();
        var tokens = tokenize(query);
        if (!tokens.length) return [];
        var scored = [];
        for (var i = 0; i < index.length; i++) {
            var s = scoreEntry(index[i], tokens, raw);
            if (s > 0) scored.push({ entry: index[i], score: s });
        }
        scored.sort(function (a, b) { return b.score - a.score; });
        return scored.slice(0, 8).map(function (x) { return x.entry; });
    }

    // ---- Rendering -----------------------------------------------------
    function render(query) {
        var tokens = tokenize(query);
        current = query.trim() ? search(query) : [];
        active = current.length ? 0 : -1;
        if (!query.trim()) {
            resultsEl.innerHTML = '<div class="aro-search-empty">Type to search the documentation…</div>';
            return;
        }
        if (!current.length) {
            resultsEl.innerHTML = '<div class="aro-search-empty">No results for “' + escapeHtml(query.trim()) + '”.</div>';
            return;
        }
        var html = '';
        for (var i = 0; i < current.length; i++) {
            var e = current[i];
            html += '<a class="aro-search-result' + (i === active ? ' active' : '') +
                '" href="' + base + e.url + '" data-i="' + i + '">' +
                '<span class="aro-search-result-title">' + highlight(e.title || e.url, tokens) +
                (e.section ? '<span class="aro-search-result-section">' + escapeHtml(e.section) + '</span>' : '') +
                '</span>' +
                '<span class="aro-search-result-snippet">' + highlight(snippetFor(e, tokens), tokens) + '</span>' +
                '</a>';
        }
        resultsEl.innerHTML = html;
    }

    function setActive(i) {
        var items = resultsEl.querySelectorAll('.aro-search-result');
        if (!items.length) return;
        active = (i + items.length) % items.length;
        for (var k = 0; k < items.length; k++) items[k].classList.toggle('active', k === active);
        items[active].scrollIntoView({ block: 'nearest' });
    }

    function go() {
        var items = resultsEl.querySelectorAll('.aro-search-result');
        if (active >= 0 && items[active]) window.location.href = items[active].getAttribute('href');
    }

    // ---- Modal lifecycle -----------------------------------------------
    function buildModal() {
        overlay = document.createElement('div');
        overlay.className = 'aro-search-overlay';
        overlay.innerHTML =
            '<div class="aro-search-modal" role="dialog" aria-modal="true" aria-label="Search documentation">' +
            '<div class="aro-search-input-row">' +
            '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>' +
            '<input class="aro-search-input" type="text" placeholder="Search the docs…" ' +
            'autocomplete="off" spellcheck="false" aria-label="Search query">' +
            '<span class="aro-search-esc">esc</span>' +
            '</div>' +
            '<div class="aro-search-results"></div>' +
            '<div class="aro-search-footer"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span>' +
            '<span><kbd>↵</kbd> open</span><span><kbd>esc</kbd> close</span></div>' +
            '</div>';
        document.body.appendChild(overlay);
        input = overlay.querySelector('.aro-search-input');
        resultsEl = overlay.querySelector('.aro-search-results');

        input.addEventListener('input', function () { render(input.value); });
        input.addEventListener('keydown', function (e) {
            if (e.key === 'ArrowDown') { e.preventDefault(); setActive(active + 1); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(active - 1); }
            else if (e.key === 'Enter') { e.preventDefault(); go(); }
        });
        overlay.addEventListener('click', function (e) {
            var a = e.target.closest('.aro-search-result');
            if (a) return; // let the link navigate
            if (e.target === overlay) close();
        });
    }

    function open() {
        if (!overlay) buildModal();
        loadIndex(function () { render(input.value); });
        overlay.classList.add('open');
        document.body.style.overflow = 'hidden';
        input.value = '';
        render('');
        setTimeout(function () { input.focus(); }, 0);
    }

    function close() {
        if (!overlay) return;
        overlay.classList.remove('open');
        document.body.style.overflow = '';
    }

    function isOpen() { return overlay && overlay.classList.contains('open'); }

    // ---- Triggers ------------------------------------------------------
    document.addEventListener('keydown', function (e) {
        var mod = e.metaKey || e.ctrlKey;
        if (mod && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); isOpen() ? close() : open(); }
        else if (e.key === 'Escape' && isOpen()) { close(); }
        else if (e.key === '/' && !isOpen() && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) {
            e.preventDefault(); open();
        }
    });

    // Inject a discoverable trigger into the nav (no per-page HTML edits).
    function injectTrigger() {
        var nav = document.querySelector('.nav-links');
        if (!nav || nav.querySelector('.aro-search-trigger')) return;
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'aro-search-trigger';
        btn.setAttribute('aria-label', 'Search documentation');
        var isMac = /Mac|iPhone|iPad/.test(navigator.platform);
        btn.innerHTML =
            '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>' +
            '<span>Search</span><kbd>' + (isMac ? '⌘K' : 'Ctrl K') + '</kbd>';
        btn.addEventListener('click', open);
        nav.insertBefore(btn, nav.firstChild);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', injectTrigger);
    } else {
        injectTrigger();
    }
})();
