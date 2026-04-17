# Build an error handling demo with guarded throws

Create a single-file ARO application that demonstrates the `Throw` action with `when` guards for conditional error throwing.

In the `Application-Start` feature set, show four scenarios:

1. **Validation** -- Create `<age>` with 25. Use `Throw the <ValidationError> for the <invalid-age> when <age> < 0`. Since age is positive, this does not fire. Log "Age validation passed!".

2. **Authorization** -- Create `<user-role>` with "admin". Throw an `<AuthorizationError>` for `<access-denied>` when role equals "guest". Since role is "admin", this does not fire. Log "Authorization check passed!".

3. **Resource check** -- Create `<resource-exists>` with true. Throw a `<NotFoundError>` for `<resource-missing>` when resource-exists equals false. This does not fire. Log "Resource validation passed!".

4. **Triggered throw** -- Create `<invalid-input>` with -5. Throw an `<InputError>` for `<negative-value>` when invalid-input is less than 0. This WILL fire, halting execution. Any statements after this should not be reached.

Log descriptive section headers before each scenario.
