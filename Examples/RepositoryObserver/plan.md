# Build a user CRUD API with repository observers

Create an ARO application with four files that demonstrates repository observers reacting to data changes.

- `openapi.yaml` -- Define an API on `http://localhost:8082` with CRUD endpoints for users: `GET /users` (listUsers), `POST /users` (createUser), `GET /users/{id}` (getUser), `PUT /users/{id}` (updateUser), `DELETE /users/{id}` (deleteUser). Define a User schema with id, name, and email fields.

- `main.aro` -- The `Application-Start` feature set that logs a startup message, starts the HTTP server with the contract, uses Keepalive, and returns OK.

- `api.aro` -- Five feature sets matching the operationIds for full CRUD operations on a user repository. `createUser` extracts request body, creates a user, stores it in `<user-repository>`, and returns Created status. `listUsers` retrieves all users from the repository. `getUser` extracts the id from path parameters and retrieves by id. `updateUser` retrieves the user, updates with request body, and stores back. `deleteUser` deletes from the repository by id.

- `observers.aro` -- Three repository observer feature sets, all with business activity `user-repository Observer`:
  - `Audit Changes` -- Extracts changeType, entityId, and repositoryName from the event. Computes and logs an audit message.
  - `Track Updates` -- Extracts changeType and entityId, logs a change tracking message.
  - `Monitor Deletions` -- Extracts changeType and entityId, logs a monitoring message.

All three observers fire automatically whenever the user-repository is modified (store, update, delete).
