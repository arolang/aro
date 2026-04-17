# Build a command-line parameter extraction demo

Create a single-file ARO application that demonstrates extracting command-line parameters. Run with: `aro run ./Examples/Parameters --name "World" --count 3 --verbose`.

In the `Application-Start` feature set, use `Extract the <name> from the <parameter: name>` and `Extract the <count> from the <parameter: count>` to get CLI arguments. Log a greeting using the name and the count value. Return OK with the name.
