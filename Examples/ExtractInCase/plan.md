# Build a demo of Extract within match/case blocks

Create a single-file ARO application that demonstrates using Extract inside case blocks of a match expression.

In the `Application-Start` feature set, extract a response object with status and body fields from an inline object literal. Extract the status code. Use a `match <status>` expression where the case 200 block extracts the body and then the message from the body, logging the result. Include a case 404 and an otherwise fallback.
