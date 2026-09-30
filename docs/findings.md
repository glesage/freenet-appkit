# Findings

What the 1.1 Mobile feasibility and supported profiles runs turned up, as of 2026-09-30. Runs cover a real iPhone 13 mini (iOS 27.0, 4 GB), the iOS Simulator and the Android emulator. Each finding names its evidence and who acts on it next. Result folders are under `results/`.

| # | Finding | Acts next |
| --- | --- | --- |
| 1 | [The iPhone refused Core's Wasm memory reservations](#the-iphone-refused-cores-wasm-memory-reservations) | freenet-core (recommended fix), 1.2 Embedded node and mobile SDK |
| 2 | [The node cannot start offline in network mode](#the-node-cannot-start-offline-in-network-mode) | freenet-core, 1.2 Embedded node and mobile SDK |
| 3 | [The node does not move to cellular on its own](#the-node-does-not-move-to-cellular-on-its-own) | 1.2 Embedded node and mobile SDK |
| 4 | [Phones are full peers on the public network](#phones-are-full-peers-on-the-public-network) | 1.8 Thin-peer role and cellular data budgets |
| 5 | [The peer count stays up during an outage](#the-peer-count-stays-up-during-an-outage) | 1.2 Embedded node and mobile SDK |
| 6 | [Callbacks run on the node's own threads](#callbacks-run-on-the-nodes-own-threads) | 1.2 Embedded node and mobile SDK |
| 7 | [A local update takes about 45 ms](#a-local-update-takes-about-45-ms) | freenet-core |
| 8 | [A persisted config kept gateway flags between profiles](#a-persisted-config-kept-gateway-flags-between-profiles) | Fixed in `crates/mobile` |
| 9 | [32-bit targets did not build](#32-bit-targets-did-not-build) | Fixed in freenet-core |
| 10 | [Core's `--gateway` form](#cores---gateway-form) | Plan 1.1 wording, corrected |
| 11 | [Smaller items](#smaller-items) | Various |

Not run yet: an Android phone and a few network conditions. See [Not run yet](#not-run-yet).

## The iPhone refused Core's Wasm memory reservations

Core reserves 256 MiB of address space for each Wasm linear memory, to match its 256 MiB memory cap, and keeps every reservation until the executor's Store is replaced (after 500 instances, or when retired memory passes a resident-byte budget). The Simulator and emulator stored 300 contracts without trouble, but the iPhone 13 mini refused the 23rd reservation:

```text
execution error: instantiation: mmap failed to reserve 0x10020000 bytes
```

Updating one contract 200 times failed the same way, because every call instantiates the contract again. On this phone River would stop working after about 20 contract calls in a session.

Two ways out were tried on the phone:

| Change | Result on the iPhone |
| --- | --- |
| Reserve only the declared memory plus 1 MiB and let memory move on growth | Crashed with `SIGSEGV` in `Runtime::run_validate_state` as soon as a contract grew its memory past the reservation. Core's host code keeps raw pointers into linear memory across guest calls, so memory must not move |
| Keep the 256 MiB reservation; replace each Store after 4 instances and default to 2 executors on iOS | Every scenario passes: 300 contracts stored, 200 updates at 21.8 per second, footprint 24–27 MiB with River open |

The second change is in the freenet-core working tree as provisional iOS defaults (`STORE_REFRESH_THRESHOLD` and `DEFAULT_RUNTIME_POOL_SIZE_CAP`). It bounds live reservations near 2 GiB.

- Evidence: `results/2026-09-30-ios-device-iphone-13-mini-256mib-reservation` (the default: 22 contracts, throughput failed), the crash report from the phone, and `results/2026-09-30-ios-device-iphone-13-mini` (the provisional limits).
- Next: 1.2 Embedded node and mobile SDK keeps the provisional limits until the upstream fix below lands, then sets the final limits from a new run.

### Recommendation: Core re-reads the memory address after each guest call

A reservation is address space, not RAM. Each contract or delegate instance has one linear memory, and today it reserves the full 256 MiB for it up front, even when the contract uses about 1 MiB. The phone runs out of address space because many instances each hold 256 MiB: every call creates a new instance, and old instances keep their reservation until the Store is replaced. The 2 GiB bound therefore limits how many instances run at once (about 8). Stored data lives in the node's store on disk and is measured by the `storage` scenario.

The recommended fix changes how much address space each instance claims up front. Each instance keeps one memory with the same 256 MiB limit:

| | Today | With the fix |
| --- | --- | --- |
| Address space claimed per instance | 256 MiB, up front | What the contract uses, plus a little room to grow |
| A contract that grows past that | Grows in place, inside its 256 MiB | wasmtime moves the memory to a bigger block and copies it. Core looks up the new address |
| Largest memory per contract | 256 MiB | 256 MiB |
| Instances that fit on the iPhone | About 22 at once | Hundreds, each taking only what it uses |

For this to work, Core looks up the memory address again after each contract and delegate call. Today it looks up the address before the call and reads the result through it afterwards. In `run_validate_state` (`crates/core/src/wasm_runtime/contract.rs`) it looks up the address at line 132, runs the contract at line 141 and reads the result at line 154. Host functions that the guest calls already look up the address again (`refresh_mem_addr_from_caller` in `engine/wasmtime_engine.rs`).

| Option | Effect |
| --- | --- |
| **Core looks up the memory address again after each contract and delegate call (recommended)** | Memory can move, so each reservation shrinks to what the instance uses, on every platform. iOS then uses the same Store replacement as other platforms. Each growth copies the memory |
| Apple's extended virtual addressing entitlement | Raises the iOS limit; reservations still pile up. Adds an entitlement for App Review to check |
| A lower memory cap on iOS | More instances fit; a contract that needs more memory fails only on iOS |

256 MiB per contract covers the contracts measured here, which use about 1 MiB. A contract that needs more is served by raising Core's memory cap, which applies to every platform. On a phone that larger memory is also real RAM, and iOS and Android close apps that use too much, so such a contract belongs on desktop nodes.

The recommended change fixes the cause in Core. To confirm it on the iPhone, re-run the 300-contract and 200-update runs with the "declared memory plus 1 MiB" setting from the table above and Core's default Store replacement. The fix is confirmed when both runs pass.

## The node cannot start offline in network mode

Core builds its DNS resolver and resolves every gateway hostname when it builds the node, and aborts the build when that fails. With no network, a node in network mode therefore cannot start at all, even when its store holds everything River needs.

| Platform | Result with no network |
| --- | --- |
| iPhone 13 mini, Airplane Mode | Failed in 27 ms: `node configuration: protocol error: no ServerAddresses key in DNS info`. The node started and had its first peer 2.3 s after Airplane Mode was turned off |
| Android emulator, Wi-Fi and cellular off | Failed. After the gateway list was cached, the fallback resolver (hickory with `system-config`) panicked: `android context was not initialized`. The mobile runtime contained the panic, so the app kept running and reported the error |

- Evidence: `offline_start` in `results/2026-09-30-ios-device-iphone-13-mini-public`; the Android emulator runs.
- Why it matters: Alice cannot open River on the subway and read "Skate club" from her phone's own copy.
- Cause: `NodeConfig::new` resolves each gateway hostname once, with `parse_socket_addr(address).await?` (`crates/core/src/node.rs`), and stores only the resulting IP address and port. The `?` aborts the build on the first hostname that does not resolve. When the OS lookup fails, `parse_socket_addr` falls back to a hickory resolver, and building that resolver reads the OS DNS settings: offline, iOS has no DNS servers and Android has no Android context. The join loop after it already retries each gateway with exponential backoff (`operations/connect.rs`), so only this startup step needs the network.
- Recommended fix (freenet-core): resolve gateways lazily. Keep a gateway that does not resolve as a hostname entry instead of failing the build, and resolve it inside the join loop before each connection attempt, reusing the loop's backoff. The node then starts offline, serves its stored contracts, and joins once the network is back. The same change should build the hickory fallback only when an online OS lookup has failed, and drop hickory's `system-config` on Android, which removes the panic.

## The node does not move to cellular on its own

On the iPhone, Wi-Fi was turned off in Control Center while the node ran with 15 peers. For the 90 s on cellular the node received 228 bytes and sent 20 KiB, while it went on reporting 16 peers: its connections stayed on the Wi-Fi addresses and nothing reconnected. Within 18 s of Wi-Fi returning it was at 26 peers.

A fresh start on cellular does work. With Wi-Fi off, the node started in 3.1 s and reached its first peer through the carrier's NAT 5.6 s after the start, then exchanged about 11 KiB each way in 30 s.

- Evidence: `transition` and `cellular_start` in `results/2026-09-30-ios-device-iphone-13-mini-public`. iOS reported the cellular path as expensive.
- Next: 1.2 Embedded node and mobile SDK already plans to rejoin the network on a network change. These runs show it must: watch `NWPathMonitor` (and `ConnectivityManager` on Android) and restart the node's transport when the path changes, since Core does not notice by itself.

## Phones are full peers on the public network

On Wi-Fi the iPhone's node reached 27 peers within two minutes and moved 7.2 MB up and 6.4 MB down in that time, about 60 KiB/s each way. The emulator showed the same pattern (22 peers, about 22 KiB/s). Idle runs with one or two peers used under 1.3 KiB/s each way.

- Evidence: `offline_start` and `transition` before the network change on the iPhone; `watch-wifi-toggle` on the emulator; `watch` runs.
- Why it matters: cellular data and battery.
- Next: 1.8 Thin-peer role and cellular data budgets. The harness's `watch` scenario and Core's transport counters (exposed as `node_traffic`) give it per-workload upload and download bytes.

## The peer count stays up during an outage

With every network off for 90 s on the emulator, Core kept reporting its 3 peers the whole time; new peers joined 15 s after the network returned. The iPhone showed the same on cellular (finding 3).

- Evidence: `watch-offline` in the emulator's `public-long-outage` and `public` runs.
- Why it matters: the SDK cannot use the peer count to tell the app it is offline or to decide when to reconnect.
- Next: 1.2 Embedded node and mobile SDK drives its reconnect from the OS path monitor.

## Callbacks run on the node's own threads

Subscription callbacks run on the node runtime's worker threads. A slow Kotlin listener (it hex-encoded each 12 KB state) delayed notifications by several seconds, and in one release run an update got no reply within 30 s. With a listener that only counts, the same run delivers every notification on time.

- Evidence: the first Android `throughput` runs, before the counting listener.
- Next: 1.2 Embedded node and mobile SDK delivers every callback on the platform's own executor, as its owned API already requires. The runtime's threads should never run app code.

## A local update takes about 45 ms

One writer sending updates back to back reaches about 21 updates per second on the Mac (21.5), the iPhone (21.8), the iOS Simulator (20.6) and the Android emulator (22.3): about 45 ms per update, whatever the device. The node log shows a broadcast retry scheduled for every update on a node with no peers.

- Evidence: `throughput` on both platforms; `throughput_probe` on the Mac.
- Next: check upstream whether the update reply waits on that broadcast. It caps how fast one screen can send, though several contracts or writers can overlap.

## A persisted config kept gateway flags between profiles

Core only ever turns `skip_load_from_network` and `is_gateway` on from `config.toml`. After a run through gateway overrides, a later start meant for the public gateway index kept the flag, so it never fetched the index and failed with "Cannot initialize node without gateways".

- Fixed: `crates/mobile` now discards the persisted config when the data directory, mode or gateway source changes (`settings::tests::a_config_written_with_other_gateways_is_discarded`). This extends the prototype learning about discarding a stale config.

## 32-bit targets did not build

`MAX_DEFAULT_MODULE_CACHE_BUDGET_BYTES = 4096 * 1024 * 1024` overflows `usize` on 32-bit targets, so Core did not compile for armeabi-v7a.

- Fixed in the freenet-core working tree: the ceiling is now 4 GiB on 64-bit targets and a quarter of the address space on 32-bit ones. With that change the whole crate builds for `armv7-linux-androideabi`.

## Core's `--gateway` form

Core's `--gateway` option takes `ip:port,hex-public-key` strings. (The hidden `--gateways` option takes JSON that names a public-key file, and Core reads it only with `skip_load_from_network`.) `crates/mobile` accepts `{address, public_key_hex}` records and passes them to `--gateway`, with IP addresses only, so an override never needs DNS. Plan 1.1's learnings table now says the same, and adds the gateway source to the stale-config check (finding 8).

## Smaller items

| Item | Detail |
| --- | --- |
| Stable web origin | A new random port each launch would give the node's shell page a new origin, losing its web storage (the per-app alert consent). The node tries the last port first and reports the port it got. Core's listener closes a moment after the node's tasks end, so stop waits until the port is free again |
| Loading cached apps | The host waits for a peer before loading River even when the store holds it, which adds about 0.5 s on the public network. 1.3 Single-application host can load stored containers first |
| Traffic in a two-node network | Through the isolated gateway, loading River downloaded 1.7–3.7 MiB and uploaded up to 1.1 MiB for a 1.06 MB archive. On the public network the same load downloaded 1.2 MiB and uploaded 9 KiB |
| Telemetry | Core sends telemetry by default; `crates/mobile` turns it off |
| Core's local mode | Installs a Ctrl-C handler (which deletes the config directories in debug builds) and has no shutdown handle. `crates/mobile` runs its local mode as an isolated gateway in Core's network mode |
| Graceful stop | Core prints "CRITICAL: Network event listener exited: Graceful shutdown" to stderr on every normal stop |
| Kotlin error field | A UniFFI error field named `message` clashes with Kotlin's `Throwable.message`; the field is `detail` |
| Emulator timing | Emulator timings vary by up to three times between runs of the same build, so device limits come from phones |
| Idle screen lock | A locked iPhone refuses the harness's next launch, so the demo keeps the screen on during harness runs |

## Not run yet

| Item | Why | How to run it |
| --- | --- | --- |
| Android phone | No Android phone was available; every Android result so far is from the emulator. We may run this later | Connect a phone with USB debugging and run `harness/run.py android-device all --profile local`, then the public and guided network scenarios |
| Battery | The iPhone was on USB power for every run | An unplugged session over wireless debugging, reading battery level before and after |
| UDP-filtering network | Needs a network that blocks UDP | Run `watch` and `river --fresh` on such a network |
| LAN test gateway on the iPhone | Needs the phone and Mac on one Wi-Fi and a tap on the local network prompt | `isolated_gateway --bind <Mac LAN address>`, then `harness/run.py ios-device river --profile gateway --gateway <address>,<key>` |
| Cold start after a reboot | Needs a phone reboot | Reboot, then run `startup` |

