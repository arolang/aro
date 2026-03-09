# Chapter 23B: Code Signing

*"A binary your teammates can actually run."*

---

## 23B.1 The Problem

You build an ARO application, compile it to a native binary, send it to a colleague, and they get a macOS dialog saying the file is damaged or from an unidentified developer. Nothing is wrong with the binary. macOS is working exactly as designed.

This is Gatekeeper—Apple's mechanism for controlling what software can run on a Mac. Gatekeeper checks whether a binary has been signed with a trusted identity. If it has not, macOS blocks it by default. The user can override this, but the process is obscure and varies across macOS versions. Asking teammates to navigate security settings every time you share a binary is not a workable distribution strategy.

The solution is code signing. A signed binary carries a cryptographic certificate that tells macOS who produced it and that the binary has not been modified since it was signed. Gatekeeper trusts signed binaries from recognized identities and allows them to run without user intervention.

---

## 23B.2 Types of Signing

macOS code signing operates at different trust levels, each suited to different distribution scenarios.

**Ad-hoc signing** is the simplest form. You sign the binary with a placeholder identity (`-`) rather than a real certificate. Ad-hoc signing tells macOS that the binary has not been tampered with since it was created, but it does not identify a developer. This removes the "damaged" error on machines where the binary was built or explicitly trusted, but does not satisfy Gatekeeper on other machines. Ad-hoc signing is useful for development and for binaries shared within a trusted team where you can explicitly trust the binary once.

**Developer ID signing** uses a certificate issued by Apple through the Apple Developer Program. This certificate identifies you or your organization as a registered developer. Gatekeeper trusts Developer ID signatures without any user interaction. Binaries signed with a Developer ID can be distributed to anyone running macOS and will run without Gatekeeper prompting. This is the appropriate level for binaries distributed to external users.

**Notarization** goes further than signing. Apple's notarization service scans your binary for malware and returns a ticket that Gatekeeper can verify. Starting with macOS Catalina, notarized binaries are required for distribution outside the Mac App Store on recent macOS versions. Notarization requires Developer ID signing with the hardened runtime enabled.

---

## 23B.3 The --sign Flag

The `aro build` command accepts a `--sign` option that specifies a signing identity. After linking the binary, the compiler runs `codesign` with the identity you provide.

For ad-hoc signing, use the special identity `-`:

```
aro build ./MyApp --sign '-'
```

For Developer ID signing, use your identity string. You can find your available identities by running `security find-identity -v -p codesigning` in your terminal. The identity string looks like:

```
aro build ./MyApp --sign 'Apple Development: Your Name (TEAMID)'
```

Or with a Developer ID certificate for distribution:

```
aro build ./MyApp --sign 'Developer ID Application: Your Name (TEAMID)'
```

The signing step happens after compilation and linking, and after symbol stripping if `--strip` or `--release` was specified. The binary is signed in place—no separate signed copy is created.

---

## 23B.4 Hardened Runtime

The hardened runtime is a macOS security feature that restricts what a running process can do. It disables certain capabilities—like loading unsigned code or inheriting dangerous environment variables—unless the binary explicitly declares it needs them through entitlements.

Apple requires the hardened runtime for notarization. If you intend to notarize your binary, enable it with `--hardened-runtime`:

```
aro build ./MyApp --sign 'Developer ID Application: Your Name (TEAMID)' --hardened-runtime
```

Most ARO applications work correctly with the hardened runtime enabled. If your application loads plugins (Swift, C, or Rust dynamic libraries), you may need to add a `com.apple.security.cs.disable-library-validation` entitlement to allow loading unsigned plugin libraries. This is handled separately from `aro build` using standard Xcode or `codesign` tooling.

For development and team-internal distribution, you do not need the hardened runtime. Include it only when preparing a build for notarization.

---

## 23B.5 Combining with Release Builds

Signing is independent of optimization. You can combine `--sign` with any other build flags. For a production-ready binary:

```
aro build ./MyApp --release --sign 'Developer ID Application: Your Name (TEAMID)'
```

This produces a release-optimized, stripped, signed binary in one step. The `--release` flag handles optimization and stripping; `--sign` handles the security certificate.

For notarization-ready release builds:

```
aro build ./MyApp --release --sign 'Developer ID Application: Your Name (TEAMID)' --hardened-runtime
```

---

## 23B.6 Notarization

Notarization is a separate step that happens after signing. It uploads your binary to Apple's servers, which scan it for malware and return a notarization ticket. You then staple the ticket to the binary so Gatekeeper can verify it offline.

Once you have a signed binary, submit it for notarization using Apple's `notarytool`:

```
xcrun notarytool submit MyApp \
  --apple-id your@email.com \
  --team-id YOURTEAMID \
  --password '@keychain:AC_PASSWORD' \
  --wait
```

After notarization succeeds, staple the ticket:

```
xcrun stapler staple MyApp
```

A stapled binary carries its notarization ticket embedded in the file. Gatekeeper can verify a stapled binary without any network request, which matters in environments where machines are offline or have restricted internet access.

---

## 23B.7 Verifying a Signature

After signing, you can verify that the binary is correctly signed using the `codesign` tool:

```
codesign --verify --verbose MyApp
```

To see detailed information about the signature, including the identity and timestamp:

```
codesign -dv --verbose=4 MyApp
```

To check what Gatekeeper would do with the binary:

```
spctl --assess --verbose MyApp
```

A Developer ID signed and notarized binary passes the `spctl` assessment. An ad-hoc signed binary does not—`spctl` requires a Developer ID for Gatekeeper assessment. But ad-hoc signing still removes the "damaged" error on machines where the binary originated.

---

## 23B.8 Platform Scope

The `--sign` and `--hardened-runtime` flags are macOS-only. Code signing as described here is a macOS-specific requirement; Linux and Windows have different distribution and trust mechanisms.

On Linux, distributing binaries typically does not require code signing. Package managers handle trust through repository signing at the distribution level, not the binary level. If you distribute Linux binaries outside a package manager, consider providing checksum files so recipients can verify integrity.

On Windows, Authenticode signing serves a similar purpose to macOS code signing. This is not currently integrated into `aro build`.

---

## 23B.9 Developer Workflow

For day-to-day development, code signing is not necessary. Use `aro run` or unsigned `aro build` binaries on your own machine.

When sharing binaries with teammates on macOS, use ad-hoc signing:

```
aro build ./MyApp --sign '-'
```

This eliminates the "damaged" error for teammates who receive the binary. They may still need to right-click and choose Open the first time, depending on their macOS version and security settings, but they will not be blocked entirely.

For public releases or distribution to users outside your organization, use Developer ID signing and notarization. This requires an Apple Developer Program membership (currently $99/year) and a Developer ID certificate issued through the developer portal.

---

*Next: Chapter 24 — Multi-file Applications*
