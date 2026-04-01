# ARO By Example - Structure

Building a Real-World Web Crawler with ARO

## Overview

This book teaches ARO by building a complete, production-ready web crawler from scratch. Each chapter introduces new concepts while progressively constructing the application.

**Target Audience:** Developers who know programming but are new to ARO.

**What You'll Build:** A concurrent web crawler that:
- Fetches web pages and converts them to Markdown
- Extracts and normalizes links
- Filters URLs by domain
- Deduplicates using set operations
- Processes links in parallel
- Saves results to files
- Deploys via Docker

## Table of Contents

### Part I: Foundations

1. **Introduction** — What ARO is, the beta disclaimer, and project overview
2. **Project Setup** — Installing ARO and creating the project structure

### Part II: The Entry Point

3. **The Entry Point** — `Application-Start`, environment variables, and initialization
4. **Event-Driven Architecture** — Events, handlers, and the EventBus

### Part III: Core Crawling

5. **Fetching Pages** — HTTP requests and HTML parsing
6. **Link Extraction** — Using `ParseHtml` to extract links
7. **URL Normalization** — Pattern matching and string interpolation
8. **URL Filtering** — Conditional logic with `when` guards

### Part IV: Data Management

9. **Storing Results** — File operations and hashing
10. **Parallel Processing** — Concurrent execution with `parallel for`
11. **Set Operations** — Deduplication with `union` and `difference`

### Part V: Completion

12. **Putting It Together** — Complete application flow and debugging
13. **Docker Deployment** — Native compilation and containerization
14. **What's Next** — Extensions and resources

### Appendices

A. **Complete Code** — All source files with comments
B. **Action Quick Reference** — Table of actions used in the book

## Files

```
AROByExample/
├── metadata.yaml
├── STRUCTURE.md (this file)
├── build-pdf.sh
├── unix-style.css
├── Cover.md
├── Chapter01-Introduction.md
├── Chapter02-ProjectSetup.md
├── Chapter03-TheEntryPoint.md
├── Chapter04-EventDrivenArchitecture.md
├── Chapter05-FetchingPages.md
├── Chapter06-LinkExtraction.md
├── Chapter07-URLNormalization.md
├── Chapter08-URLFiltering.md
├── Chapter09-StoringResults.md
├── Chapter10-ParallelProcessing.md
├── Chapter11-SetOperations.md
├── Chapter12-PuttingItTogether.md
├── Chapter13-DockerDeployment.md
├── Chapter14-WhatsNext.md
├── AppendixA-CompleteCode.md
├── AppendixB-ActionQuickReference.md
└── output/
    ├── ARO-By-Example.pdf
    └── ARO-By-Example.html
```

## Building

```bash
cd Book/AROByExample
./build-pdf.sh
```

Output will be in `output/`.
