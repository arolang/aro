# Build a file and directory operations demo

Create a single-file ARO application that demonstrates native file and directory operations: CreateDirectory, Write, Append, Read, Copy, List, and Move.

In the `Application-Start` feature set:

1. Define paths for a demo directory ("./demo-output"), a hello file, a backup file, and a copy file.
2. Create the demo directory using `CreateDirectory the <created-directory> to the <path: demo-dir>`.
3. Write "Hello from ARO!" to hello.txt using `Write the <content> to the <file: hello-file>`.
4. Append a line using `Append the <appended> to the <file: hello-file> with <append-line>`.
5. Read the file back using `Read the <file-content> from the <file: hello-file>`.
6. Copy the file to a backup using `Copy the <file: hello-file> to the <destination: backup-file>`.
7. List directory contents using `List the <files> from the <directory: demo-dir>`.
8. Rename/move the backup using `Move the <moved-file: backup-file> to the <destination: copy-file>`.
9. List the directory again to show the final state.

Log progress at each step and return OK.
