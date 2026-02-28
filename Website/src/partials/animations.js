/* ============================================================
   ARO Website - Parallax & Console Animations
   Deep parallax scrolling, reveal animations, terminal effects
   ============================================================ */

(function() {
    'use strict';

    // ==========================================================================
    // Initialize All
    // ==========================================================================
    function init() {
        initProgressBar();
        initScrollAnimations();
        initParallax();
        initMobileMenu();
        initTypewriter();
        initCursorGlow();
        initGitHubStars();
        initCodeWindowReveal();
        initNavScrollEffect();
    }

    // ==========================================================================
    // Scroll Progress Bar
    // ==========================================================================
    function initProgressBar() {
        const existing = document.querySelector('.progress-bar');
        if (existing) return;

        const progressBar = document.createElement('div');
        progressBar.className = 'progress-bar';
        document.body.appendChild(progressBar);

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
        const elements = document.querySelectorAll(
            '.animate-on-scroll, .animate-slide-left, .animate-slide-right, .animate-scale'
        );

        if (!elements.length) return;

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                }
            });
        }, {
            threshold: 0.1,
            rootMargin: '0px 0px -50px 0px'
        });

        elements.forEach(el => observer.observe(el));
    }

    // ==========================================================================
    // Parallax Scrolling
    // ==========================================================================
    function initParallax() {
        const parallaxElements = document.querySelectorAll('[data-parallax]');
        if (!parallaxElements.length) return;

        // Skip on mobile or reduced motion
        if (window.matchMedia('(max-width: 768px)').matches ||
            window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            return;
        }

        let ticking = false;

        function updateParallax() {
            const scrollY = window.scrollY;

            parallaxElements.forEach(el => {
                const speed = parseFloat(el.dataset.parallax) || 0.5;
                const rect = el.getBoundingClientRect();
                const elementTop = rect.top + scrollY;
                const offset = (scrollY - elementTop + window.innerHeight) * speed;

                el.style.transform = `translate3d(0, ${offset}px, 0)`;
            });

            ticking = false;
        }

        window.addEventListener('scroll', () => {
            if (!ticking) {
                requestAnimationFrame(updateParallax);
                ticking = true;
            }
        }, { passive: true });

        updateParallax();
    }

    // ==========================================================================
    // Mobile Menu
    // ==========================================================================
    function initMobileMenu() {
        const toggle = document.querySelector('.nav-toggle');
        const menu = document.querySelector('.mobile-menu');

        if (!toggle || !menu) return;

        function closeMenu() {
            toggle.classList.remove('active');
            menu.classList.remove('active');
            document.body.classList.remove('menu-open');
        }

        toggle.addEventListener('click', () => {
            toggle.classList.toggle('active');
            menu.classList.toggle('active');
            document.body.classList.toggle('menu-open');
        });

        menu.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', closeMenu);
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && menu.classList.contains('active')) {
                closeMenu();
            }
        });

        window.addEventListener('resize', () => {
            if (window.innerWidth > 768 && menu.classList.contains('active')) {
                closeMenu();
            }
        });
    }

    // ==========================================================================
    // Typewriter Animation
    // ==========================================================================
    function initTypewriter() {
        const line1 = document.querySelector('.typewriter-line-1');
        const line2 = document.querySelector('.typewriter-line-2');

        if (!line1) return;

        const cursor = '<span class="typewriter-cursor">|</span>';

        const slogans = [
            ['Code that', 'reads itself.'],
            ['Features become', 'programs.'],
            ['Write what,', 'not how.'],
            ['AI-native', 'by design.'],
            ['Action. Result.', 'Object.'],
            ['Business logic,', 'natural syntax.'],
            ['Event-driven.', 'Contract-first.'],
            ['Less code.', 'More meaning.'],
            ['Plugins in', 'any language.'],
            ['Swift. Rust.', 'Python. C.'],
            ['From contract', 'to code.'],
            ['HTTP server?', 'Already running.'],
            ['WebSockets?', 'One line.'],
            ['No imports.', 'Just features.'],
            ['Errors handled.', 'Automatically.'],
            ['Think features.', 'Ship faster.'],
            ['Build once.', 'Run native.'],
            ['Native binaries.', 'Zero config.'],
            ['Domain events.', 'First class.'],
            ['Repositories', 'built in.'],
            ['Your feature.', 'Your language.'],
            ['The spec', 'is the code.'],
            ['Features, not', 'functions.'],
            ['LLMs write it', 'perfectly.'],
            ['Stream gigabytes.', 'Use kilobytes.'],
            ['Business language.', 'Machine speed.'],
            ['One app.', 'All languages.'],
            ['Intent.', 'Execution.'],
            ['The runtime', 'handles the rest.'],
            ['Compile to', 'a single file.'],
            ['Describe it.', 'Done.']
        ];

        let sloganIndex = 0;
        let charIndex = 0;
        let currentLine = 0;
        let isDeleting = false;

        function updateDisplay(line1Text, line2Text, cursorOnLine) {
            // Always set both lines explicitly to avoid dual cursor issues
            if (cursorOnLine === 1) {
                line1.innerHTML = line1Text + cursor;
                if (line2) line2.textContent = line2Text;
            } else if (cursorOnLine === 2) {
                line1.textContent = line1Text;
                if (line2) line2.innerHTML = line2Text + cursor;
            } else {
                line1.textContent = line1Text;
                if (line2) line2.textContent = line2Text;
            }
        }

        function type() {
            const [text1, text2] = slogans[sloganIndex];

            if (!isDeleting) {
                // Typing
                if (currentLine === 0) {
                    const displayText = text1.substring(0, charIndex);
                    updateDisplay(displayText, '', 1);
                    charIndex++;

                    if (charIndex > text1.length) {
                        if (line2) {
                            // Move to line 2
                            currentLine = 1;
                            charIndex = 0;
                            setTimeout(type, 150);
                            return;
                        } else {
                            // No line 2, pause then delete
                            setTimeout(() => {
                                isDeleting = true;
                                charIndex = text1.length;
                                type();
                            }, 3000);
                            return;
                        }
                    }
                } else {
                    const displayText = text2.substring(0, charIndex);
                    updateDisplay(text1, displayText, 2);
                    charIndex++;

                    if (charIndex > text2.length) {
                        // Done typing both lines, pause then delete
                        setTimeout(() => {
                            isDeleting = true;
                            charIndex = text2.length;
                            type();
                        }, 3000);
                        return;
                    }
                }
            } else {
                // Deleting
                if (currentLine === 1 && line2) {
                    // Delete line 2 first
                    const displayText = text2.substring(0, charIndex);
                    updateDisplay(text1, displayText, 2);
                    charIndex--;

                    if (charIndex < 0) {
                        // Line 2 empty, switch to line 1
                        currentLine = 0;
                        charIndex = text1.length;
                        // Clear line 2 and move cursor to line 1
                        updateDisplay(text1, '', 1);
                        setTimeout(type, 60);
                        return;
                    }
                } else {
                    // Delete line 1
                    const displayText = text1.substring(0, charIndex);
                    updateDisplay(displayText, '', 1);
                    charIndex--;

                    if (charIndex < 0) {
                        // Done deleting, move to next slogan
                        isDeleting = false;
                        currentLine = 0;
                        charIndex = 0;
                        sloganIndex = (sloganIndex + 1) % slogans.length;
                        setTimeout(type, 500);
                        return;
                    }
                }
            }

            const speed = isDeleting ? 40 : 80 + Math.random() * 40;
            setTimeout(type, speed);
        }

        setTimeout(type, 800);
    }

    // ==========================================================================
    // Cursor Glow Effect
    // ==========================================================================
    function initCursorGlow() {
        const glow = document.querySelector('.cursor-glow');
        if (!glow) return;

        // Skip on touch devices or reduced motion
        if (!window.matchMedia('(hover: hover)').matches ||
            window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            glow.remove();
            return;
        }

        let mouseX = 0, mouseY = 0;
        let glowX = 0, glowY = 0;

        document.addEventListener('mousemove', (e) => {
            mouseX = e.clientX;
            mouseY = e.clientY;
            glow.classList.add('active');
        });

        document.addEventListener('mouseleave', () => {
            glow.classList.remove('active');
        });

        function animate() {
            glowX += (mouseX - glowX) * 0.08;
            glowY += (mouseY - glowY) * 0.08;
            glow.style.left = glowX + 'px';
            glow.style.top = glowY + 'px';
            requestAnimationFrame(animate);
        }

        animate();
    }

    // ==========================================================================
    // GitHub Stars
    // ==========================================================================
    function initGitHubStars() {
        const counter = document.querySelector('.github-stars-count');
        if (!counter) return;

        // Check cache first
        const cacheKey = 'aro-github-stars';
        const cacheTimeKey = 'aro-github-stars-time';
        const cached = localStorage.getItem(cacheKey);
        const cacheTime = localStorage.getItem(cacheTimeKey);
        const oneHour = 3600000;

        if (cached && cacheTime && (Date.now() - parseInt(cacheTime)) < oneHour) {
            counter.textContent = cached;
            return;
        }

        fetch('https://api.github.com/repos/arolang/aro')
            .then(res => res.ok ? res.json() : Promise.reject())
            .then(data => {
                const stars = data.stargazers_count;
                const formatted = stars >= 1000 ? (stars / 1000).toFixed(1) + 'k' : stars.toString();
                counter.textContent = formatted;
                localStorage.setItem(cacheKey, formatted);
                localStorage.setItem(cacheTimeKey, Date.now().toString());
            })
            .catch(() => {
                counter.style.display = 'none';
            });
    }

    // ==========================================================================
    // Code Window Reveal
    // ==========================================================================
    function initCodeWindowReveal() {
        const codeWindows = document.querySelectorAll('.code-window');
        if (!codeWindows.length) return;

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                }
            });
        }, { threshold: 0.2 });

        codeWindows.forEach(win => observer.observe(win));
    }

    // ==========================================================================
    // Nav Scroll Effect
    // ==========================================================================
    function initNavScrollEffect() {
        const nav = document.querySelector('.nav');
        if (!nav) return;

        window.addEventListener('scroll', () => {
            if (window.scrollY > 50) {
                nav.classList.add('nav-scrolled');
            } else {
                nav.classList.remove('nav-scrolled');
            }
        }, { passive: true });
    }

    // ==========================================================================
    // Run on DOM Ready
    // ==========================================================================
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();
