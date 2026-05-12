# Build an interactive terminal menu application

Create an ARO application with three files that implements an interactive terminal menu with keyboard navigation, repository-driven state, and template-based rendering.

- `main.aro` -- `Application-Start: Simple Menu`. Clear the terminal screen. Render loading, splash, and welcome screens using `Transform the <loading> from the <template: starting.screen>` and `Render <loading> to the <console>`. Store initial menu state `{ key: "menu", selection: 0, view: "menu" }` into `<selection-repository>`. Start keyboard listening with `Listen the <keyboard> to the <stdin>`. Use Keepalive.

- `handlers.aro` -- Four keyboard event handler feature sets:
  - `Navigate Menu: KeyPress Handler` -- Handles up/down arrow keys. Retrieves current state from repository, uses nested match expressions to cycle the selection index (0/1/2), updates state, and stores back to trigger the observer.
  - `Select Item: KeyPress Handler<key:enter>` -- On Enter, switches the view to "tasks", "logs", or exits (for index 2) by updating the repository state.
  - `Go Back: KeyPress Handler<key:backspace>` -- Returns to "menu" view.
  - `Quit App: KeyPress Handler<key:q>` -- Renders goodbye screen and stops the keyboard.

- `observer.aro` -- `Refresh View: selection-repository Observer`. Watches for any state change. Based on the current `view` field, renders the appropriate screen template (menu with selection markers, tasks list, or logs view) using `Transform` and `Render`.
