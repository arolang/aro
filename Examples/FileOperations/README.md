# File Operations Example

This example demonstrates the native file and directory operations introduced in ARO-0036.

## Features Demonstrated

- **Exists** - Check if files or directories exist
- **CreateDirectory** - Create directories (including parents)
- **Write** - Write content to files
- **Append** - Append content to files
- **Read** - Read file content
- **Stat** - Get file metadata (size, dates, permissions)
- **Copy** - Copy files or directories
- **List** - List directory contents
- **Move** - Move or rename files

## Running

```bash
aro run ./Examples/FileOperations
```

## Expected Output

```
=== ARO File Operations Demo ===

1. Checking if demo directory exists...
   Directory exists: false
2. Creating demo directory...
   Created ./demo-output
3. Writing hello.txt...
   Wrote hello.txt
4. Appending to hello.txt...
   Appended to hello.txt
5. Reading hello.txt...
   Content:
Hello from ARO!
This line was appended.
6. Getting file stats...
   Name: hello.txt
   Stats retrieved successfully
7. Copying to backup...
   Copied to hello-backup.txt
8. Listing demo-output directory...
   Files in demo-output:
9. Renaming backup file...
   Renamed to hello-copy.txt
10. Final directory listing...
   Final files:

=== Demo Complete ===
```

## Cleanup

The demo creates a `demo-output` directory. You can remove it after running:

```bash
rm -rf ./Examples/FileOperations/demo-output
```
