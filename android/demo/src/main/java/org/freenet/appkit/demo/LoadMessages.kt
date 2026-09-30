package org.freenet.appkit.demo

/**
 * The loading and error text the web app pages show, the same on iOS. Error
 * details go behind the "Details" button.
 */
object LoadMessages {
    const val STARTING = "Starting Freenet"
    const val CONNECTING = "Connecting to the Freenet network"
    const val CONNECTING_SLOW = "Connecting to the Freenet network. The first connection can take up to a minute."
    const val NODE_FAILED = "Freenet could not start."
    const val NO_PEER = "Freenet could not reach the network. Check your internet connection. " +
        "Some Wi-Fi networks block Freenet's traffic; mobile data may work."

    /** How long the peer wait shows [CONNECTING] before [CONNECTING_SLOW]. */
    const val SLOW_CONNECT_MS = 10_000L

    fun downloading(app: DemoWebApp) = "Downloading ${app.title}"

    fun opening(app: DemoWebApp) = "Opening ${app.title}"

    fun pageFailed(app: DemoWebApp) = "${app.title} could not open."
}
