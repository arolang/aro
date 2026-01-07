# =============================================================================
# ARO Programming Language - Dockerfile
# =============================================================================
# Multi-stage build for the ARO compiler and runtime
#
# Build: docker build -t aro .
# Run:   docker run -v $(pwd)/myapp:/app aro run /app
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build Environment
# -----------------------------------------------------------------------------
FROM swift:6.2-jammy AS builder

# Build arguments for version info
ARG VERSION=dev
ARG COMMIT_SHA=unknown

# Install build dependencies including LLVM
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    llvm-14 \
    clang-14 \
    && ln -sf /usr/bin/llc-14 /usr/bin/llc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy package manifest first for better caching
COPY Package.swift Package.resolved ./

# Fetch dependencies (cached layer)
RUN swift package resolve

# Copy source files
COPY Sources/ Sources/
COPY Tests/ Tests/

# Build release binary
RUN swift build -c release \
    -Xswiftc -DVERSION=\"${VERSION}\" \
    -Xswiftc -DCOMMIT_SHA=\"${COMMIT_SHA}\" \
    --static-swift-stdlib

# Run tests to verify build
RUN swift test --parallel

# -----------------------------------------------------------------------------
# Stage 2: Runtime Environment
# -----------------------------------------------------------------------------
FROM swift:6.2-jammy AS runtime

# Labels for container metadata
LABEL org.opencontainers.image.title="ARO Programming Language"
LABEL org.opencontainers.image.description="The ARO Programming Language - Speak Business. Write Code."
LABEL org.opencontainers.image.vendor="Anthropic"
LABEL org.opencontainers.image.source="https://github.com/KrisSimon/aro"
LABEL org.opencontainers.image.documentation="https://github.com/KrisSimon/aro/blob/main/Documentation"

ARG VERSION=dev
ARG COMMIT_SHA=unknown

LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT_SHA}"

# Install runtime dependencies (Swift toolchain already present in base image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libssl3 \
    llvm-14 \
    clang-14 \
    && ln -sf /usr/bin/llc-14 /usr/bin/llc \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash aro

# Copy the built binary and runtime library
COPY --from=builder /build/.build/release/aro /usr/local/bin/aro
COPY --from=builder /build/.build/release/libARORuntime.a /usr/local/lib/libARORuntime.a

# Copy examples for reference
COPY Examples/ /opt/aro/examples/

# Set up working directory
WORKDIR /app

# Switch to non-root user
USER aro

# Default command shows help
ENTRYPOINT ["aro"]
CMD ["--help"]

# -----------------------------------------------------------------------------
# Stage 3: Development Environment (optional)
# -----------------------------------------------------------------------------
FROM swift:6.2-jammy AS dev

# Install development tools including LLVM
RUN apt-get update && apt-get install -y --no-install-recommends \
    vim \
    git \
    curl \
    jq \
    llvm-14 \
    clang-14 \
    && ln -sf /usr/bin/llc-14 /usr/bin/llc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Copy source for development
COPY . .

# Build in debug mode for faster iteration
RUN swift build

# Development shell
CMD ["/bin/bash"]
