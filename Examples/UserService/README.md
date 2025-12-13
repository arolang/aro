# UserService

A complete multi-file CRUD API with event-driven side effects and file monitoring.

## What It Does

Implements a full user management API (list, create, get, update, delete) with domain events that trigger side effects: welcome emails on creation, audit logs on update, and data cleanup on deletion. Also watches an uploads directory for file events.

## Features Tested

- **Multi-file application** - Separate files for main, API handlers, and events
- **Contract-first API** - Full CRUD routes from `openapi.yaml`
- **Domain events** - `<Emit>` and `Handler` pattern for side effects
- **Event handlers** - `UserCreated Handler`, `UserUpdated Handler`, etc.
- **File event handlers** - `FileCreated Handler`, `FileDeleted Handler`
- **Repository operations** - `<Retrieve>`, `<Store>`, `<Delete>`, `<Merge>` patterns
- **Application lifecycle** - Start, success shutdown, and failure handlers
- **HTTP + File monitoring** - Multiple services in one application

## Related Proposals

- [ARO-0027: Contract-First APIs](../../Proposals/ARO-0027-contract-first-api.md)
- [ARO-0019: Event System](../../Proposals/ARO-0019-event-system.md)
- [ARO-0023: File System Operations](../../Proposals/ARO-0023-file-system.md)
- [ARO-0022: HTTP Server](../../Proposals/ARO-0022-http-server.md)

## Usage

```bash
# Start the service
aro run ./Examples/UserService

# Create a user (triggers welcome email event)
curl -X POST http://localhost:8080/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "email": "alice@example.com"}'

# List users
curl http://localhost:8080/users

# Update a user (triggers audit log event)
curl -X PUT http://localhost:8080/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Smith"}'
```

## Project Structure

```
UserService/
├── main.aro        # Application-Start, Application-End handlers
├── users.aro       # HTTP API handlers (CRUD operations)
├── events.aro      # Event handlers (emails, audit, cleanup)
└── openapi.yaml    # Complete API contract with schemas
```

## Event Flow

```
HTTP Request → API Handler → Emit Event → Event Handler
                  ↓                            ↓
            Return Response            Side Effect (email, log, etc.)
```

---

*A complete service in four files. HTTP routes, domain events, file watching, and lifecycle management - all expressed in the same declarative style. This is what ARO was built for.*
