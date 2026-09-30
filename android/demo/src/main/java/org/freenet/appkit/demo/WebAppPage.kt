package org.freenet.appkit.demo

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.os.Message
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.freenet.appkit.originOf
import org.json.JSONObject

/**
 * River or Atlas, served by the embedded node. The shell page gets a
 * `Notification` that shows in-app alerts while the app is open.
 *
 * Each node session serves the app at a new URL. When a new session starts
 * while a page is on screen, the old page stays, dimmed and under a
 * "Reconnecting" pill, until the new page has drawn behind it.
 */
@SuppressLint("SetJavaScriptEnabled")
class WebAppPage(private val context: Context, val app: DemoWebApp) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val view = FrameLayout(context)
    private val loading = LoadingView(context)
    private val reconnect = ReconnectOverlay(context)
    private var webView: WebView? = null
    /** The page on screen while [webView] loads for a new session. */
    private var previous: WebView? = null
    /** The node session [webView] was loaded for. */
    private var loadedSession: ULong? = null
    private var job: Job? = null
    /** Set from the WebView's network thread when the app frame is requested. */
    @Volatile private var appFrameSeen = false
    private var shown = false
    /** The last load failed; its error stays until "Try again". */
    private var failed = false
    private val fallback = Runnable { reveal() }
    /** Called when the page's back history changes. */
    var onHistoryChanged: (() -> Unit)? = null

    init {
        view.addView(loading.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        view.addView(reconnect.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        loading.loading(LoadMessages.STARTING)
    }

    /** Load the app for the current node session, unless it already is. */
    fun show() {
        if (job?.isActive == true) return
        if (webView != null && loadedSession != null && loadedSession == NodeHost.info?.session) return
        job = scope.launch { prepare() }
    }

    /** Whether the page has somewhere to go back to. */
    fun canGoBack() = webView?.canGoBack() == true

    fun goBack() {
        webView?.goBack()
    }

    private fun retry() {
        job?.cancel()
        job = scope.launch { prepare() }
    }

    private suspend fun prepare() {
        // A page that has drawn stays on screen while the node reconnects.
        val reconnecting = shown && !failed && webView != null && previous == null
        if (reconnecting) keepForReconnect() else showStatus(LoadMessages.STARTING)
        val info = NodeHost.start() ?: return showError(LoadMessages.NODE_FAILED, NodeHost.lastError)
        if (!reconnecting) showStatus(LoadMessages.CONNECTING)
        val slow = scope.launch {
            delay(LoadMessages.SLOW_CONNECT_MS)
            if (!reconnecting) loading.loading(LoadMessages.CONNECTING_SLOW)
        }
        val connected = NodeHost.waitForPeers()
        slow.cancel()
        if (!connected) {
            return showError(LoadMessages.NO_PEER, NodeHost.lastError)
        }
        val url = NodeHost.webUrl(app) ?: return showError(LoadMessages.NODE_FAILED, "The node is not running.")
        loadedSession = info.session
        load(url)
    }

    /** Dim the page on screen, block its taps and show the pill. */
    private fun keepForReconnect() {
        val web = webView ?: return
        view.removeCallbacks(fallback)
        previous = web
        webView = null
        web.alpha = 0.6f
        loading.hide()
        reconnect.show()
        onHistoryChanged?.invoke()
    }

    private fun removePrevious() {
        previous?.let { view.removeView(it); it.destroy() }
        previous = null
        reconnect.hide()
    }

    private fun removeWebView() {
        view.removeCallbacks(fallback)
        webView?.let { view.removeView(it); it.destroy() }
        webView = null
        onHistoryChanged?.invoke()
    }

    private fun showStatus(text: String) {
        removePrevious()
        removeWebView()
        loading.loading(text)
    }

    private fun showError(text: String, detail: String?) {
        removePrevious()
        removeWebView()
        loading.failed(text, detail) { retry() }
    }

    /** The app has drawn something, or the node showed its own page. */
    private fun reveal() {
        view.removeCallbacks(fallback)
        if (shown) return
        shown = true
        removePrevious()
        loading.hide()
        onHistoryChanged?.invoke()
    }

    private fun appFrameLoaded() {
        if (shown) return
        if (previous == null) loading.loading(LoadMessages.opening(app))
        view.removeCallbacks(fallback)
        view.postDelayed(fallback, PAINT_FALLBACK_MS)
    }

    private fun loadFailed(message: String) {
        view.removeCallbacks(fallback)
        removePrevious()
        shown = true
        failed = true
        loading.failed(LoadMessages.pageFailed(app), message) { retry() }
    }

    /** Load [url] into a new web view, behind the page on screen if there is one. */
    private fun load(url: String) {
        removeWebView()
        val origin = originOf(url)
        val web = WebView(context)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.settings.mediaPlaybackRequiresUserGesture = false
        web.settings.setSupportMultipleWindows(true)
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(web, AlertShim.script(NodeHost.alertGrant.key), setOf(origin))
            WebViewCompat.addDocumentStartJavaScript(web, AlertShim.FRAME_REPORT, setOf("*"))
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(web, "appkitAlerts", setOf(origin)) { _, message, _, _, _ ->
                if (webView === web) message.data?.let { handleAlert(web, JSONObject(it)) }
            }
            WebViewCompat.addWebMessageListener(web, "appkitFrames", setOf("*")) { _, message, _, _, _ ->
                if (webView !== web) return@addWebMessageListener
                val body = message.data?.let { JSONObject(it) } ?: JSONObject()
                when (body.optString("kind")) {
                    // The DOM has content; reveal once the view has drawn it.
                    "painted" -> web.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            if (webView === web) reveal()
                        }
                    })
                    // The app frame's history moves without a main-frame visit.
                    "history" -> onHistoryChanged?.invoke()
                    else -> if (!body.optBoolean("top")) appFrameLoaded()
                }
            }
        }
        web.webViewClient = object : WebViewClient() {
            // With no app frame, the node answered with its own page, such as
            // an error, so show it. The app frame's request can arrive just
            // after this callback, so look again a moment later.
            override fun onPageFinished(view: WebView, url: String) {
                if (!appFrameSeen) view.postDelayed({ if (!appFrameSeen && webView === view) reveal() }, NO_FRAME_WAIT_MS)
            }

            override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
                onHistoryChanged?.invoke()
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame && view === webView) loadFailed(error.description.toString())
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.url.getQueryParameter("__sandbox") == "1" && request.isForMainFrame.not()) appFrameSeen = true
                return null
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            // Links that open a new window: loopback pages stay in this view,
            // other sites go to the system browser.
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                val probe = WebView(context)
                probe.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        val target = request.url
                        if (target.host == "127.0.0.1" || target.host == "localhost") {
                            view.loadUrl(target.toString())
                        } else {
                            openExternally(context, target)
                        }
                        probe.destroy()
                        return true
                    }
                }
                (resultMsg.obj as WebView.WebViewTransport).webView = probe
                resultMsg.sendToTarget()
                return true
            }
        }
        view.addView(web, 0, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        appFrameSeen = false
        shown = false
        failed = false
        if (previous == null) loading.loading(LoadMessages.downloading(app))
        webView = web
        web.loadUrl(url)
    }

    companion object {
        /**
         * Longest the loading view stays once the app frame has loaded, for
         * apps that draw nothing the paint check sees.
         */
        const val PAINT_FALLBACK_MS = 15_000L

        /** How long after the shell page loads to wait for its app frame. */
        const val NO_FRAME_WAIT_MS = 1_000L
    }

    private fun handleAlert(web: WebView, body: JSONObject) {
        when (body.optString("kind")) {
            "permission" -> askPermission(web)
            "show" -> {
                val id = body.optString("id").filter { it.isDigit() }
                NodeHost.present(InAppAlert(id, body.optString("title", app.title), body.optString("body"), app) {
                    web.evaluateJavascript("window.__appkitAlertClick && window.__appkitAlertClick('$id')", null)
                })
            }
        }
    }

    private fun askPermission(web: WebView) {
        val answer = { grant: AlertGrant ->
            NodeHost.alertGrant = grant
            web.evaluateJavascript("window.__appkitAlertPermission && window.__appkitAlertPermission('${grant.key}')", null)
        }
        if (NodeHost.alertGrant != AlertGrant.NOT_ASKED) {
            answer(NodeHost.alertGrant)
            return
        }
        AlertDialog.Builder(context)
            .setTitle("Show message alerts from ${app.title}?")
            .setMessage("Alerts appear only while AppKit Demo is open.")
            .setNegativeButton("Don't allow") { _, _ -> answer(AlertGrant.DENIED) }
            .setPositiveButton("Allow") { _, _ -> answer(AlertGrant.GRANTED) }
            .show()
    }
}
