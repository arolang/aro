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
    // Mobile Menu Toggle
    // ==========================================================================
    function initMobileMenu() {
        const navToggle = document.querySelector('.nav-toggle');
        const mobileMenu = document.querySelector('.mobile-menu');

        if (!navToggle || !mobileMenu) return;

        function toggleMenu() {
            navToggle.classList.toggle('active');
            mobileMenu.classList.toggle('active');
            document.body.classList.toggle('menu-open');
        }

        function closeMenu() {
            navToggle.classList.remove('active');
            mobileMenu.classList.remove('active');
            document.body.classList.remove('menu-open');
        }

        // Toggle menu on button click
        navToggle.addEventListener('click', toggleMenu);

        // Close menu when clicking a link
        mobileMenu.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', closeMenu);
        });

        // Close menu on escape key
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && mobileMenu.classList.contains('active')) {
                closeMenu();
            }
        });

        // Close menu when resizing to desktop
        window.addEventListener('resize', () => {
            if (window.innerWidth > 768 && mobileMenu.classList.contains('active')) {
                closeMenu();
            }
        });
    }

    // ==========================================================================
    // Typewriter Animation (Two-Line)
    // ==========================================================================
    class TypewriterAnimation {
        constructor(line1Element, line2Element, cursorElement, badgeElement, slogans, badgeTexts, options = {}) {
            this.line1 = line1Element;
            this.line2 = line2Element;
            this.cursor = cursorElement;
            this.badge = badgeElement;
            this.slogans = slogans;
            this.badgeTexts = badgeTexts;
            this.currentSloganIndex = 0;
            this.currentBadgeIndex = 0;
            this.currentLine1Text = '';
            this.currentLine2Text = '';
            this.isDeleting = false;
            this.isOnLine2 = false;
            this.isPaused = false;

            // Timing options (milliseconds)
            this.typeSpeed = options.typeSpeed || 100;
            this.deleteSpeed = options.deleteSpeed || 50;
            this.pauseAfterType = options.pauseAfterType || 2000;
            this.pauseAfterDelete = options.pauseAfterDelete || 500;

            this.start();
        }

        start() {
            this.type();
        }

        updateLine(lineElement, text) {
            // Clear the line and rebuild with text + cursor if active
            lineElement.innerHTML = '';
            if (text) {
                lineElement.appendChild(document.createTextNode(text));
            }
        }

        moveCursorToLine(lineElement) {
            // Move cursor to the end of the active line
            lineElement.appendChild(this.cursor);
        }

        changeBadge() {
            // Remove any existing classes to reset
            this.badge.classList.remove('fade-in');

            // Fade out
            this.badge.classList.add('fade-out');

            setTimeout(() => {
                // Change text while invisible
                this.currentBadgeIndex = (this.currentBadgeIndex + 1) % this.badgeTexts.length;
                this.badge.textContent = this.badgeTexts[this.currentBadgeIndex];

                // Fade in - remove fade-out and let default opacity take over
                this.badge.classList.remove('fade-out');
            }, 300); // Match CSS transition duration
        }

        type() {
            const currentSlogan = this.slogans[this.currentSloganIndex];
            const [line1Target, line2Target] = currentSlogan;

            // Track if we're about to start line 2 for the first time
            const wasOnLine1 = !this.isOnLine2 && !this.isDeleting;
            const line1Complete = this.currentLine1Text === line1Target;
            const line2NotStarted = this.currentLine2Text.length === 0;

            if (this.isDeleting) {
                // Delete from line 2 first, then line 1
                if (this.currentLine2Text.length > 0) {
                    this.currentLine2Text = line2Target.substring(0, this.currentLine2Text.length - 1);
                    this.isOnLine2 = true;
                } else if (this.currentLine1Text.length > 0) {
                    this.currentLine1Text = line1Target.substring(0, this.currentLine1Text.length - 1);
                    this.isOnLine2 = false;
                }
            } else {
                // Type line 1 first, then line 2
                if (this.currentLine1Text.length < line1Target.length) {
                    this.currentLine1Text = line1Target.substring(0, this.currentLine1Text.length + 1);
                    this.isOnLine2 = false;
                } else if (this.currentLine2Text.length < line2Target.length) {
                    // About to type on line 2
                    if (wasOnLine1 && line1Complete && line2NotStarted) {
                        // Just finished line 1, about to start line 2 - change badge now
                        this.changeBadge();
                    }
                    this.currentLine2Text = line2Target.substring(0, this.currentLine2Text.length + 1);
                    this.isOnLine2 = true;
                }
            }

            // Update DOM - rebuild both lines
            this.updateLine(this.line1, this.currentLine1Text);
            this.updateLine(this.line2, this.currentLine2Text);

            // Place cursor at the insertion point
            const activeLine = this.isOnLine2 ? this.line2 : this.line1;
            this.moveCursorToLine(activeLine);

            // Calculate next delay
            let delay = this.isDeleting ? this.deleteSpeed : this.typeSpeed;

            // Add natural variance (±30ms)
            delay += Math.random() * 60 - 30;

            // Check state transitions
            const isFullyTyped = this.currentLine1Text === line1Target && this.currentLine2Text === line2Target;
            const isFullyDeleted = this.currentLine1Text === '' && this.currentLine2Text === '';

            if (!this.isDeleting && isFullyTyped) {
                // Finished typing - pause then start deleting
                delay = this.pauseAfterType;
                this.isDeleting = true;
            } else if (this.isDeleting && isFullyDeleted) {
                // Finished deleting - move to next slogan
                this.isDeleting = false;
                this.currentSloganIndex = (this.currentSloganIndex + 1) % this.slogans.length;
                delay = this.pauseAfterDelete;
            }

            // Schedule next frame
            setTimeout(() => this.type(), delay);
        }
    }

    function initTypewriter() {
        const line1Element = document.querySelector('.typewriter-line-1');
        const line2Element = document.querySelector('.typewriter-line-2');
        const cursorElement = document.querySelector('.typewriter-cursor');
        const badgeElement = document.querySelector('.hero-badge');

        if (line1Element && line2Element && cursorElement && badgeElement) {
            // Two-line slogans: [line1, line2]
            const slogans = [
                ["Speak Business.", "Write Code."],
                ["Business Logic.", "Natural Syntax."],
                ["From Requirements", "to Runtime."],
                ["Write What", "You Mean."],
                ["Code That Reads", "Like English."],
                ["Action. Result.", "Object."],
                ["Event-Driven.", "Business-Aligned."],
                ["Contract-First.", "Feature-Focused."],
                ["Code IS", "the Error Message."],
                ["Less Code.", "More Meaning."]
            ];

            // 20 alternative badge texts
            const badgeTexts = [
                "A New Kind of Programming Language",
                "Business Logic Made Simple",
                "Code That Speaks Your Language",
                "From Intent to Implementation",
                "The Human-First Language",
                "Where Features Become Code",
                "Business-Driven Development",
                "Natural Language Programming",
                "Event-Driven by Design",
                "Contract-First Architecture",
                "Built for Humans and AI",
                "Action-Result-Object Pattern",
                "The Business Language Revolution",
                "Executable Requirements",
                "Feature-First Development",
                "Domain Logic, Pure Code",
                "No Stack Traces, Just Facts",
                "Happy Path by Default",
                "Simplicity Over Complexity",
                "The Future of Business Logic"
            ];

            new TypewriterAnimation(line1Element, line2Element, cursorElement, badgeElement, slogans, badgeTexts, {
                typeSpeed: 100,
                deleteSpeed: 50,
                pauseAfterType: 4000,
                pauseAfterDelete: 2500
            });
        }
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
        fetch('https://api.github.com/repos/arolang/aro')
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
    // Cursor Glow Effect
    // ==========================================================================
    function initCursorGlow() {
        const cursorGlow = document.querySelector('.cursor-glow');
        if (!cursorGlow) return;

        // Skip on mobile or if reduced motion preferred
        if (window.matchMedia('(max-width: 768px)').matches ||
            window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            cursorGlow.remove();
            return;
        }

        let mouseX = 0, mouseY = 0;
        let currentX = 0, currentY = 0;
        let rafId = null;

        document.addEventListener('mousemove', (e) => {
            mouseX = e.clientX;
            mouseY = e.clientY;
            cursorGlow.classList.add('active');
        });

        document.addEventListener('mouseleave', () => {
            cursorGlow.classList.remove('active');
        });

        function animate() {
            // Smooth follow with easing
            currentX += (mouseX - currentX) * 0.08;
            currentY += (mouseY - currentY) * 0.08;

            cursorGlow.style.left = currentX + 'px';
            cursorGlow.style.top = currentY + 'px';

            rafId = requestAnimationFrame(animate);
        }

        animate();
    }

    // ==========================================================================
    // Reveal Animations (enhanced scroll-triggered)
    // ==========================================================================
    function initRevealAnimations() {
        const observerOptions = {
            threshold: 0.15,
            rootMargin: '0px 0px -80px 0px'
        };

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                    // Optionally unobserve after reveal for performance
                    // observer.unobserve(entry.target);
                }
            });
        }, observerOptions);

        const revealElements = document.querySelectorAll(
            '.reveal-up, .reveal-left, .reveal-right, .reveal-scale'
        );
        revealElements.forEach(el => observer.observe(el));
    }

    // ==========================================================================
    // Scroll Progress Indicator (back to top)
    // ==========================================================================
    function initScrollIndicator() {
        const indicator = document.querySelector('.scroll-indicator');
        if (!indicator) return;

        const circle = indicator.querySelector('circle');
        const circumference = 2 * Math.PI * 23; // r=23

        if (circle) {
            circle.style.strokeDasharray = circumference;
        }

        function updateIndicator() {
            const scrollTop = window.scrollY;
            const docHeight = document.documentElement.scrollHeight - window.innerHeight;
            const progress = docHeight > 0 ? scrollTop / docHeight : 0;

            // Show/hide based on scroll position
            if (scrollTop > 300) {
                indicator.classList.add('visible');
            } else {
                indicator.classList.remove('visible');
            }

            // Update circle progress
            if (circle) {
                const offset = circumference * (1 - progress);
                circle.style.strokeDashoffset = offset;
            }
        }

        window.addEventListener('scroll', updateIndicator, { passive: true });

        // Click to scroll to top
        indicator.addEventListener('click', () => {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });

        updateIndicator();
    }

    // ==========================================================================
    // Micro-bounce on cards
    // ==========================================================================
    function initMicroBounce() {
        const cards = document.querySelectorAll('.doc-card, .feature-card');
        cards.forEach(card => {
            card.classList.add('micro-bounce');
        });
    }

    // ==========================================================================
    // Initialize All Animations
    // ==========================================================================
    function init() {
        initProgressBar();
        initScrollAnimations();
        initRevealAnimations();
        initTimelineAnimations();
        initFloatingNav();
        initCardStagger();
        initNavScrollEffect();
        initMobileMenu();
        initTypewriter();
        initGitHubStars();
        initCursorGlow();
        initScrollIndicator();
        initMicroBounce();
    }

    // Run on DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
