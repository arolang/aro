# CurrencyAmounts

Show that money arithmetic is exact where the amount is produced, and that the
exactness survives every sink and both execution modes.

## What it demonstrates

- `Compute the <line-total> as Currency from <qty> * <price>.` — three items at
  `2.40` is `7.2`, not `7.199999999999999`.
- `as Decimal` is the same format under a different name.
- An exact amount is *contagious*: a statement that reads one stays exact
  without repeating the annotation, which is what lets a pipeline compute an
  amount once and have every aggregate downstream agree about it.
- Division has a stated rule rather than a silent one: six decimal places,
  half-up, trailing zeros dropped to the wider operand's scale. `6.00 / 2` is
  `3.00`; `10.00 / 3` is `3.333333`.
- `fixed` still settles a presentation scale, and on an exact amount it is a
  rescale rather than a repair.
- The amount serialises as a **number** at full precision: console, JSON and
  CSV all read `99.95`, never `99.94999999999999` and never `"99.95"`.

## Why it is an example and not only a unit test

ARO-0003 requires `aro run` and an `aro build` binary to agree. The compiled
path has its own expression evaluator, and the `as <Type>` annotation reaches
it over a different channel than the interpreter's. This example is run in both
modes by the integration runner against one `expected.txt`, so a divergence
fails the build rather than waiting to be noticed in a data product.

## Expected output

See `expected.txt`. The float line is kept deliberately: the contrast between
`7.199999999999999` and `7.2` on adjacent lines is the whole point.
