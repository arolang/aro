# =============================================================================
# ARO CI Image
# =============================================================================
# The toolchain every CI job installs for itself, installed once.
#
# `test`, `build:linux`, `integration:linux`, `integration:jupyter` and
# `repl:smoke` each began by adding the LLVM apt repository and installing
# roughly the same packages — about six minutes per job, five times per
# pipeline (GitLab #596).
#
# It is also a reliability cost, not only a speed one. `apt.llvm.org` is a
# third-party host contacted at the start of every job, and a job in this
# project has already failed on `Could not connect to apt.llvm.org`. Every
# network call in `before_script` is another way for a correct branch to go
# red for reasons unrelated to the change.
#
# Built and published by the `docker:ci` job. Jobs move onto it in a separate
# change, once it exists in the registry — see the merge request for why the
# two halves cannot land together.
# =============================================================================

FROM swift:6.3-jammy

LABEL org.opencontainers.image.title="ARO CI"
LABEL org.opencontainers.image.description="Toolchain for the ARO CI jobs: Swift 6.3, LLVM 20, and the system libraries the test and integration jobs link against"
LABEL org.opencontainers.image.source="https://github.com/arolang/aro"
LABEL org.opencontainers.image.vendor="ARO Language"

ENV DEBIAN_FRONTEND=noninteractive

# Speak HTTP/1.1 to git remotes, for the same reason `.gitlab-ci.yml` does:
# an HTTP/2 fetch against github.com is cut short often enough to break a
# build, and git reports it as a missing credential. A RUN step has its own
# environment and inherits none of the job's variables.
ENV GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.version \
    GIT_CONFIG_VALUE_0=HTTP/1.1

# Base packages: the union of what the jobs install for themselves.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        git ca-certificates wget curl gnupg software-properties-common \
        libgit2-dev libzmq3-dev libcurl4 libzstd-dev \
        zlib1g-dev libsqlite3-dev libxml2 \
        python3 python3-pip \
        perl cpanminus libipc-run-perl libyaml-libyaml-perl libhttp-tiny-perl \
        gdb \
    && rm -rf /var/lib/apt/lists/*

# LLVM 20 from apt.llvm.org — the reason the jobs each contacted a third-party
# host. Done once, here.
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-20 main" \
      > /etc/apt/sources.list.d/llvm.list \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        llvm-20-dev libllvm20 llvm-20 clang-20 \
    && rm -rf /var/lib/apt/lists/*

# `aro build` shells out to `llc` and `clang` by name, and the integration
# job symlinks them itself today.
RUN ln -sf /usr/bin/llc-20 /usr/bin/llc \
    && ln -sf /usr/bin/clang-20 /usr/bin/clang \
    && ln -sf /usr/bin/llvm-objcopy-20 /usr/bin/llvm-objcopy

# The pkg-config file `test` writes by hand before building.
RUN mkdir -p /usr/lib/pkgconfig && printf '%s\n' \
    'prefix=/usr/lib/llvm-20' \
    'exec_prefix=${prefix}' \
    'libdir=${exec_prefix}/lib' \
    'includedir=${prefix}/include' \
    '' \
    'Name: LLVM' \
    'Description: Low-level Virtual Machine compiler framework' \
    'Version: 20.0.0' \
    'Cflags: -I${includedir}' \
    'Libs: -L${libdir} -lLLVM-20' \
    > /usr/lib/pkgconfig/llvm.pc

ENV PATH="/usr/lib/llvm-20/bin:${PATH}" \
    LD_LIBRARY_PATH="/usr/lib/llvm-20/lib:${LD_LIBRARY_PATH}"

# Fail the image build rather than a job three stages later.
RUN swift --version && llc --version | head -1 && clang --version | head -1 \
    && perl -e 'print "perl ok\n"' && python3 --version
