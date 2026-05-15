# Build a user notification demo with age-based filtering

Create a single-file ARO application that demonstrates the `Notify` action and event handler guards.

In `main.aro`:

1. `Application-Start: Notification Demo` -- Create a single user object (Alice, age 30) and notify her with "Welcome to ARO!" using `Notify the <alice> with "Welcome to ARO!"`. Then create a list of users with varying ages (14, 25, 15, 20) and notify the entire group with `Notify the <group> with "Hello everyone!"`. The runtime distributes the notification to each user individually.

2. `Greet User: NotificationSent Handler` -- An event handler with a `when` guard on the declaration: `when <age> >= 16`. This means the handler only fires for users aged 16 or above. Inside the handler, extract the user name from `<event: user>` and log "hello " concatenated with the name. Users under 16 are silently skipped.
