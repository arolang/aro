# UserService

A complete multi-file CRUD API with bidirectional file synchronization.

## What It Does

Implements a full user management API (list, create, get, update, delete) with bidirectional sync between the HTTP API and the file system. User data is automatically written to JSON files when created or updated via the API, and external file modifications are synced back to the in-memory repository.

## Features Tested

- **Multi-file application** - Separate files for main, API handlers, and events
- **Contract-first API** - Full CRUD routes from `openapi.yaml`
- **Domain events** - `<Emit>` and `Handler` pattern for side effects
- **Event handlers** - `UserCreated Handler`, `UserUpdated Handler`
- **File event handlers** - `File Event Handler` for file modifications and deletions
- **Bidirectional sync** - API changes write to files, file changes sync to repository
- **Repository operations** - `<Retrieve>`, `<Store>`, `<Delete>` patterns
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

# Create a user (writes to ./data/users/Alice.json)
curl -X POST http://localhost:8080/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice"}'

# List users
curl http://localhost:8080/users

# Modify the file externally (syncs back to repository)
echo '{"name": "Alice", "status": "updated"}' > ./data/users/Alice.json

# List users again - shows updated data
curl http://localhost:8080/users
```

## Project Structure

```
UserService/
├── main.aro        # Application-Start, Application-End handlers
├── users.aro       # HTTP API handlers (CRUD operations)
├── events.aro      # Event handlers (file sync, audit logging)
└── openapi.yaml    # Complete API contract with schemas
```

## Event Flow

```
HTTP Request → API Handler → Emit Event → Event Handler → Write File
                  ↓
            Return Response

File Modified → File Event Handler → Update Repository
```

---

*A complete service in four files. HTTP routes, domain events, file watching, and lifecycle management - all expressed in the same declarative style. This is what ARO was built for.*
