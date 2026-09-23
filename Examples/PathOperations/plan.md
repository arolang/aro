# Take paths apart and put them back together

Create an ARO application that uses the path qualifiers and the file-metadata
statements, rather than string concatenation and `Split`.

- `main.aro` — one `Application-Start` feature set that:
  - splits `/var/data/report.csv` with `basename`, `dirname`, `extension` and
    `stem`, and logs each,
  - rebuilds a renamed path with `path-join`, showing the three agree,
  - joins `"uploads/"` to `"/photo.png"` and logs the single separator,
  - joins `/uploads` to `/etc/passwd` and shows the absolute right-hand
    component does **not** reset the path,
  - shows a dotfile has no extension,
  - resolves `.` and `..` with `absolute`,
  - touches a marker file and logs whether it was created,
  - sets its permissions with `Configure … with { permissions: "755" }`, logs
    the new and previous modes, reads them back with `Stat`, and deletes the
    file.
