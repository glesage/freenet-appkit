# freenet-appkit

Freenet AppKit for iOS and Android: one web app per installation, River or Atlas, on a Freenet node that runs inside the app.

The Rust side lives in [freenet-core](https://github.com/freenet/freenet-core) as `crates/mobile` (package `freenet-mobile`). It embeds a node in the app process and exposes it to Swift and Kotlin through [UniFFI](https://mozilla.github.io/uniffi-rs/latest/). This repository packages that library for each platform and builds the apps on it.

```mermaid
flowchart LR
  subgraph phone["iOS app / Android app"]
    welcome["Welcome screen<br/>(first start only)"]
    tabs["The hosted app: River (or Atlas)"]
    web["WKWebView / WebView"]
    host["NodeHost<br/>(foreground only)"]
    node["freenet-mobile<br/>(embedded Core node)"]
  end
  welcome --> tabs --> web
  web -- "HTTP and WebSocket on 127.0.0.1" --> node
  host -- "start, stop, events" --> node
  node -- "UDP" --> peers["Public Freenet network"]
```

## What is here

| Path | Contents |
| --- | --- |
| `Package.swift`, `Sources/FreenetAppKit/` | Swift package: the generated bindings, directory helpers, the bundle scheme handler and the WebView bridge host |
| `android/appkit/` | Kotlin library: the generated bindings, the native libraries for each ABI, the bundle server and bridge host |
| `ios/` | iOS app (SwiftUI) |
| `android/demo/` | Android app |
| `art/` | App icon art for both platforms |
| `scripts/` | Library, app and store builds, and the store build check |
| `results/`, `docs/` | Results of 1.1 Mobile feasibility and supported profiles ([support matrix](docs/support-matrix.md), [device results](docs/device-results.md), [findings](docs/findings.md)), the [distribution review](docs/distribution-review.md), the [store build plan](docs/store-build-plan.md) and the [review notes](docs/review-notes.md) |

The harness and measurement scenarios that produced `results/` are at git tag `plan-1.1-harness`.

## The app

Each installation hosts one web app, with its own node, stores, web data and consent records. River is the release host; Atlas is a separate installation for testing.

| | iOS | Android |
| --- | --- | --- |
| Name on the home screen | River (Atlas) | River (Atlas) |
| Store name | Freenet AppKit | Freenet AppKit |
| Identifier | `freenet.appkit` (`freenet.appkit.atlas`) | `freenet.appkit` (`freenet.appkit.atlas`) |
| How the app is chosen | `APP=river` or `APP=atlas` for the build scripts (`APPKIT_APPLICATION` build setting) | `river` or `atlas` product flavor |
| Lowest OS | iOS 16, iPhone | Android 9 (API 28) |
| Wasm backend | Pulley, checked at every start | Pulley on every ABI, checked at every start |

The embedded node joins the public Freenet network, fetches the app's website container and serves it to the web view on `127.0.0.1`, on one port chosen at the first start so web storage keeps one origin.

```mermaid
flowchart TD
  fg["App in the foreground"] --> want["Host wants the node running"]
  bg["App in the background"] --> stop["Host wants the node stopped"]
  want --> rec["One reconciler<br/>start and stop never overlap"]
  stop --> rec
  rec -- "stop ends the session" --> drop["Old page dimmed, bridge messages<br/>and prompts from it refused"]
  rec -- "start opens a session" --> open{"Saved page?"}
  open -- "yes" --> show["Open it before joining the network"]
  open -- "no" --> join["Wait for the first peer, then open"]
```

- The node runs only while the app is open. A stop has one deadline (4.5 s) for draining, node exit and port release; an incomplete stop is reported.
- A later start reads the gateway list saved by the first one, so it never waits on the gateway index; the running node refreshes the list.
- The page stays on screen with a "Reconnecting" label until the new session has drawn it, and with an "Offline" label while the device has no network. When the network returns and the node still has no peers 10 s later, the host restarts it, at most twice a minute.
- Bridge messages must come from the page's web view, the right frame and origin, within the size limit and during the session the page was loaded for. Alerts need the user's grant. Permission prompts close when their session ends and their answers are dropped.
- Links: pages on the session's origin open in place; web links the user taps open in the browser; other schemes are refused.

## Build and run

Needs Xcode, the Android SDK with NDK r29, Rust with the targets below, and the neighbouring checkout `../freenet-core`.

```bash
rustup target add --toolchain 1.94.0 aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android x86_64-linux-android armv7-linux-androideabi
```

Build the libraries:

```bash
scripts/build-ios.sh
```

```bash
scripts/build-android.sh
```

Build the apps for the simulator, a phone or the emulator:

```bash
scripts/build-ios-app.sh Release simulator
```

```bash
DEVICE_ID=<udid> DEVELOPMENT_TEAM=<team> scripts/build-ios-app.sh Release device
```

```bash
scripts/build-android-app.sh Release
```

Add `APP=atlas` to the app build commands for the Atlas installation.

## Store builds

Each store build needs a number that goes up on every upload. The iOS build needs the project's paid Apple Developer Program team. The Android build needs the upload key: copy `android/keystore.properties.example` to `android/keystore.properties` and fill it in.

```bash
DEVELOPMENT_TEAM=<team> BUILD_NUMBER=<n> scripts/archive-ios.sh
```

```bash
VERSION_CODE=<n> scripts/bundle-android.sh
```

Both take `APP=atlas` for the Atlas installation. Both finish with `scripts/check-store-build.sh`, which checks the package for the icon, the privacy manifest, the encryption key, the lowest OS (iOS 16, API 28), the hosted app, iPhone only, the native library for every Android ABI with 16 KB ELF alignment, release signing, 16 KB APK alignment and the absence of test code. It can also be run on any built `.app`, `.apk` or `.aab`:

```bash
scripts/check-store-build.sh ios build/ios/DerivedData-river/Build/Products/Release-iphonesimulator/AppKitDemo.app
```

```bash
scripts/check-store-build.sh android android/demo/build/outputs/apk/river/release/demo-river-universal-release.apk
```

Text for App Review and Play review is in [review notes](docs/review-notes.md).
