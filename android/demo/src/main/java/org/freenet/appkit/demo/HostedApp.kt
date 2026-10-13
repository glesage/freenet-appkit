package org.freenet.appkit.demo

/**
 * The one web app this installation hosts. Each build flavor hosts exactly
 * one, named by `BuildConfig.APPKIT_APPLICATION`. Its node, stores, web data
 * and consent records belong to that app alone. `HostedApp.swift` in the iOS
 * app has the same values.
 */
enum class HostedApp(val id: String, val title: String, val instanceId: String) {
    RIVER("river", "River", "raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv"),
    ATLAS("atlas", "Atlas", "771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9");

    /** Folder for this app's node files, in the files and cache directories. */
    val storageFolder get() = "freenet-$id"

    /** Name of this app's own preferences file. */
    val preferences get() = "appkit-$id"

    companion object {
        /** The app this build hosts. */
        val current: HostedApp = entries.firstOrNull { it.id == BuildConfig.APPKIT_APPLICATION } ?: RIVER
    }
}
