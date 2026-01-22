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
    cpanminus \
    > /dev/null 2>&1

echo "=== Installing LLVM 20 from official apt repository ==="
wget -q https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
./llvm.sh 20 > /dev/null 2>&1
apt-get install -y -qq llvm-20-dev > /dev/null 2>&1

# Setup LLVM environment for Swift Package Manager
export PATH="/usr/lib/llvm-20/bin:$PATH"

# Create symlinks for binaries
ln -sf /usr/bin/llc-20 /usr/bin/llc
ln -sf /usr/bin/clang-20 /usr/bin/clang
ln -sf /usr/lib/llvm-20/bin/llvm-config /usr/bin/llvm-config

# Create the llvm.pc file that Swifty-LLVM expects
# This is generated from llvm-config output
LLVM_VERSION=$(/usr/lib/llvm-20/bin/llvm-config --version)
LLVM_INCLUDEDIR=$(/usr/lib/llvm-20/bin/llvm-config --includedir)
LLVM_LIBDIR=$(/usr/lib/llvm-20/bin/llvm-config --libdir)
LLVM_CFLAGS=$(/usr/lib/llvm-20/bin/llvm-config --cflags)
LLVM_LDFLAGS=$(/usr/lib/llvm-20/bin/llvm-config --ldflags)
LLVM_LIBS=$(/usr/lib/llvm-20/bin/llvm-config --libs)

mkdir -p /usr/lib/pkgconfig
cat > /usr/lib/pkgconfig/llvm.pc << EOF
prefix=/usr/lib/llvm-20
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: LLVM
Description: Low-level Virtual Machine compiler framework
Version: ${LLVM_VERSION}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lLLVM-20
EOF

# Set PKG_CONFIG_PATH to find our llvm.pc
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:$PKG_CONFIG_PATH"

# Install additional Perl modules
cpanm -q --notest Net::EmptyPort Term::ANSIColor 2>/dev/null || true

echo "=== Verifying LLVM 20 installation ==="
/usr/lib/llvm-20/bin/llvm-config --version
pkg-config --modversion llvm
pkg-config --cflags llvm

# Clean any existing macOS build artifacts
echo ""
echo "=== Cleaning build directory ==="
rm -rf .build

echo ""
echo "=== Building ARO (release) ==="
swift build -c release 2>&1 | tail -15

echo ""
echo "=== Verifying ARO binary ==="
file .build/release/aro
.build/release/aro --version || .build/release/aro --help | head -3

echo ""
echo "=== Running test-examples.pl ==="
./test-examples.pl 2>&1
'
