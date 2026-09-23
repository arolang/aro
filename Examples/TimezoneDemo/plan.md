# Render one instant in several timezones

Create an ARO application that converts a UTC instant into other zones and
shows what conversion does and does not change.

- `main.aro` — one `Application-Start` feature set that:
  - parses two UTC instants six months apart,
  - converts both to `Europe/Berlin` with
    `Extract the <r: timezone> from <date> with "Europe/Berlin".` and logs the
    local hour and whether DST is in effect — they differ, which is the case a
    fixed offset gets wrong,
  - converts one to `Asia/Tokyo` with the zone written as the qualifier,
  - logs the timestamps of two renderings to show the instant did not move,
  - converts back to UTC and logs the hour, showing the round trip is the
    identity.
