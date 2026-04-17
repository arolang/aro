# Build a reactive task manager with repository observers

Create a single-file ARO application that demonstrates the repository observer watch pattern for reactive UI updates.

In `main.aro`:

1. `Application-Start: Task Manager` -- Create three task objects with id, title, and status. Store each into `<task-repository>`. Use Keepalive.

2. `Dashboard Watch: task-repository Observer` -- Fires automatically whenever the task repository changes. Retrieves all tasks from the repository and logs a dashboard header. This enables reactive rendering without polling.

3. `Add Task: TaskAdded Handler` -- Handles TaskAdded events. Extracts the title, creates a new task with "pending" status, and stores it into the task repository (which triggers the Dashboard Watch observer).
