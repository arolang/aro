# Chapter 13: Docker Deployment

*"If it runs in Docker, it runs anywhere."*

---

## What We Will Learn

- Compiling ARO to a native binary
- Creating a Dockerfile for the crawler
- Using Docker Compose for easy deployment
- CI/CD considerations

---

## 13.1 From Interpreted to Native

So far, we have run our crawler with `aro run .`, which interprets the ARO code. For deployment, we can compile to a native binary with `aro build`:

```bash
aro build . -o crawler
```

This produces a standalone executable that behaves exactly like `aro run .` — including reading `CRAWL_URL` from the environment, and including doing nothing quietly when it is not set:

```bash
CRAWL_URL="https://example.com" ./crawler
```

For optimized builds:

```bash
aro build . --release -o crawler
```

`--release` is shorthand for `--optimize --size --strip`: optimized, tuned for size rather than speed, and with debug symbols removed. Each of the three is available on its own if you want a different mix — `--optimize` alone keeps symbols, which is what you want if you intend to attach `lldb` to the binary later.

By default the Swift runtime is linked statically, so the output is a single self-contained file. `--dynamic` links it dynamically instead and copies the required libraries next to the binary with `rpath=$ORIGIN` — useful when several ARO binaries ship in the same image and you would rather not pay for the runtime in each of them.

---

## 13.2 The Architectural Decision

**Our Choice:** Multi-stage Docker build with native compilation.

**Alternative Considered:** We could ship the ARO runtime and interpret `.aro` files at container startup. This makes the image larger but allows changing code without rebuilding. For a crawler that runs as a job, native compilation is better: smaller image, faster startup, no runtime dependency.

**Why This Approach:** Docker images should be minimal and self-contained. A native binary is exactly that—no interpreter, no source files, just an executable. The multi-stage build keeps the final image small by excluding build tools.

---

## 13.3 The Dockerfile

Create a `Dockerfile`:

```dockerfile
# Stage 1: Build
FROM ghcr.io/arolang/aro-buildsystem:latest AS builder

WORKDIR /app
COPY *.aro openapi.yaml ./

# Compile to native binary
RUN aro build . --release -o crawler

# Stage 2: Runtime
FROM ghcr.io/arolang/aro-runtime:latest

WORKDIR /app
COPY --from=builder /app/crawler ./

# Create output directory
RUN mkdir -p /output

# Set the entrypoint
ENTRYPOINT ["./crawler"]
```

This Dockerfile:

1. Uses the ARO build system image to compile
2. Copies the sources **and** `openapi.yaml` — the contract is a build input, not an afterthought
3. Copies only the binary to a minimal runtime image
4. Creates the output directory
5. Sets the binary as the entrypoint

---

## 13.4 Building the Image

Build the Docker image:

```bash
docker build -t web-crawler .
```

Run it:

```bash
docker run -e CRAWL_URL="https://example.com" web-crawler
```

The output goes to `/output` inside the container. To access it, mount a volume:

```bash
docker run \
    -e CRAWL_URL="https://example.com" \
    -v $(pwd)/output:/output \
    web-crawler
```

Now crawled files appear in your local `output/` directory.

---

## 13.5 Docker Compose

For easier management, create `docker-compose.yml`:

```yaml
services:
  crawler:
    build: .
    environment:
      - CRAWL_URL=https://example.com
    volumes:
      - ./output:/output
```

Run with:

```bash
docker compose up
```

Change the URL by setting the environment variable:

```bash
CRAWL_URL="https://other-site.com" docker compose up
```

Or edit the compose file directly.

---

## 13.6 CI/CD Pipeline

For automated builds, here is a GitHub Actions workflow (`.github/workflows/build.yml`):

```yaml
name: Build

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -t web-crawler .

      - name: Test crawler
        run: |
          timeout 60 docker run \
            -e CRAWL_URL="https://example.com" \
            web-crawler || true

      - name: Push to registry
        if: github.ref == 'refs/heads/main'
        run: |
          docker tag web-crawler ghcr.io/${{ github.repository }}:latest
          echo ${{ secrets.GITHUB_TOKEN }} | docker login ghcr.io -u ${{ github.actor }} --password-stdin
          docker push ghcr.io/${{ github.repository }}:latest
```

This workflow:

1. Builds the Docker image on every push
2. Runs a quick test (with timeout to prevent infinite crawls)
3. Pushes to GitHub Container Registry on main branch

---

## 13.7 Image Size Considerations

Let us compare image sizes:

| Approach | Size |
|----------|------|
| With full ARO runtime + source | ~200MB |
| With minimal runtime + native binary | ~50MB |
| Static binary (no runtime) | ~20MB |

The native binary approach is a good balance between size and simplicity.

---

## 13.8 What ARO Does Well Here

**Native Compilation.** `aro build` produces standalone binaries. No runtime dependencies to manage in production.

**Standard Docker Workflow.** ARO fits into existing containerization practices. No special tooling required.

**Small Binaries.** Compiled ARO produces reasonably sized executables.

---

## 13.9 What Could Be Better

**No Cross-Compilation.** You cannot build a Linux binary on macOS directly. You need Docker or a Linux machine for Linux targets — which is the main reason the multi-stage Dockerfile above exists.

**The Build Inputs Are Not Just `.aro`.** `aro build` needs the whole application directory — `openapi.yaml` and any `.store` files as much as the source. It is easy to write a `COPY *.aro ./` that builds cleanly and then fails at runtime because the contract was left behind on the host. Copy the directory, not a glob.

---

## Chapter Recap

- `aro build . -o binary` compiles to native executable
- Multi-stage Docker builds keep images small
- Mount volumes to access crawler output
- Docker Compose simplifies configuration
- CI/CD pipelines can automate builds and tests

---

*Next: Chapter 14 - What's Next*
