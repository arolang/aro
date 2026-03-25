# =============================================================================
# ARO Build System Docker Image
# =============================================================================
# Full build environment for compiling ARO code into native binaries.
# Includes Swift 6.2, LLVM 20, and the ARO CLI.
#
# Usage:
#   docker run -v $(pwd):/app ghcr.io/arolang/aro-buildsystem:latest check .
#   docker run -v $(pwd):/app ghcr.io/arolang/aro-buildsystem:latest build . -o myapp
# =============================================================================

FROM swift:6.2-jammy

LABEL org.opencontainers.image.title="ARO Build System"
LABEL org.opencontainers.image.description="Build environment for compiling ARO applications to native binaries"
LABEL org.opencontainers.image.source="https://github.com/arolang/aro"
LABEL org.opencontainers.image.vendor="ARO Language"

# When cross-compiling for arm64 via QEMU on GitHub Actions, ldconfig segfaults
# under user-space emulation (exit 139). Replace it with a no-op for the duration
# of apt-get, then restore the real binary afterwards.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      mv /sbin/ldconfig /sbin/ldconfig.real-bak 2>/dev/null || true; \
      printf '#!/bin/sh\n' > /sbin/ldconfig; \
      chmod +x /sbin/ldconfig; \
    fi

# Install build dependencies including LLVM 20
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    wget \
    gnupg \
    pkg-config \
    git \
    lsb-release \
    software-properties-common \
    libzstd-dev \
    libgit2-dev \
    && wget -qO- https://apt.llvm.org/llvm.sh | bash -s 20 \
    && apt-get install -y --no-install-recommends llvm-20-dev clang-20 \
    && ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && ln -sf /usr/bin/clang-20 /usr/bin/clang \
    && rm -rf /var/lib/apt/lists/*

# Restore the real ldconfig after apt-get (was replaced for QEMU arm64 compatibility)
RUN if [ -f /sbin/ldconfig.real-bak ]; then \
      mv /sbin/ldconfig.real-bak /sbin/ldconfig && ldconfig; \
    fi

# Create pkg-config file for LLVM
RUN mkdir -p /usr/lib/pkgconfig && \
    printf '%s\n' \
    'prefix=/usr/lib/llvm-20' \
    'exec_prefix=${prefix}' \
    'libdir=${prefix}/lib' \
    'includedir=${prefix}/include' \
    '' \
    'Name: LLVM' \
    'Description: LLVM compiler framework' \
    'Version: 20.0.0' \
    'Libs: -L${libdir} -lLLVM-20' \
    'Cflags: -I${includedir}' \
    > /usr/lib/pkgconfig/llvm.pc

# Install Rust toolchain (required for compiling rust-plugin type managed plugins)
RUN wget -qO- https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Build ARO from source
WORKDIR /aro-build
ARG ARO_VERSION=main
RUN git clone --depth 1 --branch ${ARO_VERSION} https://github.com/arolang/aro.git . \
    && swift build -c release --static-swift-stdlib \
    && swift build -c release --product ARORuntime \
    && cp .build/release/aro /usr/local/bin/aro \
    && ARCH=$(uname -m) \
    && if [ "$ARCH" = "x86_64" ]; then TRIPLE="x86_64-unknown-linux-gnu"; \
       elif [ "$ARCH" = "aarch64" ]; then TRIPLE="aarch64-unknown-linux-gnu"; fi \
    && cp .build/${TRIPLE}/release/libARORuntime.a /usr/local/lib/libARORuntime.a \
    && rm -rf /aro-build

# Verify installation
RUN aro --version

# Set working directory for user code
WORKDIR /app

# Default entrypoint runs aro CLI
ENTRYPOINT ["aro"]
CMD ["--help"]
