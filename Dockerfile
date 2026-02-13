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

# Install build dependencies including LLVM 20 (required for Swifty-LLVM) and Rust (for plugins)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    pkg-config \
    curl \
    && wget https://apt.llvm.org/llvm.sh \
    && chmod +x llvm.sh \
    && ./llvm.sh 20 \
    && apt-get install -y --no-install-recommends llvm-20-dev \
    && ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && rm -rf /var/lib/apt/lists/* \
    && rm llvm.sh

# Install Rust for plugin compilation
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . $HOME/.cargo/env \
    && rustup default stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Create pkg-config file for LLVM 20
RUN mkdir -p /usr/lib/pkgconfig && \
    printf '%s\n' \
    'prefix=/usr/lib/llvm-20' \
    'exec_prefix=${prefix}' \
    'libdir=${prefix}/lib' \
    'includedir=${prefix}/include' \
    '' \
    'Name: LLVM' \
    'Description: Low-level Virtual Machine compiler framework' \
    'Version: 20.0.0' \
    'Libs: -L${libdir} -lLLVM-20' \
    'Cflags: -I${includedir}' \
    > /usr/lib/pkgconfig/llvm.pc

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
LABEL org.opencontainers.image.source="https://github.com/arolang/aro"
LABEL org.opencontainers.image.documentation="https://github.com/arolang/aro/blob/main/Documentation"

ARG VERSION=dev
ARG COMMIT_SHA=unknown

LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT_SHA}"

# Install runtime dependencies including LLVM 20 and Rust (for plugins)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libssl3 \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    curl \
    python3 \
    build-essential \
    && wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 20 \
    && apt-get install -y --no-install-recommends llvm-20 clang-20 \
    && ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && ln -sf /usr/bin/clang-20 /usr/bin/clang \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash aro

# Install Rust for plugin compilation
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . $HOME/.cargo/env \
    && rustup default stable
ENV PATH="/root/.cargo/bin:${PATH}"

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

# Install development tools including LLVM 20 and Rust (for plugins)
RUN apt-get update && apt-get install -y --no-install-recommends \
    vim \
    git \
    curl \
    jq \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    pkg-config \
    python3 \
    build-essential \
    && wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 20 \
    && apt-get install -y --no-install-recommends llvm-20-dev clang-20 \
    && ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && ln -sf /usr/bin/clang-20 /usr/bin/clang \
    && rm -rf /var/lib/apt/lists/*

# Install Rust for plugin compilation
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . $HOME/.cargo/env \
    && rustup default stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Create pkg-config file for LLVM 20
RUN mkdir -p /usr/lib/pkgconfig && \
    printf '%s\n' \
    'prefix=/usr/lib/llvm-20' \
    'exec_prefix=${prefix}' \
    'libdir=${prefix}/lib' \
    'includedir=${prefix}/include' \
    '' \
    'Name: LLVM' \
    'Description: Low-level Virtual Machine compiler framework' \
    'Version: 20.0.0' \
    'Libs: -L${libdir} -lLLVM-20' \
    'Cflags: -I${includedir}' \
    > /usr/lib/pkgconfig/llvm.pc

WORKDIR /workspace

# Copy source for development
COPY . .

# Build in debug mode for faster iteration
RUN swift build

# Development shell
CMD ["/bin/bash"]
