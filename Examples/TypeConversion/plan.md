# Build a type conversion demo

Create a single-file ARO application that demonstrates the `Transform` action for converting values between types.

In the `Application-Start` feature set, show six type conversions:

1. String to integer: `Transform the <int-num: int> from the <str-num>` (where str-num is "42").
2. Integer to string: `Transform the <str-val: string> from the <number>` (123).
3. String to double: `Transform the <price: double> from the <str-price>` ("19.99").
4. String to boolean: `Transform the <flag: bool> from the <str-bool>` ("true").
5. Object to JSON string: `Transform the <json-str: json> from the <person>`.
6. Integer to double: `Transform the <double-val: double> from the <int-val>`.

Log each conversion result with a descriptive label.
