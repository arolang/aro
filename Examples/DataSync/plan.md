# Build a data sync pipeline between remote URLs and local files

Create a single-file ARO application that demonstrates syncing data between remote APIs and local files using unified Read/Write syntax.

In the `Application-Start` feature set:

1. Fetch remote data: `Read the <remotedata> from the <url: "https://jsonplaceholder.typicode.com/posts/1">`. Extract the title.
2. Save to local file: `Write the <remotedata> to the <file: "/tmp/synced-post.json">`.
3. Read the local file back: `Read the <localdata> from the <file: "/tmp/synced-post.json">`. Extract the title to verify.
4. Create transformed data with a new title and body.
5. Upload to remote: `Write the <newpost> to the <url: "https://jsonplaceholder.typicode.com/posts">`.

Log progress at each step and return OK.
