#!/bin/bash
# =============================================================================
# test-examples-in-docker.sh
# Runs test-examples.pl in a Swift 6.2 Docker container with all dependencies
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Running ARO tests in Swift 6.2 Docker container ==="
echo ""

docker run --rm -v "$SCRIPT_DIR:/workspace" -w /workspace swift:6.2-jammy bash -c '
set -e

echo "=== Installing dependencies ==="
apt-get update -qq
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq \
    perl \
    curl \
    wget \
    llvm-14 \
    clang-14 \
    libipc-run-perl \
    libjson-perl \
    libyaml-libyaml-perl \
    libhttp-tiny-perl \
    zlib1g-dev \
    libsqlite3-dev \
    cpanminus \
    > /dev/null 2>&1

# Setup LLVM symlinks
ln -sf /usr/bin/llc-14 /usr/bin/llc
ln -sf /usr/bin/clang-14 /usr/bin/clang
export PATH="/usr/lib/llvm-14/bin:$PATH"

# Install additional Perl modules
cpanm -q --notest Net::EmptyPort Term::ANSIColor 2>/dev/null || true

echo "=== Verifying LLVM installation ==="
llc --version | head -2
clang --version | head -1

echo ""
echo "=== Building ARO (debug) ==="
swift build -c debug 2>&1 | tail -5

echo ""
echo "=== Building ARO (release) ==="
swift build -c release 2>&1 | tail -5

echo ""
echo "=== Verifying ARO binary ==="
.build/release/aro --version || .build/release/aro --help | head -3

echo ""
echo "=== Running test-examples.pl ==="
./test-examples.pl 2>&1
'
