package org.freenet.appkit.demo

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import kotlinx.coroutines.delay
import org.freenet.mobile.buildInfoJson
import org.freenet.mobile.conformanceReportJson
import org.freenet.mobile.directorySizeBytes
import org.freenet.mobile.fixtureReportJson
import org.freenet.mobile.nodeInfoJson
import org.freenet.mobile.nodeStatusJson
import org.freenet.mobile.nodeTraffic
import org.freenet.mobile.processMetrics
import org.freenet.mobile.processMetricsJson
import org.freenet.mobile.runBackendConformance
import org.freenet.mobile.verifyFixtures
import org.json.JSONArray
import org.json.JSONObject

/**
 * Runs a measurement scenario chosen by intent extras and writes its result:
 *
 *     adb shell am start -W -S -n org.freenet.appkit.demo/.MainActivity \
 *         --es appkit.scenario conformance --ez appkit.exitWhenDone true
 *
 * The result goes to `files/appkit-results/<scenario>.json` (and the same path
 * in the app's external files directory, readable over adb for release
 * builds). The iOS demo writes the same fields.
 */
object Harness {
    val scenarios = listOf("conformance", "fixtures", "native", "startup", "lifecycle", "bridge", "river", "atlas", "storage")

    /** Scenarios that need the real foreground lifecycle while they run. */
    val lifecycleScenarios = setOf("resume")

    var appInitUptimeMs: Long = 0
    var firstFrameUptimeMs: Long = 0

    suspend fun run(activity: MainActivity, scenario: String): JSONObject {
        val context = activity.applicationContext
        val out = JSONObject()
            .put("scenario", scenario)
            .put("platform", "android")
            .put("device", deviceInfo(context))
            .put("build", JSONObject(buildInfoJson()))
            .put("profile", NodeHost.profile.key)
            .put("started_at_ms", System.currentTimeMillis().toDouble())
        try {
            when (scenario) {
                "conformance" -> {
                    val report = runBackendConformance(AppResources.conformanceModules(context), true)
                    out.put("passed", report.passed).put("result", JSONObject(conformanceReportJson(report)))
                }
                "fixtures" -> {
                    val expected = AppResources.protocolFixtures(context)
                    val report = FixtureNode.run(context) { info -> verifyFixtures(expected, info.wsPort) }
                    out.put("passed", report.passed).put("result", JSONObject(fixtureReportJson(report)))
                }
                "native" -> {
                    val checks = NativeRoute.run(context, expectedFixtureValues(context))
                    val samples = NativeRoute.largeRecords(context, listOf(16 shl 10, 256 shl 10, 1 shl 20, 4 shl 20, 16 shl 20, 32 shl 20))
                    val intact = (0 until samples.length()).all { samples.getJSONObject(it).getBoolean("intact") }
                    out.put("passed", checks.all { it.passed } && intact)
                        .put("result", JSONObject()
                            .put("checks", JSONArray(checks.map { it.json() }))
                            .put("large_records", samples))
                }
                "startup" -> out.put("result", startup())
                "lifecycle" -> out.put("result", lifecycle())
                "bridge" -> {
                    val report = bridge(activity)
                    out.put("passed", report.optBoolean("passed")).put("result", report)
                }
                "river" -> out.put("result", webApp(activity, DemoWebApp.RIVER))
                "atlas" -> out.put("result", webApp(activity, DemoWebApp.ATLAS))
                "storage" -> out.put("result", storage())
                "watch" -> out.put("result", watch(activity))
                "resume" -> out.put("result", resume(activity))
                "throughput" -> {
                    val result = throughput(context)
                    out.put("passed", !result.has("error")).put("result", result)
                }
                "alerts" -> {
                    val result = alerts(activity)
                    out.put("passed", result.optBoolean("opened")).put("result", result)
                }
                "wasm_instances" -> {
                    val result = wasmInstances(context)
                    out.put("passed", !result.has("error")).put("result", result)
                }
                else -> out.put("error", "unknown scenario $scenario")
            }
        } catch (e: Exception) {
            Log.e(TAG, "scenario $scenario failed", e)
            out.put("error", e.toString()).put("passed", false)
        }
        out.put("finished_at_ms", System.currentTimeMillis().toDouble())
        out.put("metrics", JSONObject(processMetricsJson(processMetrics())))
        return out
    }

    private suspend fun startup(): JSONObject {
        val processStart = Process.getStartUptimeMillis()
        val result = JSONObject()
            .put("process_to_app_init_ms", (appInitUptimeMs - processStart).toDouble())
            .put("process_to_first_frame_ms", (firstFrameUptimeMs - processStart).toDouble())
        NodeHost.stop()
        var started = SystemClock.elapsedRealtimeNanos()
        val cold = NodeHost.start() ?: error(NodeHost.lastError ?: "start failed")
        result.put("node_first_start_ms", (SystemClock.elapsedRealtimeNanos() - started) / 1e6)
            .put("node_first_start", JSONObject(nodeInfoJson(cold)))
        started = SystemClock.elapsedRealtimeNanos()
        NodeHost.stop()
        result.put("node_stop_ms", (SystemClock.elapsedRealtimeNanos() - started) / 1e6)
        started = SystemClock.elapsedRealtimeNanos()
        val warm = NodeHost.start() ?: error(NodeHost.lastError ?: "restart failed")
        result.put("node_restart_ms", (SystemClock.elapsedRealtimeNanos() - started) / 1e6)
            .put("node_restart", JSONObject(nodeInfoJson(warm)))
        return result
    }

    private suspend fun lifecycle(): JSONObject {
        val first = NodeHost.start() ?: error(NodeHost.lastError ?: "start failed")
        var session = first.session
        val cycles = JSONArray()
        repeat(3) {
            var t = SystemClock.elapsedRealtimeNanos()
            NodeHost.stop()
            val stopMs = (SystemClock.elapsedRealtimeNanos() - t) / 1e6
            val stoppedState = NodeHost.node?.status()?.state?.name?.lowercase() ?: "none"
            t = SystemClock.elapsedRealtimeNanos()
            val next = NodeHost.start() ?: error(NodeHost.lastError ?: "restart failed")
            cycles.put(JSONObject()
                .put("stop_ms", stopMs)
                .put("state_after_stop", stoppedState)
                .put("start_ms", (SystemClock.elapsedRealtimeNanos() - t) / 1e6)
                .put("previous_session", session.toLong())
                .put("session", next.session.toLong())
                .put("fresh_session", next.session > session)
                .put("same_port", next.wsPort == first.wsPort))
            session = next.session
        }
        return JSONObject().put("cycles", cycles)
    }

    private suspend fun bridge(activity: MainActivity): JSONObject {
        activity.select(MainActivity.Tab.BRIDGE, autorun = true)
        val deadline = System.currentTimeMillis() + 60_000
        while (activity.bridgeReport() == null && System.currentTimeMillis() < deadline) delay(100)
        return activity.bridgeReport() ?: error("the bridge page sent no report")
    }

    private fun traffic(): Pair<Long, Long> = nodeTraffic().let { it.uploadBytes.toLong() to it.downloadBytes.toLong() }

    private fun trafficSince(before: Pair<Long, Long>): JSONObject {
        val now = traffic()
        return JSONObject().put("upload_bytes", now.first - before.first).put("download_bytes", now.second - before.second)
    }

    /** Record peer counts and traffic for `appkit.watchSeconds` seconds (default 60). */
    private suspend fun watch(activity: MainActivity): JSONObject {
        val seconds = activity.intent?.getIntExtra("appkit.watchSeconds", 60)?.takeIf { it > 0 } ?: 60
        NodeHost.start()
        NodeHost.waitForPeers(60_000)
        val before = traffic()
        val origin = System.currentTimeMillis()
        val samples = JSONArray()
        repeat(seconds) {
            val status = NodeHost.node?.status()
            val now = traffic()
            samples.put(JSONObject()
                .put("ms", System.currentTimeMillis() - origin)
                .put("peers", status?.connectedPeers?.toLong() ?: 0)
                .put("state", status?.state?.name?.lowercase() ?: "none")
                .put("upload_bytes", now.first - before.first)
                .put("download_bytes", now.second - before.second))
            delay(1000)
        }
        return JSONObject().put("seconds", seconds).put("samples", samples).put("traffic", trafficSince(before))
    }

    /** Open River, then wait while the harness backgrounds the app and brings it back. */
    private suspend fun resume(activity: MainActivity): JSONObject {
        val first = webApp(activity, DemoWebApp.RIVER, sampleSeconds = 0)
        val logStart = NodeHost.lifecycleLog.size
        val deadline = System.currentTimeMillis() + 180_000
        var backgrounded: Long? = null
        var resumedAt: Long? = null
        while (System.currentTimeMillis() < deadline) {
            val entries = NodeHost.lifecycleLog.drop(logStart)
            if (backgrounded == null && entries.any { it.endsWith("backgrounding") }) backgrounded = System.currentTimeMillis()
            if (backgrounded != null && entries.any { it.endsWith("resumed with a fresh session") }) {
                resumedAt = System.currentTimeMillis()
                break
            }
            delay(50)
        }
        val resumed = resumedAt ?: error("the app was not backgrounded and resumed within 180 s")
        activity.select(MainActivity.Tab.RIVER)
        fun reloaded() = WebTimeline.marks(DemoWebApp.RIVER).any { it.event == "title:River" && it.ms > resumed }
        while (System.currentTimeMillis() < deadline && !reloaded()) delay(50)
        val marks = WebTimeline.marks(DemoWebApp.RIVER).filter { it.ms >= resumed - 5_000 }
        return JSONObject()
            .put("first_load", first)
            .put("backgrounded_at_ms", backgrounded)
            .put("resumed_at_ms", resumed)
            .put("after_resume", JSONArray(marks.map { JSONObject().put("event", it.event).put("ms", it.ms - resumed) }))
            .put("session", NodeHost.info?.session?.toLong())
    }

    /** Subscription throughput: one connection subscribes, another sends updates back to back. */
    private suspend fun throughput(context: Context, count: Int = 200): JSONObject = FixtureNode.run(context) { info ->
        val reader = org.freenet.mobile.connectClient(info.wsPort)
        val writer = org.freenet.mobile.connectClient(info.wsPort)
        val put = reader.put(org.freenet.mobile.fixtureContractWasm(), byteArrayOf(0x7A), byteArrayOf(1), false, null)
        val recorder = CountingListener()
        reader.subscribe(put.contract.instanceId, recorder, null)
        val delta = ByteArray(64) { 0x42 }
        val started = System.nanoTime()
        repeat(count) { writer.update(put.contract, delta, 30_000u) }
        val sent = (System.nanoTime() - started) / 1e9
        val deadline = System.currentTimeMillis() + 60_000
        while (recorder.count < count && System.currentTimeMillis() < deadline) delay(10)
        val received = (System.nanoTime() - started) / 1e9
        val got = recorder.count
        reader.destroy()
        writer.destroy()
        JSONObject().put("updates", count).put("delta_bytes", 64).put("received", got)
            .put("send_seconds", sent).put("receive_seconds", received)
            .put("updates_per_second", got / received).put("final_state_bytes", 1 + count * 64)
            .put("notification_bytes", recorder.totalBytes)
            .apply { if (got < count) put("error", "received $got of $count updates") }
    }

    /** Message alerts: the shell page raises a notification, the host shows its banner, a tap reaches the page. */
    private suspend fun alerts(activity: MainActivity): JSONObject {
        NodeHost.alertGrant = AlertGrant.GRANTED
        val loaded = webApp(activity, DemoWebApp.RIVER, sampleSeconds = 0)
        val web = WebViews.byApp[DemoWebApp.RIVER] ?: error("no River web view")
        val shown = kotlinx.coroutines.CompletableDeferred<InAppAlert>()
        val previous = NodeHost.alertPresenter
        NodeHost.alertPresenter = { alert -> previous?.invoke(alert); shown.complete(alert) }
        val raised = System.currentTimeMillis()
        web.evaluateJavascript("""
            (function () {
              var n = new Notification('Bob', { body: 'Skate club: see you at 6?', tag: 'skate-club' });
              n.onclick = function () { window.__appkitProbeClicked = true; };
              return true;
            })()
        """.trimIndent(), null)
        val alert = kotlinx.coroutines.withTimeoutOrNull(10_000) { shown.await() }
        NodeHost.alertPresenter = previous
        alert ?: error("no banner appeared")
        val bannerMs = System.currentTimeMillis() - raised
        alert.open()
        delay(300)
        val clicked = kotlinx.coroutines.CompletableDeferred<Boolean>()
        web.evaluateJavascript("window.__appkitProbeClicked === true") { clicked.complete(it == "true") }
        return JSONObject()
            .put("river_loaded", loaded.optBoolean("loaded"))
            .put("banner_title", alert.title).put("banner_body", alert.body)
            .put("raise_to_banner_ms", bannerMs)
            .put("opened", clicked.await())
            .put("foreground_only", true)
    }

    /** Store contracts until the device refuses or 300 are stored. */
    private suspend fun wasmInstances(context: Context): JSONObject = FixtureNode.run(context) { info ->
        val client = org.freenet.mobile.connectClient(info.wsPort)
        val wasm = org.freenet.mobile.fixtureContractWasm()
        val start = processMetrics().virtualBytes.toLong()
        val samples = JSONArray()
        var stored = 0
        var failure: String? = null
        for (i in 0 until 300) {
            try {
                client.put(wasm, byteArrayOf((i and 0xFF).toByte(), (i shr 8).toByte()), byteArrayOf(1, 2, 3), false, 30_000u)
                stored = i + 1
            } catch (e: Exception) {
                failure = e.message ?: e.toString()
                break
            }
            if (stored % 25 == 0) {
                val m = processMetrics()
                samples.put(JSONObject().put("contracts", stored).put("virtual_bytes", m.virtualBytes.toLong())
                    .put("footprint_bytes", m.footprintBytes?.toLong()))
            }
        }
        val end = processMetrics().virtualBytes.toLong()
        client.destroy()
        JSONObject().put("stored", stored).put("samples", samples)
            .put("virtual_bytes_per_contract", if (stored > 0) (end - start).toDouble() / stored else 0.0)
            .apply { failure?.let { put("error", it) } }
    }

    private suspend fun webApp(activity: MainActivity, app: DemoWebApp, sampleSeconds: Int = 20): JSONObject {
        val before = traffic()
        activity.select(if (app == DemoWebApp.RIVER) MainActivity.Tab.RIVER else MainActivity.Tab.ATLAS)
        val deadline = System.currentTimeMillis() + 180_000
        while (System.currentTimeMillis() < deadline) {
            if (WebTimeline.has(app, "title:${app.title}") && WebTimeline.has(app, "shell_loaded")) break
            if (WebTimeline.has(app, "load_failed")) break
            delay(100)
        }
        val marks = WebTimeline.marks(app)
        val origin = marks.firstOrNull()?.ms ?: System.currentTimeMillis().toDouble()
        val loadTraffic = trafficSince(before)
        val samples = JSONArray()
        repeat(sampleSeconds) {
            samples.put(JSONObject(processMetricsJson(processMetrics())))
            delay(1000)
        }
        return JSONObject()
            .put("timeline", JSONArray(marks.map { JSONObject().put("event", it.event).put("ms", it.ms - origin) }))
            .put("loaded", WebTimeline.has(app, "title:${app.title}"))
            .put("load_traffic", loadTraffic)
            .put("session_traffic", trafficSince(before))
            .put("memory_samples", samples)
            .put("status", NodeHost.node?.let { JSONObject(nodeStatusJson(it.status())) })
    }

    private fun storage(): JSONObject {
        val dirs = NodeHost.directories
        return JSONObject()
            .put("data_bytes", directorySizeBytes(dirs.data.absolutePath).toLong())
            .put("config_bytes", directorySizeBytes(dirs.config.absolutePath).toLong())
            .put("logs_bytes", directorySizeBytes(dirs.logs.absolutePath).toLong())
            .put("cache_bytes", directorySizeBytes(dirs.cache.absolutePath).toLong())
    }

    fun expectedFixtureValues(context: Context): Map<String, String> {
        val values = JSONObject(AppResources.protocolFixtures(context)).getJSONObject("values")
        return values.keys().asSequence().associateWith { values.getString(it) }
    }

    fun write(context: Context, scenario: String, result: JSONObject) {
        val text = result.toString()
        for (base in listOfNotNull(context.filesDir, context.getExternalFilesDir(null))) {
            val dir = File(base, "appkit-results").apply { mkdirs() }
            File(dir, "$scenario.json").writeText(text)
        }
        Log.i("AppKitHarness", "APPKIT_RESULT scenario=$scenario passed=${result.opt("passed")} bytes=${text.length}")
    }

    private fun deviceInfo(context: Context): JSONObject {
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        val emulator = Build.FINGERPRINT.contains("generic") || Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk")
        return JSONObject()
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("name", Build.DEVICE)
            .put("os", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
            .put("simulator", emulator)
            .put("physical_memory_bytes", memory.totalMem)
            .put("cpu_count", Runtime.getRuntime().availableProcessors())
            .put("page_size", android.system.Os.sysconf(android.system.OsConstants._SC_PAGESIZE))
    }
}
