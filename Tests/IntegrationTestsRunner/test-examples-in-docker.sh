#!/bin/bash
# =============================================================================
# test-examples-in-docker.sh
# Runs Tests/IntegrationTestsRunner in a Swift 6.2 Docker container with
# all dependencies installed.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Running ARO tests in Swift 6.2 Docker container ==="
echo ""

docker run --rm -v "$SCRIPT_DIR:/workspace" -w /workspace swift:6.2-jammy bash -c '
set -e

# Copy the workspace from the (slow, inotify-broken) host bind-mount to a
# native overlayfs path inside the container, then run everything from
# there. Docker Desktop on macOS uses virtiofs/gRPC FUSE which (a) does
# not propagate inotify events — breaks FileWatcher — and (b) is slow for
# the many small-file ops that SwiftSyntax compilation does, which times
# out plugin examples like GreetingPlugin.
echo "=== Copying workspace to native filesystem (avoids virtiofs limits) ==="
mkdir -p /aro
# tar streams the bind mount into the overlayfs once, filtering out the macOS
# build artefacts up front. cp/tar are pre-installed; rsync is not, and
# `apt-get install rsync` here would fail (no apt-get update yet).
tar -C /workspace -cf - \
    --exclude=".build" \
    --exclude=".build-aro" \
    --exclude="target" \
    --exclude="*.dylib" \
    . | tar -C /aro -xf -
cd /aro

echo "=== Installing base dependencies ==="
apt-get update -qq
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq \
    perl \
    curl \
    wget \
    file \
    lsb-release \
    software-properties-common \
    gnupg \
    pkg-config \
    libipc-run-perl \
    libjson-perl \
    libyaml-libyaml-perl \
    libhttp-tiny-perl \
    zlib1g-dev \
    libsqlite3-dev \
    libgit2-dev \
    cpanminus \
    build-essential \
    rsync \
    > /dev/null 2>&1

echo "=== Installing LLVM 20 from official apt repository ==="
# Use apt repository method (more reliable than llvm.sh script)
wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-20 main" > /etc/apt/sources.list.d/llvm.list
apt-get update -qq
apt-get install -y -qq llvm-20-dev libzstd-dev > /dev/null 2>&1

# Create symlinks for binaries
ln -sf /usr/bin/llc-20 /usr/bin/llc

# Create the llvm.pc file that Swifty-LLVM expects
mkdir -p /usr/lib/pkgconfig
cat > /usr/lib/pkgconfig/llvm.pc << EOF
prefix=/usr/lib/llvm-20
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: LLVM
Description: Low-level Virtual Machine compiler framework
Version: 20.1
Cflags: -I\${includedir}
Libs: -L\${libdir} -lLLVM-20
EOF

# Install additional Perl modules
cpanm -q --notest Net::EmptyPort Term::ANSIColor 2>/dev/null || true

echo "=== Installing Rust for plugin compilation ==="
curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1
. $HOME/.cargo/env
rustc --version

echo "=== Verifying LLVM 20 installation ==="
pkg-config --modversion llvm
echo "llc: $(llc --version 2>&1 | head -1)"

# Clean any existing macOS build artifacts
echo ""
echo "=== Cleaning build directory ==="
rm -rf .build

# Clean Rust build artifacts from plugin directories (macOS dylibs will not work on Linux).
# Use -ipath so we also catch the lowercase legacy `plugins/` directories
# (ExternalService, SQLiteExample, ZipService).
echo "=== Cleaning Rust plugin artifacts ==="
find Examples -type d -name target -ipath "*/plugins/*" -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true

# Clean macOS-built plugin libraries and SPM build caches (wrong arch for Linux)
echo "=== Cleaning plugin build artifacts ==="
find Examples -ipath "*/plugins/*" \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null | xargs -0 rm -f 2>/dev/null || true
find Examples -ipath "*/plugins/*" -type d \( -name ".build" -o -name ".build-aro" \) -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true

# Clean macOS compiled binaries from Examples directories (Mach-O will not run on Linux)
echo "=== Cleaning macOS example binaries ==="
find Examples -maxdepth 2 -type f -executable ! -name "*.sh" ! -name "*.pl" ! -name "*.py" ! -name "*.aro" -print0 2>/dev/null | xargs -0 rm -f 2>/dev/null || true

# Fix git ownership issues in Docker (mounted volume has different owner)
# Use || true since git may fail in git worktree environments where the parent repo path
# is not accessible inside the container
git config --global --add safe.directory /aro || true
git config --global --add safe.directory "*" || true

echo ""
echo "=== Building ARO (release) ==="
swift build -c release 2>&1 | tail -15

echo ""
echo "=== Verifying ARO binary ==="
file .build/release/aro
.build/release/aro --version || .build/release/aro --help | head -3

echo ""
echo "=== Running integration tests ==="
. $HOME/.cargo/env

# Copy test artifacts (logs, diffs) back to the bind-mount on exit so the
# host can inspect them after the container stops.
sync_results() {
    rsync -a --include="*/" \
        --include="testrun.log" --include="expected.diff" --include="expected.binary.diff" \
        --exclude="*" \
        /aro/Examples/ /workspace/Examples/ 2>/dev/null || true
}
trap sync_results EXIT

./Tests/IntegrationTestsRunner/run-tests.pl 2>&1
'
