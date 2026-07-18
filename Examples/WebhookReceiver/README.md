# Webhook Receiver

Demonstrates **incoming webhooks** declared via OpenAPI 3.1's top-level
`webhooks` object (ARO-0187).

## How it works

`openapi.yaml` declares two webhooks under `webhooks:`:

| Webhook           | Routed as             | Handler feature set |
|-------------------|-----------------------|---------------------|
| `newOrder`        | `POST /newOrder`      | `newOrder`          |
| `paymentReceived` | `POST /paymentReceived` | `handlePayment` (via `operationId`) |

**Webhook naming convention:** the webhook map key becomes both the request
path and the feature-set name. If the webhook operation declares an
`operationId`, that name is used instead — letting you decouple the handler
name from the webhook name (as `paymentReceived` → `handlePayment` shows).

This mirrors the `operationId` convention already used for `paths`, and reuses
the same route → feature-set dispatch machinery.

## Run

```bash
aro run ./Examples/WebhookReceiver
```

Then, from another shell:

```bash
curl -X POST localhost:8080/newOrder -d '{"id":1}'
curl -X POST localhost:8080/paymentReceived -d '{"amount":9.99}'
curl localhost:8080/health
```

## Note on outgoing callbacks

OpenAPI `Operation.callbacks` (outgoing webhooks) are **parsed** by ARO but
are not automatically fired. Prefer ARO's event-driven model: emit an event and
have a handler make the outbound call with the HTTP client. See
`Proposals/ARO-0008-io-services.md` §2.8.
