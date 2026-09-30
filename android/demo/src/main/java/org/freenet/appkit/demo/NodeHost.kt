package org.freenet.appkit.demo

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.freenet.appkit.NodeDirectories
import org.freenet.mobile.MobileNode
import org.freenet.mobile.NodeEvent
import org.freenet.mobile.NodeEventListener
import org.freenet.mobile.NodeInfo
import org.freenet.mobile.NodeMode
import org.freenet.mobile.NodeSettings
import org.freenet.mobile.NodeStatus

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
 * Owns the embedded node for the whole app. The node joins the public network
 * and runs only while the app is in the foreground.
 */
object NodeHost {
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
    /** Increases on every fresh session, so web views reload with new authority. */
    var sessionGeneration = 0
        private set

    private val stateListeners = mutableListOf<() -> Unit>()
    var alertPresenter: ((InAppAlert) -> Unit)? = null

    fun init(context: Context) {
        if (::directories.isInitialized) return
        directories = NodeDirectories.standard(context.applicationContext)
        prefs = context.applicationContext.getSharedPreferences("appkit", Context.MODE_PRIVATE)
    }

    var alertGrant: AlertGrant
        get() = AlertGrant.of(prefs.getString("alerts", null))
        set(value) = prefs.edit().putString("alerts", value.key).apply()

    private fun settings(): NodeSettings {
        val last = prefs.getInt("lastPort", 0)
        return directories.settings(NodeMode.NETWORK, preferredWsPort = if (last == 0) null else last.toUShort())
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
                scope.launch { handle() }
            }
        })
        node = created
        return created
    }

    /** Start the node. Repeated calls return the running node. */
    suspend fun start(): NodeInfo? = try {
        val node = currentNode()
        val started = node.start()
        info = started
        status = node.status()
        lastError = null
        prefs.edit().putInt("lastPort", started.wsPort.toInt()).apply()
        changed()
        started
    } catch (e: Exception) {
        lastError = e.message ?: e.toString()
        changed()
        null
    }

    suspend fun stop() {
        val node = node ?: return
        try {
            node.stop()
        } catch (e: Exception) {
            lastError = e.message
        }
        info = null
        status = node.status()
        changed()
    }

    /** The app moved to the background: stop the node. */
    fun onBackground() {
        scope.launch { stop() }
    }

    /** The app is in the foreground again: start a fresh session. */
    fun onForeground() {
        scope.launch {
            val wasRunning = info != null
            start()
            if (!wasRunning) {
                sessionGeneration += 1
                changed()
            }
        }
    }

    private fun handle() {
        node?.let { status = it.status() }
        changed()
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

    fun webUrl(app: DemoWebApp): String? = try {
        node?.webUrl(app.instanceId)
    } catch (e: Exception) {
        null
    }

    fun present(alert: InAppAlert) {
        alertPresenter?.invoke(alert)
    }
}
