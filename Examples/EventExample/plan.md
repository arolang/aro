# Build a multi-handler event example

Create an ARO application with two files that demonstrates emitting an event and having multiple handlers react to it.

- `main.aro` -- Contains the `Application-Start` feature set that logs a startup message, emits a `<NumberTriggered: event>` with the payload "Event triggered!", logs that the event was emitted, and returns OK. Also include an `Application-End: Success` handler that logs "Very Good!".

- `handlers.aro` -- Contains five separate event handler feature sets, all with business activity `NumberTriggered Handler`. Each one simply logs "Handler #N executed" (where N is 1 through 5) and returns OK. All five handlers will fire when the NumberTriggered event is emitted.
