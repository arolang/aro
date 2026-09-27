# Compare two values and read the result

Create an ARO application that uses `Compare … against …` and reads both of
the result's fields.

- `main.aro` — one `Application-Start` feature set that:
  - compares two equal numbers and logs `<r: matches>` and `<r: result>`,
  - compares against a smaller and a larger number, showing `greater` and
    `less`,
  - compares two strings and uses `<r: matches>` as a `when` guard.

The example runs in `mode: both` deliberately: the `against` operand was not
bound in compiled binaries, so the comparison ran with no right-hand side.
