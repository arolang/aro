# =============================================================================
# ARO Runtime Docker Image
# =============================================================================
# Minimal runtime container for executing compiled ARO binaries.
# Contains only the Swift runtime libraries and essential system libraries.
#
# Usage (in multi-stage build):
#   FROM ghcr.io/arolang/aro-buildsystem:latest AS builder
#   WORKDIR /app
#   COPY *.aro ./
#   RUN aro build . --release -o myapp
#
#   FROM ghcr.io/arolang/aro-runtime:latest
#   COPY --from=builder /app/myapp /usr/local/bin/myapp
#   ENTRYPOINT ["/usr/local/bin/myapp"]
# =============================================================================

FROM ubuntu:22.04

LABEL org.opencontainers.image.title="ARO Runtime"
LABEL org.opencontainers.image.description="Minimal runtime environment for ARO compiled binaries"
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

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 \
    libssl3 \
    ca-certificates \
    libstdc++6 \
    libatomic1 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

# Restore the real ldconfig after apt-get (was replaced for QEMU arm64 compatibility)
RUN if [ -f /sbin/ldconfig.real-bak ]; then \
      mv /sbin/ldconfig.real-bak /sbin/ldconfig; \
    fi

# Copy Swift runtime libraries from the Swift image
# We use a multi-stage approach to keep the image minimal
COPY --from=swift:6.2-jammy /usr/lib/swift/linux/*.so /usr/lib/swift/linux/

# Configure the dynamic linker to find Swift libraries.
# Use ENV rather than running ldconfig to avoid QEMU arm64 emulation issues
# during cross-compilation. LD_LIBRARY_PATH is respected by all Swift binaries.
RUN echo "/usr/lib/swift/linux" > /etc/ld.so.conf.d/swift.conf
ENV LD_LIBRARY_PATH=/usr/lib/swift/linux

# Create non-root user for running applications
RUN useradd -m -s /bin/bash aro

# Default working directory
WORKDIR /app

# Switch to non-root user
USER aro
