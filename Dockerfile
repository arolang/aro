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
FROM swift:6.3-jammy AS builder

# Build arguments for version info
ARG VERSION=dev
ARG COMMIT_SHA=unknown

# Install build dependencies including LLVM 20 (required for Swifty-LLVM) and Rust (for plugins)
#
# The LLVM apt repository is added by hand rather than through
# `apt.llvm.org/llvm.sh`. `llvm.sh` calls `add-apt-repository`, which lives in
# `software-properties-common`, which pulls in the systemd/dbus chain. Those
# packages' postinst scripts try to take over `/etc/resolv.conf` and to talk to
# a system message bus, and inside a container under QEMU emulation both fail:
#
#   ln: failed to create symbolic link '/etc/resolv.conf': Device or resource busy
#   Failed to open connection to "system" message bus
#
# apt then exits 2 and the whole layer fails. Adding the repository is three
# lines of keyring and sources.list, needs neither `software-properties-common`
# nor `lsb-release`, and does exactly what `llvm.sh` would have done. The key
# fetch is retried because `apt.llvm.org` is a third-party host and one dropped
# connection would otherwise fail the layer.
#
# Same change as `docker/buildsystem/Dockerfile`, which hit this for real on the
# emulated arm64 build; every stage below carries it for the same reason.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    ca-certificates \
    wget \
    gnupg \
    pkg-config \
    curl \
    libgit2-dev \
    && ( for attempt in 1 2 3 4 5; do \
           wget -nv -O /tmp/llvm.key --tries=3 --timeout=30 --retry-connrefused \
                https://apt.llvm.org/llvm-snapshot.gpg.key && [ -s /tmp/llvm.key ] && exit 0; \
           echo "LLVM signing key fetch failed (attempt $attempt of 5); retrying"; \
           sleep 10; \
         done; \
         echo "could not fetch https://apt.llvm.org/llvm-snapshot.gpg.key"; exit 1 ) \
    && gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg < /tmp/llvm.key \
    && rm -f /tmp/llvm.key \
    && echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-20 main" > /etc/apt/sources.list.d/llvm-20.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends llvm-20-dev \
    && ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && ln -sf /usr/bin/llvm-objcopy-20 /usr/bin/llvm-objcopy \
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

# Run tests to verify build (skip when SKIP_TESTS=true)
ARG SKIP_TESTS=false
RUN if [ "$SKIP_TESTS" != "true" ]; then swift test --parallel --num-workers 2; fi

# -----------------------------------------------------------------------------
# Stage 2: Runtime Environment
# -----------------------------------------------------------------------------
FROM swift:6.3-jammy AS runtime

# Labels for container metadata
LABEL org.opencontainers.image.title="ARO Programming Language"
LABEL org.opencontainers.image.description="The ARO Programming Language - Speak Business. Write Code."
LABEL org.opencontainers.image.source="https://github.com/arolang/aro"
LABEL org.opencontainers.image.documentation="https://github.com/arolang/aro/blob/main/Documentation"

ARG VERSION=dev
ARG COMMIT_SHA=unknown

LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT_SHA}"

# Install runtime dependencies including LLVM 20 and Rust (for plugins)
#
# The LLVM apt repository is added by hand for the reason spelled out in the
# builder stage above: `llvm.sh` needs `add-apt-repository` from
# `software-properties-common`, and that package's systemd/dbus dependencies
# cannot run their postinst scripts in a container under QEMU emulation.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libssl3 \
    wget \
    gnupg \
    curl \
    python3 \
    build-essential \
    && ( for attempt in 1 2 3 4 5; do \
           wget -nv -O /tmp/llvm.key --tries=3 --timeout=30 --retry-connrefused \
                https://apt.llvm.org/llvm-snapshot.gpg.key && [ -s /tmp/llvm.key ] && exit 0; \
           echo "LLVM signing key fetch failed (attempt $attempt of 5); retrying"; \
           sleep 10; \
         done; \
         echo "could not fetch https://apt.llvm.org/llvm-snapshot.gpg.key"; exit 1 ) \
    && gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg < /tmp/llvm.key \
    && rm -f /tmp/llvm.key \
    && echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-20 main" > /etc/apt/sources.list.d/llvm-20.list \
    && apt-get update \
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
FROM swift:6.3-jammy AS dev

# Install development tools including LLVM 20 and Rust (for plugins)
#
# The LLVM apt repository is added by hand for the reason spelled out in the
# builder stage above: `llvm.sh` needs `add-apt-repository` from
# `software-properties-common`, and that package's systemd/dbus dependencies
# cannot run their postinst scripts in a container under QEMU emulation.
RUN apt-get update && apt-get install -y --no-install-recommends \
    vim \
    git \
    curl \
    jq \
    wget \
    gnupg \
    ca-certificates \
    pkg-config \
    python3 \
    build-essential \
    && ( for attempt in 1 2 3 4 5; do \
           wget -nv -O /tmp/llvm.key --tries=3 --timeout=30 --retry-connrefused \
                https://apt.llvm.org/llvm-snapshot.gpg.key && [ -s /tmp/llvm.key ] && exit 0; \
           echo "LLVM signing key fetch failed (attempt $attempt of 5); retrying"; \
           sleep 10; \
         done; \
         echo "could not fetch https://apt.llvm.org/llvm-snapshot.gpg.key"; exit 1 ) \
    && gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg < /tmp/llvm.key \
    && rm -f /tmp/llvm.key \
    && echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-20 main" > /etc/apt/sources.list.d/llvm-20.list \
    && apt-get update \
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
