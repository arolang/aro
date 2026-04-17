# Build a template rendering demo

Create a single-file ARO application that demonstrates Mustache-style template rendering with variable interpolation.

In the `Application-Start` feature set, create a user object with fields firstName, email, and plan. Then render a template file using `Transform the <email-content> from the <template: emails/welcome.tpl>`. The template path uses slash-separated segments. Log the rendered output between "--- Rendered Output ---" and "--- End Output ---" markers.
