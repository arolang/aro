# Build a full-featured user service with CRUD API, events, and file sync

Create a multi-file ARO application that implements a complete user REST API with event-driven side effects including file synchronization.

The application needs four files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with full CRUD operations for users: `GET /users` (listUsers), `POST /users` (createUser), `GET /users/{id}` (getUser), `PUT /users/{id}` (updateUser), `DELETE /users/{id}` (deleteUser). Define User, CreateUserRequest, UpdateUserRequest, and Error schemas.

- `main.aro` -- Three feature sets:
  - `Application-Start: User Service` -- Start the HTTP server, log readiness, use Keepalive, return OK.
  - `Application-End: Success` -- Stop the HTTP server, close database connections, log goodbye.
  - `Application-End: Error` -- Extract the error, log the crash, close database connections.

- `users.aro` -- Five HTTP handler feature sets matching the operationIds:
  - `listUsers` -- Retrieve all users from `<user-repository>` and return them.
  - `getUser` -- Extract id from path parameters, retrieve by id, return the user.
  - `createUser` -- Extract request body, create user, store into repository, emit `<UserCreated: event>`, return Created status.
  - `updateUser` -- Extract id and update data, retrieve existing user, merge with updates, store, emit `<UserUpdated: event>`, return OK.
  - `deleteUser` -- Extract id, delete from repository, emit `<UserDeleted: event>`, return NoContent status.

- `events.aro` -- Five event handler feature sets for bidirectional user-file sync:
  - `Write New User File: UserCreated Handler` -- Extract user from event, compute a file path from the user name, write user data as JSON file.
  - `Log User Update: UserUpdated Handler` -- Log that a user was updated.
  - `Write User File: UserUpdated Handler` -- Write updated user data to a JSON file.
  - `Handle File Modified: File Event Handler` -- Read modified file content, parse it, store into the user repository (syncing file changes back to the repo).
  - `Handle File Deleted: File Event Handler` -- Extract filename from path, delete user from repository.
