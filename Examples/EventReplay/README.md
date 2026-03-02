# EventReplay - Event Recording and Replay

This example demonstrates ARO's event recording and replay functionality (GitLab #124).

## Usage

### Recording Events

Record all events during application execution to a JSON file:

```bash
aro run ./Examples/EventReplay --record events.json
```

This captures:
- Domain events (UserCreated, OrderPlaced, PaymentProcessed, etc.)
- System events (application.started, featureset.started, etc.)
- Error events
- Timestamps for each event

### Replaying Events

Replay previously recorded events:

```bash
aro run ./Examples/EventReplay --replay events.json
```

Events are replayed without timing delays (fast replay) before the application starts.

### Verbose Mode

See detailed information about recording/replay:

```bash
aro run ./Examples/EventReplay --record events.json --verbose
aro run ./Examples/EventReplay --replay events.json --verbose
```

## Event Recording Format

Events are saved as JSON:

```json
{
  "version": "1.0",
  "application": "ARO Application",
  "recorded": "2026-02-24T07:25:26Z",
  "events": [
    {
      "timestamp": "2026-02-24T07:25:26Z",
      "eventType": "domain",
      "payload": "{\"domainEventType\":\"UserCreated\",\"data\":{\"userId\":\"123\",\"name\":\"Alice\"}}"
    }
  ]
}
```

## Use Cases

- **Debugging**: Capture events during a bug occurrence and replay for investigation
- **Testing**: Record expected event sequences for validation
- **Auditing**: Maintain event logs for compliance
- **Development**: Replay production events in development environment
