/* =============================================================================
   ARO Website - Animation Scripts
   ============================================================================= */

(function() {
    'use strict';

    // ==========================================================================
    // Progress Bar
    // ==========================================================================
    function initProgressBar() {
        const progressBar = document.getElementById('progressBar');
        if (!progressBar) return;

        function updateProgress() {
            const scrollTop = window.scrollY;
            const docHeight = document.documentElement.scrollHeight - window.innerHeight;
            const progress = docHeight > 0 ? (scrollTop / docHeight) * 100 : 0;
            progressBar.style.width = progress + '%';
        }

        window.addEventListener('scroll', updateProgress, { passive: true });
        updateProgress();
    }

    // ==========================================================================
    // Scroll-Triggered Animations
    // ==========================================================================
    function initScrollAnimations() {
        const observerOptions = {
            threshold: 0.1,
            rootMargin: '0px 0px -50px 0px'
        };

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                }
            });
        }, observerOptions);

        // Observe all animated elements
        const animatedElements = document.querySelectorAll(
            '.animate-on-scroll, .animate-slide-left, .animate-slide-right, .animate-scale'
        );
        animatedElements.forEach(el => observer.observe(el));
    }

    // ==========================================================================
    // Timeline Animations (for tutorial page)
    // ==========================================================================
    function initTimelineAnimations() {
        const timelineElements = document.querySelectorAll('.timeline');
        if (timelineElements.length === 0) return;

        const timelineObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                }
            });
        }, { threshold: 0.2 });

        timelineElements.forEach(el => timelineObserver.observe(el));
    }

    // ==========================================================================
    // Floating Navigation (for pages with section nav)
    // ==========================================================================
    function initFloatingNav() {
        // Support both data-section and tutorial-section patterns
        let sections = document.querySelectorAll('[data-section]');
        if (sections.length === 0) {
            sections = document.querySelectorAll('.tutorial-section[id]');
        }
        const navLinks = document.querySelectorAll('.floating-nav a');

        if (sections.length === 0 || navLinks.length === 0) return;

        function updateNav() {
            const scrollPos = window.scrollY + window.innerHeight / 2;

            sections.forEach((section, index) => {
                const top = section.offsetTop;
                const height = section.offsetHeight;

                if (scrollPos >= top && scrollPos < top + height) {
                    navLinks.forEach(link => link.classList.remove('active'));
                    if (navLinks[index]) navLinks[index].classList.add('active');
                }
            });
        }

        window.addEventListener('scroll', updateNav, { passive: true });
        updateNav();

        // Smooth scroll for nav links
        navLinks.forEach(link => {
            link.addEventListener('click', (e) => {
                e.preventDefault();
                const target = document.querySelector(link.getAttribute('href'));
                if (target) {
                    target.scrollIntoView({ behavior: 'smooth' });
                }
            });
        });
    }

    // ==========================================================================
    // Card Hover Effects (staggered)
    // ==========================================================================
    function initCardStagger() {
        const cards = document.querySelectorAll('.feature-card, .glass-card');
        cards.forEach((card, index) => {
            if (!card.classList.contains('stagger-1') &&
                !card.classList.contains('stagger-2') &&
                !card.classList.contains('stagger-3')) {
                card.classList.add(`stagger-${(index % 6) + 1}`);
            }
        });
    }

    // ==========================================================================
    // Nav Scroll Effect (add shadow on scroll)
    // ==========================================================================
    function initNavScrollEffect() {
        const nav = document.querySelector('.nav');
        if (!nav) return;

        let lastScroll = 0;

        window.addEventListener('scroll', () => {
            const currentScroll = window.scrollY;

            if (currentScroll > 50) {
                nav.classList.add('nav-scrolled');
            } else {
                nav.classList.remove('nav-scrolled');
            }

            lastScroll = currentScroll;
        }, { passive: true });
    }

    // ==========================================================================
    // GitHub Stars Fetcher
    // ==========================================================================
    function initGitHubStars() {
        const starsCountEl = document.querySelector('.github-stars-count');
        if (!starsCountEl) return;

        // Check for cached value first (cache for 1 hour)
        const cacheKey = 'github-stars-aro';
        const cacheTimeKey = 'github-stars-aro-time';
        const cached = localStorage.getItem(cacheKey);
        const cacheTime = localStorage.getItem(cacheTimeKey);
        const oneHour = 60 * 60 * 1000;

        if (cached && cacheTime && (Date.now() - parseInt(cacheTime)) < oneHour) {
            starsCountEl.textContent = cached;
            starsCountEl.classList.add('loaded');
            return;
        }

        // Fetch from GitHub API
        fetch('https://api.github.com/repos/KrisSimon/aro')
            .then(response => {
                if (!response.ok) throw new Error('API error');
                return response.json();
            })
            .then(data => {
                const stars = data.stargazers_count;
                const formatted = stars >= 1000 ? (stars / 1000).toFixed(1) + 'k' : stars.toString();
                starsCountEl.textContent = formatted;
                starsCountEl.classList.add('loaded');

                // Cache the result
                localStorage.setItem(cacheKey, formatted);
                localStorage.setItem(cacheTimeKey, Date.now().toString());
            })
            .catch(() => {
                // On error, hide the stars count gracefully
                starsCountEl.style.display = 'none';
            });
    }

    // ==========================================================================
    // Initialize All Animations
    // ==========================================================================
    function init() {
        initProgressBar();
        initScrollAnimations();
        initTimelineAnimations();
        initFloatingNav();
        initCardStagger();
        initNavScrollEffect();
        initGitHubStars();
    }

    // Run on DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
