# Support matrix

This matrix covers the River WebView route and the custom Swift/Kotlin route on iOS and Android, as of 2026-09-30. Measured values are in [device results](device-results.md), what the runs turned up is in [findings](findings.md), and store policy is in the [distribution review](distribution-review.md).

Runs cover a real iPhone 13 mini (iOS 27.0), the iOS Simulator and the Android emulator. No Android phone has run yet; the Android device column fills in when one does (see [Running on phones](#running-on-phones)).

## Routes

| Route | How the app reaches the node | iOS | Android |
| --- | --- | --- | --- |
| River WebView | River's web UI in WKWebView or android.webkit.WebView, served by the embedded node from River's website container at `http://127.0.0.1:<port>/v1/contract/web/<id>/`. River opens its own WebSocket through Core's shell page | Runs on the iPhone 13 mini (offline and public network) and the Simulator (also the test gateway) | Runs on the emulator: offline, test gateway and public network |
| Atlas WebView | Atlas main's web UI, served the same way | Runs on the iPhone and the Simulator | Runs on the emulator |
| Host-served bundle | The app's own files, checked against a per-file SHA-256 manifest, served under a custom scheme (iOS) or an intercepted `http://appkit.bundle/` origin (Android). JSON bridge to the host; the page opens its own WebSocket to the node | 5/5 checks | 5/5 checks |
| Custom Swift/Kotlin | `NodeClient` through UniFFI: put, get, update, subscribe | 10/10 checks against desktop | 10/10 checks against desktop |

## Targets and Wasm backends

| Platform | Rust target | Wasm backend | Executable memory | Build | Runs |
| --- | --- | --- | --- | --- | --- |
| iOS devices, arm64 | `aarch64-apple-ios` | Pulley. Cranelift is refused with a typed error | None | Builds, signs with a personal team | Conformance 12/12 on the iPhone 13 mini, iOS 27.0 |
| iOS Simulator, arm64 | `aarch64-apple-ios-sim` | Pulley, as on devices | None | Builds | Conformance 12/12 |
| Android arm64-v8a | `aarch64-linux-android` | Cranelift (default), Pulley available | Cranelift maps code executable | Builds, 16 KB-aligned | Conformance 24/24 on the API 37 emulator, both backends |
| Android x86_64 | `x86_64-linux-android` | Cranelift (default), Pulley available | As arm64 | Builds, 16 KB-aligned | Not run: no x86_64 image installed |
| Android armeabi-v7a | `armv7-linux-androideabi` | Pulley only: Cranelift has no 32-bit ARM backend | None | Builds after the Core fix in [findings](findings.md#32-bit-targets-did-not-build) | Not run: no 32-bit image installed |
| iOS Simulator on Intel Macs | `x86_64-apple-ios` | – | – | Not built | Unsupported |

On iOS, Core replaces each executor's Store after 4 instances and defaults to 2 executors, because the iPhone refused Core's default of 256 MiB reservations per instance kept until a Store is replaced (see [findings](findings.md#the-iphone-refused-cores-wasm-memory-reservations)).

On iOS and Android, wasmtime installs no process-wide signal or Mach exception handlers: Core turns signals-based traps off on both, so generated code checks bounds and divisors itself. The conformance suite confirms that out-of-bounds, divide-by-zero and unreachable traps still come back as typed errors on every backend.

## Pinned revisions

| Component | Revision | Notes |
| --- | --- | --- |
| freenet-core | `main` at `576f5445` | `freenet` 0.2.139. The runs used `1d13bf5d` with these changes uncommitted (reported as `1d13bf5d…+dirty`); the wait for the port in stop came after the runs |
| freenet-stdlib | 0.12.1 from crates.io | Same source as local `main` at `77fcf65` (tag `rust-v0.12.1`) |
| wasmtime | 47.0.3, with the `pulley` feature | |
| UniFFI | 0.32.2 | Swift module `FreenetMobile`, Kotlin package `org.freenet.mobile` |
| Rust | 1.94.0 | freenet-core's `rust-toolchain.toml` |
| Xcode | 27.0 (27A266a), iOS 27.0 SDK | Deployment target iOS 16.0 |
| Android | NDK r29 (29.0.14206865), AGP 9.1.1, Kotlin 2.3.21, Gradle 9.4.1 | compileSdk and targetSdk 36, minSdk 26 |
| Android libraries | JNA 5.17.0, androidx.webkit 1.15.0, kotlinx-coroutines 1.10.2 | |
| River website container | `raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv`, state SHA-256 `a925be93…` | Pinned in `fixtures/webapps.json`; fetched from the network on 2026-09-30 |
| River contracts | River `main` at `a7edaba3`: `ui/public/contracts/room_contract.wasm` | Compiled in the conformance run |
| Atlas website container | `771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9` | Pinned in `fixtures/webapps.json` |
| Atlas contracts | Atlas `main` at `ca32018`: `contracts/index-contract/atlas_index_contract.wasm` | Compiled in the conformance run |
| freenet-migrate | Not used by this plan | River's UI pins 0.5 and its CLI 0.6, both on stdlib 0.8.x; no release on stdlib 0.12 yet |

freenet-core changes this plan adds (commits `f5d32b58` and `576f5445`):

| Change | Files |
| --- | --- |
| `--wasm-backend cranelift\|pulley` and `WasmBackend` with the target's default; Pulley through wasmtime's `pulley` feature | `Cargo.toml`, `crates/core/src/config.rs`, `crates/core/src/config/wasm_backend.rs`, `crates/core/src/contract/executor/runtime.rs`, `crates/core/src/wasm_runtime/runtime.rs` |
| The engine refuses a backend the target cannot run, and turns signals-based traps off on iOS and Android | `crates/core/src/wasm_runtime/engine/wasmtime_engine.rs` |
| Runtime errors keep the trap kind, such as "out of bounds memory access" | same |
| `RuntimeOracle::standalone_with_backend` | `crates/core/src/conformance/runtime_oracle.rs` |
| The module-cache ceiling fits 32-bit targets | `crates/core/src/wasm_runtime/module_cache.rs` |
| iOS replaces each Store after 4 instances and defaults to 2 executors | `crates/core/src/wasm_runtime/engine/wasmtime_engine.rs`, `crates/core/src/config.rs` |
| Backend conformance tests and their fixture contract | `crates/core/src/wasm_runtime/tests/backend.rs`, `tests/test-contract-backend-conformance/` |
| The new mobile crate | `crates/mobile/` |

## Protocol compatibility

River's and Atlas's web clients use freenet-stdlib 0.8.5; Core `main` uses 0.12.1. Both web apps load and render against Core 0.12.1 through the node's native (bincode) encoding, and the contract request encodings they use are unchanged between the two versions. No adapter is needed for these routes. The shared fixtures pin the 0.12.1 request bytes, so a later stdlib change that moves a byte fails the device runs.

## Operations

✓ passed on that platform, – not run yet.

| Operation | iOS Simulator | iPhone 13 mini | Android emulator | Android device |
| --- | --- | --- | --- | --- |
| Wasm backend conformance | ✓ | ✓ | ✓ | – |
| Protocol fixtures: same bytes, typed errors, result after a timeout, callback order | ✓ | ✓ | ✓ | – |
| Swift/Kotlin route against desktop | ✓ | ✓ | ✓ | – |
| Host-served bundle and JSON bridge | ✓ | ✓ | ✓ | – |
| River and Atlas offline | ✓ | ✓ | ✓ | – |
| River and Atlas through the test gateway | ✓ | – | ✓ | – |
| River from the public network after a fresh install | ✓ | ✓ | ✓ | – |
| Foreground lifecycle: stop and fresh session | ✓ | ✓ | ✓ | – |
| Resume after another app | ✓ | ✓ | ✓ | – |
| Message alert and tap | ✓ | ✓ | ✓ | – |
| Subscription throughput | ✓ | ✓ with the iOS Store limits | ✓ | – |
| Large-record copying | ✓ | ✓ | ✓ | – |
| Contract stress (address space) | ✓ (300 stored) | ✓ 300 stored with the iOS Store limits; 22 with Core's defaults | ✓ (300 stored) | – |
| Fresh start on cellular (carrier NAT) | not possible on the Simulator | ✓ first peer in 5.6 s | not a real carrier | – |
| Wi-Fi to cellular while running | not possible on the Simulator | Fails: no traffic on cellular until Wi-Fi returns ([findings](findings.md#the-node-does-not-move-to-cellular-on-its-own)) | No disconnect: the emulator's Wi-Fi and cellular share one NAT | – |
| All networks off and back | not possible on the Simulator | – | Peer count stays up ([findings](findings.md#the-peer-count-stays-up-during-an-outage)) | – |
| Start while offline | not possible on the Simulator | Fails ([findings](findings.md#the-node-cannot-start-offline-in-network-mode)) | Fails | – |
| UDP-filtering network, battery, LAN test gateway | – | – | – | – |

## Required adapters

| Platform | Adapter | Why |
| --- | --- | --- |
| iOS | `WKURLSchemeHandler` (`freenet-bundle://`) | Serves only manifest-listed, verified bundle files |
| iOS | `WKScriptMessageHandler` named `freenetHost` | Carries bridge text; `crates/mobile` answers every message |
| iOS and Android | A `Notification` shim in the node's shell page | Neither WebView has the Notifications API. The shim hands alerts to the host, which shows them only in the foreground |
| Android | `WebViewCompat.addWebMessageListener` and `addDocumentStartJavaScript` (androidx.webkit) | Origin-checked bridge; needs a WebView with `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT` |
| Android | `shouldInterceptRequest` for `http://appkit.bundle/` | Serves the verified bundle |
| Android | Network security config allowing cleartext to `127.0.0.1`, `localhost` and `appkit.bundle` | The node serves plain HTTP on loopback |

## Unsupported operations and limits

| Operation | Status |
| --- | --- |
| Running while the app is in the background | Not offered: the node stops when the app leaves the foreground |
| Delegate calls from Swift or Kotlin | Not in the 1.1 native API; 1.2 Embedded node and mobile SDK adds them |
| Ending a subscription on the node | freenet-stdlib has no client Unsubscribe; `unsubscribe` stops local delivery and the node's subscription ends with the connection |
| Several requests in flight on one `NodeClient` | One at a time; 1.2 Embedded node and mobile SDK adds the per-contract queue |
| Web storage inside River's frame | The frame has an opaque origin, so `localStorage` is unavailable, as on desktop |
| Starting in network mode with no network | Fails; see [findings](findings.md#the-node-cannot-start-offline-in-network-mode) |

## Proposed supported profiles

This is a proposal for the plan owner to approve, based on the iPhone 13 mini, Simulator and emulator runs. The Android lines still need an Android phone.

| Profile | Proposal |
| --- | --- |
| River WebView on iOS | iOS 16 and later, arm64 devices, Pulley, with the provisional Store limits until Core's host code tolerates moving memory |
| River WebView on Android | Android 8 (API 26) and later. arm64-v8a with Cranelift, pending the store-policy decision in the [distribution review](distribution-review.md); armeabi-v7a with Pulley; x86_64 for emulators |
| Custom Swift/Kotlin | Put, get, update and subscribe on the same targets. Delegate calls come with 1.2 Embedded node and mobile SDK |
| Network | Network mode through the public gateway index or gateway overrides. Phones run as full peers until 1.8 Thin-peer role and cellular data budgets lands, which matters on cellular (see [findings](findings.md#phones-are-full-peers-on-the-public-network)) |

## Running on phones

| Platform | Steps |
| --- | --- |
| iPhone | Connect and unlock the phone (Developer Mode on), build with a signing team, `DEVICE_ID=<udid> DEVELOPMENT_TEAM=<team> harness/build-ios-app.sh Release device`, then `harness/run.py ios-device <scenarios>`. The harness installs with `devicectl`, launches each scenario and reads its result from the console. The guided scenarios (`transition`, `offline_start`, `cellular_start`) show instructions on the phone. For the test gateway, run `isolated_gateway --bind <Mac LAN address>`; iOS asks for local network access the first time |
| Android phone | Enable USB debugging, then run `harness/run.py android-device <scenarios> --serial <serial>`. The harness installs the APK for the phone's ABI and reads results over adb |
