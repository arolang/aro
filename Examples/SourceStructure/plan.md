# Build a sources/ subdirectory structure demo

Create an ARO application that demonstrates organizing .aro files in a `sources/` subdirectory with nested folders. The runtime automatically discovers all .aro files in subdirectories.

The application needs three files:

- `main.aro` -- `Application-Start` that emits `<CreateUser: event>` and `<CreateOrder: event>` with sample data. No imports needed since all feature sets are globally visible.

- `sources/users/users.aro` -- `Handle User Creation: CreateUser Handler` that extracts name and email from the event, creates a user object, and logs it.

- `sources/orders/orders.aro` -- `Handle Order Creation: CreateOrder Handler` that extracts userId and total from the event, creates an order object with "pending" status, and logs it.
