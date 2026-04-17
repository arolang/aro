# Build a collection grouping demo

Create a single-file ARO application that demonstrates the `Group` action for partitioning collections by field value.

In the `Application-Start` feature set:

1. Create a list of order objects with id, status, and amount fields. Use `Group the <status-groups> from the <orders> by "status"` to partition orders by their status. Log the result.

2. Create a list of user objects with name, country, and role fields. Group them by "country" and then by "role", logging each grouping result.

Return OK at the end.
