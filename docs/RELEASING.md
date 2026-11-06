# Releasing

Pushing a version tag makes CI publish a GitHub release with the APK.

```bash
make deploy             # = deploy-patch; or deploy-minor, deploy-major (runs tool/release.sh)
tool/release.sh 1.3.0-beta.1   # an explicit version
```

It bumps `version:` in `pubspec.yaml`, commits "release vX.Y.Z", tags it, and after a confirmation pushes `main` and the tag (`--dry-run` only prints the new version). It refuses to run off `main`, with uncommitted changes, or if the tag exists. Pushing goes to all of `origin`'s push URLs; only GitHub runs the workflow. Wait for CI on the pushed commit if you want the checks before the tag; otherwise the tag's own run does them before publishing.

The `release` job in `.github/workflows/flutter.yml` runs after tests, the release build and the integration tests passed. It then:

- fails if the tag differs from the `version:` in `pubspec.yaml`,
- fails if the APK is signed with the debug key (`tool/check_apk_signature.sh`),
- creates the release with generated notes (from the commits and PRs since the last tag), `voidweaver-v1.2.0.apk` and its `.sha256`. A version with a suffix (`1.2.0-beta.1`) is marked as a prerelease.

## Signing key (one time)

An installed app only updates to an APK signed with the same key, so releases need a stable key. Without one, CI signs with a debug key that is different on every run, and the release job refuses to publish.

```bash
# keytool comes with a JDK; Android Studio's is at
# "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
mkdir -p ~/.android-keys
keytool -genkeypair -v -keystore ~/.android-keys/voidweaver-release.jks -alias voidweaver \
  -keyalg RSA -keysize 4096 -validity 10000
base64 < ~/.android-keys/voidweaver-release.jks | gh secret set RELEASE_KEYSTORE_BASE64
gh secret set RELEASE_KEYSTORE_PASSWORD
gh secret set RELEASE_KEY_ALIAS          # voidweaver
gh secret set RELEASE_KEY_PASSWORD
```

Keep the `.jks` and its passwords somewhere safe outside the repository, as above (`*.jks` is also git-ignored). If the key is lost, installed copies can't be updated; users have to uninstall first, which clears their login and cache.

`android/app/build.gradle.kts` reads the key from `VOIDWEAVER_KEYSTORE_FILE`, `VOIDWEAVER_KEYSTORE_PASSWORD`, `VOIDWEAVER_KEY_ALIAS` and `VOIDWEAVER_KEY_PASSWORD`. To sign a release locally, export them before `flutter build apk --release`; without them the build is debug-signed, which is fine for local checks. Secrets aren't available to pull requests from forks, so those builds are debug-signed too.
