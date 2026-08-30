# Security policy

## Supported code

Security fixes target the Windows USB host on the `custom` branch and its
separate `AudioShare-Android` companion repository. The historical upstream
Android `com.ysbing.audioshare` server is retired and unsupported.

## Retired signing key

The upstream repository published a default Android keystore and password.
That key is permanently untrusted and was removed from the current tree along
with the retired APK and Gradle module. Never install or distribute an Android
package whose authenticity depends on that key. Git history is retained for
upstream attribution, so deleting the current file does not make the old key
secret again.

Production companion releases must use a private external signing key. The
Windows release build validates the supplied APK signature, package ID, and
minimum compatible version before packaging it.

## Reporting

Do not publish session tokens, signing material, or private device identifiers
in an issue. Report a reproducible problem with secrets removed through the
repository's GitHub security-advisory interface.
