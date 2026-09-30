package org.freenet.appkit.demo

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.freenet.appkit.NodeDirectories
import org.freenet.mobile.GatewayOverride
import org.freenet.mobile.LifecyclePhase
import org.freenet.mobile.MobileNode
import org.freenet.mobile.NodeEvent
import org.freenet.mobile.NodeEventListener
import org.freenet.mobile.NodeInfo
import org.freenet.mobile.NodeMode
import org.freenet.mobile.NodeSettings
import org.freenet.mobile.NodeStatus
import org.freenet.mobile.WasmBackendChoice
import org.freenet.mobile.connectClient

const val TAG = "AppKitDemo"

/** How the demo's node reaches other peers. */
enum class NetworkProfile(val key: String, val label: String) {
    /** An isolated node on the phone, with River and Atlas preloaded. */
    LOCAL("local", "Local (offline)"),
    /** Network mode through a gateway override, such as the test gateway on the Mac. */
    GATEWAY("gateway", "Test gateway"),
    /** Network mode through the public gateway index. */
    PUBLIC("public", "Public network");

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: PUBLIC
    }
}

/** A web app the demo loads from a website container. */
enum class DemoWebApp(val title: String, val instanceId: String, val resourceName: String) {
    RIVER("River", "raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv", "river"),
    ATLAS("Atlas", "771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9", "atlas"),
}

/** A foreground message alert from a web app. */
data class InAppAlert(val id: String, val title: String, val body: String, val app: DemoWebApp, val open: () -> Unit)

/** The user's answer to "show message alerts". */
enum class AlertGrant(val key: String) {
    NOT_ASKED("default"), GRANTED("granted"), DENIED("denied");

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: NOT_ASKED
    }
}

/**
 * Owns the embedded node for the whole app and runs it only while the app is
 * in the foreground.
 */
object NodeHost {
    lateinit var directories: NodeDirectories
        private set
    private lateinit var prefs: android.content.SharedPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var node: MobileNode? = null
        private set
    var info: NodeInfo? = null
        private set
    var status: NodeStatus? = null
        private set
    var lastError: String? = null
        private set
    /** Increases on every fresh session, so web views reload with new authority. */
    var sessionGeneration = 0
        private set
    val lifecycleLog = mutableListOf<String>()

    private val eventSinks = mutableMapOf<String, (NodeEvent) -> Unit>()
    private val lifecycleSinks = mutableMapOf<String, (LifecyclePhase) -> Unit>()
    private val stateListeners = mutableListOf<() -> Unit>()
    private val preloaded = mutableSetOf<String>()
    var alertPresenter: ((InAppAlert) -> Unit)? = null

    fun init(context: Context) {
        if (::directories.isInitialized) return
        directories = NodeDirectories.standard(context.applicationContext)
        prefs = context.applicationContext.getSharedPreferences("appkit", Context.MODE_PRIVATE)
    }

    var profile: NetworkProfile
        get() = NetworkProfile.of(prefs.getString("profile", null))
        set(value) = prefs.edit().putString("profile", value.key).apply()

    var gatewayText: String
        get() = prefs.getString("gateway", "") ?: ""
        set(value) = prefs.edit().putString("gateway", value).apply()

    var alertGrant: AlertGrant
        get() = AlertGrant.of(prefs.getString("alerts", null))
        set(value) = prefs.edit().putString("alerts", value.key).apply()

    var backend: String?
        get() = prefs.getString("backend", null)
        set(value) = prefs.edit().putString("backend", value).apply()

    val gatewayOverrides: List<GatewayOverride>
        get() = gatewayText.split('\n', ';').mapNotNull { line ->
            val parts = line.split(',').map { it.trim() }
            if (parts.size == 2) GatewayOverride(parts[0], parts[1]) else null
        }

    private val backendChoice: WasmBackendChoice?
        get() = when (backend) {
            "cranelift" -> WasmBackendChoice.CRANELIFT
            "pulley" -> WasmBackendChoice.PULLEY
            else -> null
        }

    fun settings(profile: NetworkProfile): NodeSettings {
        val last = prefs.getInt("lastPort", 0)
        val port = if (last == 0) null else last.toUShort()
        return when (profile) {
            NetworkProfile.LOCAL -> directories.settings(NodeMode.LOCAL, preferredWsPort = port, wasmBackend = backendChoice)
            NetworkProfile.GATEWAY -> directories.settings(NodeMode.NETWORK, gatewayOverrides, port, backendChoice)
            NetworkProfile.PUBLIC -> directories.settings(NodeMode.NETWORK, preferredWsPort = port, wasmBackend = backendChoice)
        }
    }

    fun onChange(listener: () -> Unit) {
        stateListeners.add(listener)
    }

    private fun changed() = stateListeners.forEach { it() }

    private fun currentNode(): MobileNode {
        node?.let { return it }
        val created = MobileNode(settings(profile))
        created.setListener(object : NodeEventListener {
            override fun onEvent(event: NodeEvent) {
                scope.launch { handle(event) }
            }
        })
        node = created
        return created
    }

    /** Start the node for the current profile. Repeated calls return the running node. */
    suspend fun start(): NodeInfo? = try {
        val node = currentNode()
        val started = node.start()
        info = started
        status = node.status()
        lastError = null
        prefs.edit().putInt("lastPort", started.wsPort.toInt()).apply()
        log("started session ${started.session} on port ${started.wsPort} in ${started.timings.totalMs.toInt()} ms")
        changed()
        started
    } catch (e: Exception) {
        lastError = e.message ?: e.toString()
        log("start failed: $lastError")
        changed()
        null
    }

    suspend fun stop() {
        val node = node ?: return
        try {
            node.stop()
            log("stopped")
        } catch (e: Exception) {
            lastError = e.message
        }
        info = null
        status = node.status()
        changed()
    }

    /** Switch profile: stop the node, then start one with the new settings. */
    suspend fun apply(newProfile: NetworkProfile) {
        stop()
        node?.setListener(null)
        node?.destroy()
        node = null
        preloaded.clear()
        profile = newProfile
        start()
        sessionGeneration += 1
        changed()
    }

    /** The app moved to the background: tell pages, then stop the node. */
    fun onBackground() {
        log("backgrounding")
        lifecycleSinks.values.forEach { it(LifecyclePhase.BACKGROUNDING) }
        scope.launch { stop() }
    }

    /** The app is in the foreground again: start a fresh session. */
    fun onForeground() {
        scope.launch {
            val wasRunning = info != null
            start()
            if (!wasRunning) {
                sessionGeneration += 1
                lifecycleSinks.values.forEach { it(LifecyclePhase.RESUMED) }
                log("resumed with a fresh session")
                changed()
            }
        }
    }

    private fun handle(event: NodeEvent) {
        node?.let { status = it.status() }
        eventSinks.values.forEach { it(event) }
        changed()
    }

    fun addEventSink(sink: (NodeEvent) -> Unit): String = UUID.randomUUID().toString().also { eventSinks[it] = sink }

    fun addLifecycleSink(sink: (LifecyclePhase) -> Unit): String =
        UUID.randomUUID().toString().also { lifecycleSinks[it] = sink }

    fun removeSink(id: String) {
        eventSinks.remove(id)
        lifecycleSinks.remove(id)
    }

    /** Wait for a peer in network mode. Local mode has none to wait for. */
    suspend fun waitForPeers(timeoutMs: Long = 60_000): Boolean {
        val node = node ?: return false
        if (profile == NetworkProfile.LOCAL) return true
        return try {
            node.waitForPeers(1u, timeoutMs.toULong())
            status = node.status()
            true
        } catch (e: Exception) {
            lastError = e.message
            false
        }
    }

    /** In local mode, store the app's website container from the assets. */
    suspend fun preloadIfLocal(context: Context, app: DemoWebApp) {
        val info = info ?: return
        if (profile != NetworkProfile.LOCAL || app.instanceId in preloaded) return
        val client = connectClient(info.wsPort)
        try {
            client.get(app.instanceId, false, false, 10_000u)
        } catch (e: Exception) {
            val files = AppResources.webapp(context, app.resourceName)
            client.put(files.code, files.params, files.state, false, 60_000u)
        }
        client.destroy()
        preloaded.add(app.instanceId)
    }

    fun webUrl(app: DemoWebApp): String? = try {
        node?.webUrl(app.instanceId)
    } catch (e: Exception) {
        null
    }

    fun present(alert: InAppAlert) {
        alertPresenter?.invoke(alert)
    }

    fun log(line: String) {
        val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        lifecycleLog.add("$stamp $line")
        while (lifecycleLog.size > 50) lifecycleLog.removeAt(0)
        Log.i(TAG, line)
    }
}

/** Files `scripts/prepare-resources.sh` copies into the APK's assets. */
object AppResources {
    class Webapp(val code: ByteArray, val params: ByteArray, val state: ByteArray)

    fun bytes(context: Context, path: String): ByteArray =
        context.assets.open("AppKitResources/$path").use { it.readBytes() }

    fun text(context: Context, path: String) = String(bytes(context, path), Charsets.UTF_8)

    fun webapp(context: Context, name: String) = Webapp(
        bytes(context, "webapps/$name.code.wasm"),
        bytes(context, "webapps/$name.params"),
        bytes(context, "webapps/$name.state"),
    )

    fun protocolFixtures(context: Context) = text(context, "protocol-fixtures.json")

    /**
     * A web bundle is a directory with its manifest, so the bridge test bundle is
     * copied out of the APK before the host opens and verifies it.
     */
    fun bridgeTestBundle(context: Context): File {
        val dir = File(context.filesDir, "bundles/bridge-test")
        dir.deleteRecursively()
        dir.mkdirs()
        val names = context.assets.list("AppKitResources/bridge-test") ?: emptyArray()
        for (name in names) {
            File(dir, name).writeBytes(bytes(context, "bridge-test/$name"))
        }
        return dir
    }

    fun conformanceModules(context: Context): List<org.freenet.mobile.NamedModule> = listOf(
        "river_room_contract" to "contracts/river-room-contract.wasm",
        "atlas_index_contract" to "contracts/atlas-index-contract.wasm",
        "web_container_contract" to "webapps/river.code.wasm",
    ).mapNotNull { (name, path) ->
        try {
            org.freenet.mobile.NamedModule(name, bytes(context, path), ByteArray(0))
        } catch (e: Exception) {
            null
        }
    }
}
