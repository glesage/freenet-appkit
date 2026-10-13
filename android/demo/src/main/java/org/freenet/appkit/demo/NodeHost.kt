package org.freenet.appkit.demo

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.freenet.appkit.NodeDirectories
import org.freenet.mobile.MobileException
import org.freenet.mobile.MobileNode
import org.freenet.mobile.NodeEvent
import org.freenet.mobile.NodeEventListener
import org.freenet.mobile.NodeInfo
import org.freenet.mobile.NodeMode
import org.freenet.mobile.NodeSettings
import org.freenet.mobile.NodeStatus
import org.freenet.mobile.WasmBackendChoice
import org.freenet.mobile.buildInfo

/** A foreground message alert from the hosted app. */
data class InAppAlert(val id: String, val title: String, val body: String, val open: () -> Unit)

/** The user's answer to "show message alerts", kept for the hosted app only. */
enum class AlertGrant(val key: String) {
    NOT_ASKED("default"), GRANTED("granted"), DENIED("denied");

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: NOT_ASKED
    }
}

/**
 * Owns the hosted app's embedded node. The node joins the public network and
 * runs only while the app is in the foreground.
 *
 * One reconciler moves the node towards what the app wants (running in the
 * foreground, stopped in the background), one step at a time, so a start and
 * a stop never interleave. Every stop ends the session: pages and prompts
 * bound to it are discarded before the next session's page loads.
 */
object NodeHost {
    val app = HostedApp.current

    private lateinit var directories: NodeDirectories
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
    /**
     * Increases whenever a session starts or ends, so pages reload with new
     * authority and prompts from the old session close.
     */
    var sessionGeneration = 0
        private set
    /** The device has a usable network. */
    var networkAvailable = true
        private set

    private val stateListeners = mutableListOf<() -> Unit>()
    var alertPresenter: ((InAppAlert) -> Unit)? = null

    /** What the app wants: the node running (foreground) or stopped. */
    private var wantRunning = false
    private var welcomeSeen = false
    private var reconciler: Job? = null
    private val networkRestarts = ArrayDeque<Long>()

    /** At most this many restarts a minute when the network comes back and the node has no peers. */
    private const val MAX_NETWORK_RESTARTS_PER_MINUTE = 2

    fun init(context: Context) {
        if (::directories.isInitialized) return
        val appContext = context.applicationContext
        directories = NodeDirectories.standard(appContext, app.storageFolder)
        prefs = appContext.getSharedPreferences(app.preferences, Context.MODE_PRIVATE)
        welcomeSeen = WelcomeScreen.isSeen(appContext)
        watchNetwork(appContext)
    }

    var alertGrant: AlertGrant
        get() = AlertGrant.of(prefs.getString("alerts", null))
        set(value) = prefs.edit().putString("alerts", value.key).apply()

    /** The node always runs contracts on Pulley. */
    private fun settings(): NodeSettings = directories.settings(
        NodeMode.NETWORK,
        preferredWsPort = preferredPort(),
        wasmBackend = WasmBackendChoice.PULLEY,
    )

    /**
     * The loopback port this installation asks for on every start, so web
     * app storage keeps one origin. Chosen once, before the first start.
     */
    private fun preferredPort(): UShort {
        val saved = prefs.getInt("port", 0)
        if (saved in 1024..65535) return saved.toUShort()
        val port = (49152..65000).random()
        prefs.edit().putInt("port", port).apply()
        return port.toUShort()
    }

    fun onChange(listener: () -> Unit) {
        stateListeners.add(listener)
    }

    fun removeOnChange(listener: () -> Unit) {
        stateListeners.remove(listener)
    }

    private fun changed() = stateListeners.forEach { it() }

    private fun currentNode(): MobileNode {
        node?.let { return it }
        val created = MobileNode(settings())
        created.setListener(object : NodeEventListener {
            override fun onEvent(event: NodeEvent) {
                scope.launch { handle(event) }
            }
        })
        node = created
        return created
    }

    /** The app is in the foreground and past the welcome screen. */
    val wantsNode get() = wantRunning && welcomeSeen

    /**
     * The running session, started if the app wants one. `null` in the
     * background or when the start failed (see [lastError]). Never runs while
     * a stop is in progress.
     */
    suspend fun session(): NodeInfo? {
        info?.let { if (reconciler?.isActive != true) return it }
        reconcile()
        reconciler?.join()
        return info
    }

    private suspend fun startNode(): NodeInfo? = try {
        val node = currentNode()
        val started = node.start()
        if (started.wasmBackend != WasmBackendChoice.PULLEY || WasmBackendChoice.PULLEY !in buildInfo().availableBackends) {
            runCatching { node.stop() }
            lastError = "This build does not run contracts on Pulley (got ${started.wasmBackend})."
            null
        } else {
            info = started
            status = node.status()
            lastError = null
            started
        }
    } catch (e: Exception) {
        lastError = e.message ?: e.toString()
        null
    }

    private suspend fun stopNode() {
        val node = node ?: return
        // The session ends before the stop: nothing bound to it may act.
        if (info != null) sessionGeneration += 1
        info = null
        changed()
        try {
            node.stop()
        } catch (e: MobileException.IncompleteShutdown) {
            lastError = "The node stopped incompletely after ${e.elapsedMs} ms " +
                "(exited: ${e.nodeExited}, port released: ${e.portReleased})."
        } catch (e: Exception) {
            lastError = e.message
        }
        status = node.status()
        changed()
    }

    /** Move the node towards [wantsNode], one step at a time. */
    private fun reconcile() {
        if (reconciler?.isActive == true) return
        reconciler = scope.launch {
            while (true) {
                val running = info != null
                if (wantsNode == running) break
                if (wantsNode) {
                    if (startNode() == null) {
                        changed()
                        break
                    }
                    sessionGeneration += 1
                    changed()
                } else {
                    stopNode()
                }
            }
        }
    }

    /** The user has read the welcome screen: the node may start. */
    fun onWelcomeSeen() {
        welcomeSeen = true
        reconcile()
    }

    /** The app moved to the background: stop the node. */
    fun onBackground() {
        wantRunning = false
        reconcile()
    }

    /** The app is in the foreground again: start a fresh session. */
    fun onForeground() {
        wantRunning = true
        reconcile()
    }

    private fun handle(event: NodeEvent) {
        node?.let { status = it.status() }
        if (event is NodeEvent.Exited) {
            info = null
            sessionGeneration += 1
        }
        changed()
    }

    /**
     * The network came back: the node reconnects by itself, but a node that
     * still has no peers a while later restarts, a bounded number of times.
     */
    private fun watchNetwork(context: Context) {
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return
        networkAvailable = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                scope.launch { networkChanged(true) }
            }

            override fun onLost(network: Network) {
                scope.launch { networkChanged(false) }
            }
        })
    }

    private fun networkChanged(available: Boolean) {
        val cameBack = available && !networkAvailable
        networkAvailable = available
        changed()
        if (!cameBack) return
        scope.launch {
            delay(10_000)
            if (!wantRunning || info == null || (status?.connectedPeers ?: 0u) > 0u) return@launch
            val now = System.currentTimeMillis()
            while (networkRestarts.isNotEmpty() && now - networkRestarts.first() > 60_000) networkRestarts.removeFirst()
            if (networkRestarts.size >= MAX_NETWORK_RESTARTS_PER_MINUTE) return@launch
            networkRestarts.addLast(now)
            stopNode()
            reconcile()
        }
    }

    /** Wait until the node is connected to at least one peer. */
    suspend fun waitForPeers(timeoutMs: Long = 60_000): Boolean {
        val node = node ?: return false
        return try {
            node.waitForPeers(1u, timeoutMs.toULong())
            status = node.status()
            true
        } catch (e: Exception) {
            lastError = e.message
            false
        }
    }

    /**
     * The node unpacked this app's website container on an earlier visit, so
     * it can serve the page before it joins the network.
     */
    val hasSavedPage: Boolean
        get() {
            val cache = File(directories.cache, "network/webapp_cache")
            return cache.list()?.any { it.startsWith(app.instanceId) } == true
        }

    fun webUrl(): String? = try {
        node?.webUrl(app.instanceId)
    } catch (e: Exception) {
        null
    }

    fun present(alert: InAppAlert) {
        if (alertGrant == AlertGrant.GRANTED) alertPresenter?.invoke(alert)
    }
}
