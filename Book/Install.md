<!--
  The canonical installation snippet, shared by every book under Book/.

  Do not copy this text into a chapter. A chapter asks for it with an HTML
  comment reading "ARO:INCLUDE Install.md", a one-line fallback for anyone
  reading the raw markdown, and a closing "/ARO:INCLUDE" comment. Book's
  build scripts replace everything between the two comments with this file
  (see book-release.sh, aro_book_stamp). Any chapter here already carrying
  the pair is the example to copy.

  Reader-facing URLs point at https://github.com/arolang/aro. The GitLab
  remote is where the work is pushed; it is not reachable by the people
  these books are written for.

  The Homebrew tap is `arolang/aro`, backed by github.com/arolang/homebrew-aro,
  which the release workflow updates on every tag. `brew install arolang/tap/aro`
  looks for a tap named `arolang/homebrew-tap`, which does not exist.
-->

**macOS (Homebrew)** — the shortest path:

```bash
brew tap arolang/aro
brew install aro
```

**Linux** — pick the artifact that matches your distribution from the
[Releases page](https://github.com/arolang/aro/releases) and put `aro` on your
`PATH`. The release carries signed `.deb` and `.rpm` packages as well as a
portable tarball. `libARORuntime.a` belongs next to it (`/usr/local/lib` is the
usual choice) — `aro build` links against it.

**Windows** — download and extract the zip from the same Releases page, then add
the directory to your `PATH`. Keep `aro.exe` and `libARORuntime.a` together.

**From source** — Swift 6.3 or later, and LLVM 20 if you want `aro build`:

```bash
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
./.build/release/aro --version
```

Whichever route you took, `aro --version` should answer, and `aro --help`
should list the subcommands. This edition documents ARO @ARO_VERSION@.
