# Distribution review

A review of the complete iOS and Android demo packages against App Store and Google Play policy, as of 2026-09-30. Policy sources were read that day (App Review Guidelines of June 8, 2026; Apple Developer Program License Agreement of August 18, 2026; Google Play policy pages as published that day).

**Review result: not submitted yet.** Neither package has gone to App Review or a Play review track. The next step is a TestFlight build and a Play internal-testing build, which need the project's developer accounts. The tables below are the assessment to take into that submission.

## What the packages contain

| Item | iOS package | Android package |
| --- | --- | --- |
| App code | SwiftUI app and the `freenet-mobile` static library (43.9 MB stripped, 17.6 MB zipped) | Kotlin app and `libfreenet_mobile.so` per ABI (arm64-v8a APK 42.9 MB) |
| Downloaded website content | River's and Atlas's website containers (HTML, JavaScript, CSS and Wasm for the web UI), fetched from the network and served on `127.0.0.1` | Same |
| Contract and delegate Wasm | River's room contract and chat delegate, fetched from the network and run by the node | Same |
| Interpreter | wasmtime's Pulley interpreter; no executable memory | Cranelift compiles Wasm to native code at run time on arm64-v8a and x86_64; Pulley on armeabi-v7a |
| Signing | Development builds signed with a personal team (run on an iPhone 13 mini, iOS 27.0); no distribution certificate yet | Release APK signed with the debug key, for local runs only |
| Entitlements and permissions | No entitlements. Info.plist: `NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription`, `UIFileSharingEnabled` (for collecting results) | `INTERNET`, `ACCESS_NETWORK_STATE`; cleartext allowed only to `127.0.0.1`, `localhost` and `appkit.bundle`; `profileable` for the shell |
| Lifecycle | The node runs only in the foreground; in-app alerts only while open; no background modes and no push | Same; no foreground service |

## App Store

| Item | Rule | Source | Assessment | Change needed |
| --- | --- | --- | --- | --- |
| Downloaded website content | Downloaded code may not add or change the app's features. Interpreted code may be downloaded if it keeps the app's advertised purpose and does not create a storefront. HTML5 mini apps need moderation, consent, an index, an age gate and Apple's permission before they reach native APIs | [Guidelines](https://developer.apple.com/app-store/review/guidelines/) 2.5.2 and 4.7; [DPLA](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) 3.3.1(B) | Risk | Ship as a River app with pinned website and contract keys. Keep the bridge to node calls. Ask before the first large download, stating its size (Guidelines 4.2.3). Explain the node and the interpreter in the review notes |
| Contract and delegate Wasm | Same rules as above | Same | Risk, as above | Pin the allowed code hashes; run only River's and Atlas's pinned contracts and delegates |
| Interpreter use | Just-in-time compilation is only for approved browser engines in the EU and Japan, through BrowserEngineKit | DPLA 3.3.1(B); [alternative browser engines](https://developer.apple.com/support/alternative-browser-engines/) | Fits: Pulley maps no executable memory | CI check that the iOS build has no Cranelift native backend and requests no JIT entitlement |
| Web content | Apps that browse the web must use WebKit | Guidelines 2.5.6 | Fits: WKWebView | None |
| Signing | Distribution certificate and provisioning profile | App Store Connect | Not done | Set up the team and a bundle ID the project owns |
| Entitlements and permissions | Outgoing connections to local-network addresses show a one-time prompt; loopback should not | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | Needs a change for LAN gateways | Keep `NSLocalNetworkUsageDescription`, retry the first LAN send after the prompt, and test on a device (the Simulator has no local-network privacy). Remove `UIFileSharingEnabled` from store builds |
| Lifecycle | Background services only for their stated purpose; no excessive battery use | Guidelines 2.5.4 and 2.4.2 | Fits: foreground only | None |
| Encryption export | App Store Connect asks which encryption the app uses. Standard algorithms outside the OS need a French declaration for France and may need a US year-end self-classification report | [Export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) | Needs a decision | Declare standard algorithms (X25519, AES-GCM, ChaCha20, Ed25519, BLAKE3); decide on France and the US report |
| User-generated content | Filtering, reporting with timely answers, blocking, and published contact details | Guidelines 1.2 | Needs a change: River is a chat app | In-app reporting to a monitored inbox, blocking (hide locally, owner ban), a default filter and a support URL |

## Google Play

| Item | Rule | Source | Assessment | Change needed |
| --- | --- | --- | --- | --- |
| Downloaded website content | Apps may not download executable code, except "code that runs in a virtual machine or an interpreter" with only indirect access to Android APIs, such as JavaScript in a WebView | [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379) | Fits | None beyond the pinned keys |
| Contract and delegate Wasm | Same rule; run-time code must not enable policy violations | Same | Fits in our reading: Wasm runs in wasmtime with host imports only | Pin the allowed code hashes |
| Interpreter use | Same rule | Same | Pulley fits plainly. Cranelift generates native code inside the Wasm virtual machine, which matches the WebView JavaScript example, but that is our reading | Decide per ABI (see below) |
| Signing | Upload key and Play App Signing | Play Console | Not done | Create the upload key; the debug key is for local runs only |
| Entitlements and permissions | New apps and updates must target API 36 or later since August 31, 2026. Native code must support 16 KB pages; updates without it are blocked from February 1, 2027. LAN traffic needs `ACCESS_LOCAL_NETWORK` from target API 37 | [Target API](https://support.google.com/googleplay/android-developer/answer/11926878); [page sizes](https://developer.android.com/guide/practices/page-sizes); [local network](https://developer.android.com/privacy-and-security/local-network-permission) | Fits: targetSdk 36, 16 KB-aligned libraries, run on a 16 KB emulator | CI: `zipalign -c -P 16`; add `ACCESS_LOCAL_NETWORK` when targeting API 37 with LAN gateways |
| Lifecycle | No rule applies to a foreground-only node | – | Fits | None |
| WebView bridge | A WebView with a JavaScript interface that loads untrusted `http://` content is a listed violation | [Malware policy](https://support.google.com/googleplay/android-developer/answer/9888380) | Fits: the bridge uses origin-checked `addWebMessageListener`, not `addJavascriptInterface` | Keep it that way |
| Listening on loopback | No rule on loopback listeners; proxying for third parties is allowed only as the app's main purpose | Device and Network Abuse | Risk while phones relay as full peers | 1.8 Thin-peer role and cellular data budgets |
| User-generated content | Terms before posting, in-app reporting and blocking, action on reports; social and anonymous chat apps also publish child-safety standards | [UGC](https://support.google.com/googleplay/android-developer/answer/9876937); [child safety](https://support.google.com/googleplay/android-developer/answer/14747720) | Needs a change | The App Store features above, plus a terms screen before the first post |
| Data safety | Declare data sent off the device, including by libraries and WebViews whose code you control; end-to-end encrypted data is exempt | [Data safety](https://support.google.com/googleplay/android-developer/answer/10787469) | Needs a decision | Declare messages, user IDs and IP addresses sent to peers unless end-to-end encrypted; declare encryption in transit |

## Decisions before submission

| Decision | Options |
| --- | --- |
| App scope | A River app with pinned keys, or a general Freenet host. A general host adds the mini-app index, age gate and moderation for every app |
| Android backend per ABI | Cranelift on arm64-v8a and x86_64 relies on our reading of Play's interpreter exception; Pulley everywhere is the cautious choice. The emulator's compute case ran 3 to 16 times slower under Pulley, so phones should measure the cost first |
| Encryption export | Distribute in France or not; file the US report or not |
| Moderation | Who reads reports, how fast they are answered, and what removal means when content lives on peers |
| Peer role | Thin peer (1.8 Thin-peer role and cellular data budgets), or a full peer with relaying declared as a main purpose |
| LAN gateways in release builds | Skip private addresses, or accept the iOS prompt and request `ACCESS_LOCAL_NETWORK` on Android |
