package org.freenet.appkit

import android.content.Context
import java.io.File
import org.freenet.mobile.GatewayOverride
import org.freenet.mobile.NodeMode
import org.freenet.mobile.NodeSettings
import org.freenet.mobile.WasmBackendChoice

/**
 * Where an Android app keeps the embedded node's files.
 *
 * Stores live in the app's files directory, which Android keeps across launches
 * and app updates. Logs and unpacked web apps live in the cache directory,
 * which Android may clear when the device runs low on space.
 */
class NodeDirectories(val data: File, val config: File, val logs: File, val cache: File) {
    companion object {
        fun standard(context: Context, folder: String = "freenet"): NodeDirectories {
            val files = File(context.filesDir, folder)
            val caches = File(context.cacheDir, folder)
            val dirs = NodeDirectories(
                data = File(files, "data"),
                config = File(files, "config"),
                logs = File(caches, "logs"),
                cache = File(caches, "cache"),
            )
            listOf(dirs.data, dirs.config, dirs.logs, dirs.cache).forEach { it.mkdirs() }
            return dirs
        }
    }

    /** Settings for a node in [mode], rooted in these directories. */
    fun settings(
        mode: NodeMode,
        gateways: List<GatewayOverride> = emptyList(),
        preferredWsPort: UShort? = null,
        wasmBackend: WasmBackendChoice? = null,
    ) = NodeSettings(
        dataDir = data.absolutePath,
        configDir = config.absolutePath,
        logDir = logs.absolutePath,
        cacheDir = cache.absolutePath,
        mode = mode,
        preferredWsPort = preferredWsPort,
        networkPort = null,
        gateways = gateways,
        wasmBackend = wasmBackend,
        logFilter = null,
        moduleCacheBudgetBytes = null,
        maxHostingStorageBytes = null,
        maxHostingDiskBytes = null,
    )
}
