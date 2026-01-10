# Repository Observer Example

This example demonstrates repository observers - feature sets that automatically react to repository changes with access to old and new values.

## Overview

Repository observers enable reactive patterns where feature sets subscribe to repository changes:

- **Audit logging**: Track all changes with full before/after context
- **Change tracking**: Compare old and new values on updates
- **Event-driven architecture**: Decouple reactions from mutations

## Files

- `main.aro` - Application entry point
- `api.aro` - CRUD operations (create, read, update, delete users)
- `observers.aro` - Three observers that react to repository changes
- `openapi.yaml` - API contract defining HTTP endpoints

## Observer Syntax

Observers use the pattern `{repository-name} Observer` as their business activity:

```aro
(Audit Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <oldValue> from the <event: oldValue>.
    <Extract> the <newValue> from the <event: newValue>.

    <Log> <changeType> to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

## Event Payload

Observers receive an event with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `repositoryName` | String | e.g., "user-repository" |
| `changeType` | String | "created", "updated", or "deleted" |
| `entityId` | String? | ID of changed entity |
| `newValue` | Any? | New value (nil for deletes) |
| `oldValue` | Any? | Previous value (nil for creates) |
| `timestamp` | Date | When change occurred |

## Running

```bash
# Build ARO
swift build

# Run the example
.build/debug/aro run ./Examples/RepositoryObserver
```

## Testing

```bash
# Create a user (triggers "created" event)
curl -X POST http://localhost:8080/users \
  -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice@example.com"}'

# Update the user (triggers "updated" event - observers see old and new values)
curl -X PUT http://localhost:8080/users/{id} \
  -H 'Content-Type: application/json' \
  -d '{"name":"Alice Smith","email":"alice@example.com"}'

# Delete the user (triggers "deleted" event)
curl -X DELETE http://localhost:8080/users/{id}
```

Watch the console for observer output showing the change type and entity details.

## Use Cases

- **Audit trails**: Log every change with who/what/when/before/after
- **Caching invalidation**: Clear caches when data changes
- **Synchronization**: Keep secondary systems in sync
- **Analytics**: Track data changes over time
- **Notifications**: Alert users when their data changes
