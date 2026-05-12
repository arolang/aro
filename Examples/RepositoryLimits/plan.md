# Build a repository limits demo with maxSize and TTL

Create a single-file ARO application that demonstrates repository constraints: maximum size with FIFO eviction and time-to-live expiry.

In `main.aro`:

1. `Application-Start: Repository Limits Demo` --
   - **maxSize**: Configure `<log-repository: maxSize>` with 3. Store four items; storing the 4th evicts the oldest (FIFO). Retrieve all entries and log the count (should be 3).
   - **TTL**: Configure `<cache-repository: ttl>` with 1 (second). Store an item, retrieve immediately (count = 1), sleep for 2 seconds, retrieve again (count = 0 because the item expired).

2. `Track Eviction: log-repository Evicted Handler` -- An eviction event handler that fires when an item is evicted from the log-repository due to maxSize. Extract the evicted item from `<event: evictedItem>` and log its label.
