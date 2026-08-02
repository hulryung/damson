# damson release pipeline

`swift build -c release` → `.app` bundle → Developer ID codesigning →
Apple notarization → `.dmg`. Sparkle auto-updates and GitHub Actions
automation are left as separate steps.

## One-time setup

### Apple Developer certificate

A Developer ID Application certificate must be in the keychain.

```sh
security find-identity -p codesigning -v
# Example output:
#   1) 1234ABCD... "Developer ID Application: Your Name (TEAMID)"
```

Set the full identity string as `APPLE_SIGNING_IDENTITY`.

### Notarization credentials

Pick one of two methods:

**Method A — keychain profile (recommended)**

```sh
xcrun notarytool store-credentials damson-notary \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
```

Then just set `NOTARY_KEYCHAIN_PROFILE=damson-notary`.

**Method B — pass via env every time**

Export `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` (issued at appleid.apple.com),
and `APPLE_TEAM_ID` on every run.

## Release in one shot

```sh
export APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE=damson-notary
MARKETING_VERSION=0.1.0 ./scripts/release.sh
```

Result:
```
dist/
├── Damson.app          # signed + notarized + stapled
└── Damson-0.1.0.dmg    # signed + notarized + stapled
```

## Step by step

For fast iteration:

```sh
# 1) Build only — dev verification without signing
SKIP_NOTARIZE=1 ./scripts/build-app.sh
open dist/Damson.app

# 2) Sign only — notarization takes time, so keep it separate
SKIP_NOTARIZE=1 ./scripts/sign-and-notarize.sh

# 3) The real thing (sign + notarize)
./scripts/sign-and-notarize.sh

# 4) dmg
./scripts/build-dmg.sh
```

## Verification

To confirm the distribution actually passes Gatekeeper:

```sh
spctl --assess --type execute --verbose=4 dist/Damson.app
# accepted, source=Notarized Developer ID
```

The `.dmg` too:

```sh
spctl --assess --type open --context context:primary-signature dist/Damson-0.1.0.dmg
```

## Installing damson-cli

It ships inside the `.app` bundle as `Contents/Resources/damson-cli`. Users
typically symlink it into `/usr/local/bin`:

```sh
sudo ln -sf /Applications/Damson.app/Contents/Resources/damson-cli \
    /usr/local/bin/damson-cli
damson-cli --list-instances
```

An "Install Command-Line Tool…" button in the Settings UI is planned.

## Versioning

Set the marketing version (CFBundleShortVersionString) via the
`MARKETING_VERSION` env var. If `BUILD_NUMBER` is unset, it is auto-filled
with epoch seconds.

```sh
MARKETING_VERSION=0.2.0 BUILD_NUMBER=20260526 ./scripts/release.sh
```

## Sparkle auto-updates

The `.app` automatically checks for updates at launch via
SPUStandardUpdaterController. Users can check immediately via the App menu →
"Check for Updates…".

### One-time: generate the EdDSA key

```sh
./scripts/sparkle-keygen.sh
# Example output: rxFA7zVTQNxX1cd...= (base64 public key)
```

Put this public key string in the `SPARKLE_PUBLIC_KEY` env var and
build-app.sh automatically bakes it into Info.plist as `SUPublicEDKey`. The
private key stays stored in the macOS keychain
(`security find-generic-password -s "https://sparkle-project.org" -a ed25519`).

### When releasing

```sh
export SPARKLE_PUBLIC_KEY='rxFA7zVTQNxX1cd...='
MARKETING_VERSION=0.1.0 ./scripts/release.sh
./scripts/sparkle-appcast.sh \
    --dmg dist/Damson-0.1.0.dmg \
    --version 0.1.0 \
    --build 1 \
    --url 'https://github.com/hulryung/damson/releases/download/v0.1.0/Damson-0.1.0.dmg' \
    > /tmp/entry.xml
python3 .github/scripts/insert-appcast-entry.py appcast.xml /tmp/entry.xml > appcast.new.xml
mv appcast.new.xml appcast.xml
git add appcast.xml && git commit -m "appcast 0.1.0"
git tag v0.1.0 && git push --tags
gh release create v0.1.0 dist/Damson-0.1.0.dmg
```

`SUFeedURL` is baked in as `https://raw.githubusercontent.com/.../main/appcast.xml`,
so once the appcast.xml commit is pushed to main, users get notified on the
next background check.

## GitHub Actions automated release

`.github/workflows/release.yml` — pushing a `v*` tag runs every step
automatically (build → sign → notarize → .dmg → appcast update → GitHub
Release creation).

### Required secrets (Settings → Secrets and variables → Actions)

| Key | Description |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application `.p12` via `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when importing the `.p12` |
| `APPLE_SIGNING_IDENTITY` | `"Developer ID Application: Your Name (TEAMID)"` |
| `APP_STORE_CONNECT_KEY_B64` | App Store Connect API key (`.p8`) → base64 |
| `APP_STORE_CONNECT_KEY_ID` | ASC API Key ID |
| `APP_STORE_CONNECT_ISSUER` | ASC Issuer ID (UUID) |
| `APPLE_TEAM_ID` | `ABCDE12345` |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key (sparkle-keygen.sh output) |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key (keychain export) |

Notarization prefers the App Store Connect API key; `APPLE_ID` +
`APPLE_APP_SPECIFIC_PASSWORD` still work as a legacy fallback if the ASC
secrets are absent.

How to export the private key:
```sh
security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w \
  | base64
# Paste this output into the SPARKLE_PRIVATE_KEY secret.
```

### Usage

```sh
git tag v0.1.0
git push --tags
# Actions runs automatically. Watch progress: gh run watch
```

Manual trigger also works: Actions tab → "release" workflow → "Run workflow" → enter version.

## Key custody

Two secrets can end a release: the Developer ID signing identity and the Sparkle
EdDSA key. GitHub Actions holds a copy of each, but **Actions secrets are
write-only** — they can be replaced, never read back. So the repository is not a
backup, and the only recoverable copies are the ones you keep yourself.

| Key | Lives in | Recoverable if lost? |
|---|---|---|
| Developer ID certificate | Apple Developer portal (re-downloadable) | Yes — the `.cer` is always available |
| …its private key | login keychain of the machine that made the CSR | **No** — revoke and issue a new certificate |
| Sparkle EdDSA private key | login keychain, `"https://sparkle-project.org"` / `ed25519` | **No** — and see below |
| App Store Connect API key (`.p8`) | downloaded once at creation | No, but a replacement key is free to issue |

### What losing each one costs

**Developer ID private key** — issue a new certificate and re-sign. Nothing
already shipped breaks; Gatekeeper keeps honoring binaries signed by the old
certificate as long as it was valid and notarized when they were signed. The
cost is process, not users. (Note Developer ID certificates are rate-limited per
team, so don't churn them.)

**Sparkle EdDSA private key** — this is the expensive one. Every installed copy
verifies updates against the `SUPublicEDKey` baked into *its own* Info.plist, so
a new keypair orphans every user already in the field: their app rejects the
update as unsigned and stays where it is until they download a `.dmg` by hand.
There is no rotation path that reaches an app that has already shipped.

**Leaking** either private key is worse than losing it — someone else can ship
software signed as you. If a Developer ID key leaks, Apple revokes the
certificate, and revocation applies to what you already shipped: those builds
stop launching. Treat both as company credentials, not developer conveniences.

### Backing them up

```sh
# Developer ID: Keychain Access → select the certificate AND its private key
# → right-click → Export → .p12 (this is exactly what APPLE_CERTIFICATE_BASE64 holds)

# Sparkle EdDSA:
generate_keys -x sparkle-private.key      # .build/artifacts/sparkle/Sparkle/bin/
generate_keys -f sparkle-private.key      # …and to import it on another machine
```

Keep two copies that don't share a failure mode: one in the team password
manager's shared vault (restricted to whoever cuts releases), one offline on
encrypted media. Not in this repository, not in Slack or email, not in
unencrypted cloud sync.

Give the `.p12` a long random export password — PKCS#12 can be brute-forced
offline, so a memorable password means the file leaking is the key leaking.
Store that password in the password manager, and delete the exported files from
disk once they are in the vault; both are plaintext key material until then.

## Known limitations

- **No universal binary support** — only the build machine's architecture
  (arm64 or x86_64). CI also runs only on arm64 (macos-14). Supporting Intel
  users would require a `swift build --arch arm64 --arch x86_64` + `lipo`
  merge step.
- **App icon not applied** — build-app.sh is already set up to include
  `Resources/Damson.icns` in the bundle automatically once it's added.
