# Chapter 14: What's Next

*"Every ending is a new beginning."*

---

## What We Will Learn

- How to extend the crawler
- Other ARO application patterns
- Resources for continued learning
- How to contribute to ARO

---

## 14.1 You Built a Web Crawler

Congratulations! Over 13 chapters, you built a complete, production-ready web crawler from scratch. You learned:

- The Action-Result-Object pattern
- Event-driven architecture
- HTTP requests and HTML parsing
- Pattern matching and guards
- Parallel processing
- Set operations and deduplication
- File I/O
- Docker deployment

More importantly, you learned to think in ARO: events, handlers, data flow, and natural language syntax.

---

## 14.2 Extending the Crawler

Here are ideas for extending what you built:

**Depth Limiting**

Track how many links deep you have traveled from the starting URL. Stop crawling after a certain depth to limit the scope.

```aro
Emit a <CrawlPage: event> with { url: <url>, base: <base>, depth: <current-depth> }.
```

**Rate Limiting**

Add delays between requests to avoid overwhelming servers. ARO has a `<Wait>` action:

```aro
Wait for 1000.  (* milliseconds *)
```

**Content Filtering**

Skip pages based on URL patterns, content type, or page size:

```aro
Request the <html> from the <url> when <url> contains "/docs/".
```

**Robots.txt Compliance**

Fetch and parse robots.txt before crawling. Respect disallow rules.

**Database Storage**

Instead of files, store crawled content in a database. ARO can connect to external services.

**Sitemap Generation**

After crawling, generate a sitemap.xml from the discovered URLs.

---

## 14.3 Other Application Patterns

The web crawler demonstrates one ARO pattern. Here are others:

**HTTP API Server**

ARO can serve HTTP APIs using OpenAPI contracts:

```aro
(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}
```

Feature sets are named after OpenAPI `operationId` values. The server handles routing automatically.

**Real-Time WebSocket Application**

Build applications with live updates using WebSocket. Messages posted via HTTP are broadcast to all connected clients:

```aro
(Application-Start: StatusPost) {
    Start the <http-server> with { websocket: "/ws" }.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(postMessage: StatusPost API) {
    Extract the <body> from the <request: body>.
    Extract the <message-text: message> from the <body>.
    Create the <message: Message> with {
        message: <message-text>,
        createdAt: <now>
    }.
    Store the <message> into the <message-repository>.
    Broadcast the <message> to the <websocket>.
    Return a <Created: status> with <message>.
}

(Handle WebSocket Connect: WebSocket Event Handler) {
    Log "Client connected" to the <console>.
    Return an <OK: status> for the <connection>.
}
```

**File Processor**

Watch a directory for new files and process them:

```aro
(Application-Start: File Processor) {
    Start the <file-monitor> with "./inbox".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(Process File: File Event Handler) {
    Extract the <path> from the <event: path>.
    (* Process the file *)
}
```

**Metrics and Monitoring**

Expose Prometheus metrics for monitoring your application. ARO automatically tracks execution counts and timing for all feature sets:

```aro
(getMetrics: Monitoring API) {
    Return an <OK: status> with <metrics: prometheus>.
}
```

With the OpenAPI contract specifying `text/plain`:

```yaml
/metrics:
  get:
    operationId: getMetrics
    responses:
      '200':
        content:
          text/plain:
            schema:
              type: string
```

This outputs standard Prometheus format that can be scraped by monitoring systems.

**Event-Sourced System**

Use ARO's events as the foundation for event sourcing. Emit events for all state changes, replay them to rebuild state.

**Integration Pipeline**

Connect external services through events. Fetch data from one API, transform it, send to another.

---

## 14.4 Learning Resources

**Official Documentation**

- [ARO Language Guide](https://github.com/arolang/aro/wiki) — Comprehensive language reference
- [ARO Proposals](https://github.com/arolang/aro/tree/main/Proposals) — Language design specifications

**Example Applications**

- [Example Web Crawler](https://github.com/arolang/example-web-crawler) — The code from this book
- [Examples Directory](https://github.com/arolang/aro/tree/main/Examples) — Additional examples in the main repository

**Community**

- [GitHub Issues](https://github.com/arolang/aro/issues) — Report bugs, request features
- [Discussions](https://github.com/arolang/aro/discussions) — Ask questions, share ideas

---

## 14.5 Contributing to ARO

ARO is open source and welcomes contributions:

**Report Bugs**

Found something broken? Open an issue with:
- What you expected
- What happened instead
- Steps to reproduce
- ARO version and platform

**Suggest Features**

Have an idea? Open a discussion or issue. Describe:
- The use case
- How it would work
- Why it fits ARO's philosophy

**Contribute Code**

The codebase is Swift. Areas that need work:
- Error messages
- Documentation
- Built-in actions
- Performance optimization

**Write Examples**

Help others learn by writing examples. Real-world use cases are especially valuable.

---

## 14.6 The Road Ahead

ARO is young. The language will evolve. Some things that may change:

- Better error messages and debugging
- Package management for code sharing
- More built-in actions
- IDE integration with LSP
- Persistent storage options

By learning ARO now, you are part of shaping its future. Your feedback matters.

---

## 14.7 Final Thoughts

ARO takes a different approach to programming. It treats code as natural language, events as the primary communication mechanism, and the happy path as the only path you write.

This approach is not for every problem. But for business logic—the "what should happen when" of applications—it offers clarity that traditional code often lacks.

Thank you for taking this journey. We hope ARO serves you well.

---

## Chapter Recap

- You built a complete web crawler in 211 lines of ARO
- Extensions like rate limiting and depth limiting are straightforward
- ARO supports many patterns: APIs, file processing, event sourcing
- Documentation and examples are available on GitHub
- Contributions are welcome; the language is actively evolving

---

## The Complete Journey

| Chapter | What You Learned |
|---------|------------------|
| 1 | ARO philosophy and project overview |
| 2 | Project structure and setup |
| 3 | Application-Start and initialization |
| 4 | Event-driven architecture |
| 5 | HTTP requests and HTML parsing |
| 6 | Link extraction with ParseHtml |
| 7 | URL normalization with pattern matching |
| 8 | URL filtering with when guards |
| 9 | File storage with hashing |
| 10 | Parallel processing |
| 11 | Set operations for deduplication |
| 12 | Complete application flow |
| 13 | Docker deployment |
| 14 | Next steps and resources |

---

*Happy crawling!*
