# =============================================================================
# ARO Cards - Docker Build
# =============================================================================
# Multi-stage build: Buildbox generates PNGs, Runtime serves the viewer
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Buildbox - Generate PNG cards with Puppeteer
# -----------------------------------------------------------------------------
FROM node:20-slim AS buildbox

# Install Chromium dependencies for Puppeteer
RUN apt-get update && apt-get install -y \
    chromium \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxss1 \
    xdg-utils \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Set Puppeteer to use system Chromium
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

WORKDIR /app

# Copy package files and install dependencies
COPY package.json package-lock.json* ./
RUN npm ci --ignore-scripts || npm install

# Copy source files
COPY generate.js styles.css facts.yaml ./

# Generate PNG cards
RUN node generate.js

# -----------------------------------------------------------------------------
# Stage 2: Runtime - Serve static files with nginx
# -----------------------------------------------------------------------------
FROM nginx:alpine AS runtime

# Copy nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy viewer files and set proper permissions
COPY --chmod=644 index.html styles.css facts.yaml viewer.js /usr/share/nginx/html/

# Copy generated PNG cards from buildbox
COPY --from=buildbox --chmod=644 /app/output /usr/share/nginx/html/output/

# Expose port 80
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost/ || exit 1

# Run nginx
CMD ["nginx", "-g", "daemon off;"]
