package org.freenet.appkit.demo

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Message
import android.view.Gravity
import android.widget.TextView
import android.webkit.CookieManager
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
 * The hosted app, served by the embedded node. The shell page gets a
 * `Notification` that shows in-app alerts while the app is open.
 *
 * Each node session serves the app at a new URL. When a session ends while a
 * page is on screen, the old page stays, dimmed and under a "Reconnecting"
 * pill, until the next session's page has drawn behind it.
 *
 * Every bridge message is checked before it acts: it must come from the web
 * view on screen, from the frame and origin its listener serves, within the
 * size limit, during the session the page was loaded for, and with the
 * permission it needs. Prompts close when their session ends and their
 * answers are dropped.
 */
@SuppressLint("SetJavaScriptEnabled")
class WebAppPage(private val context: Context, val app: HostedApp) {
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
    /** The permission prompt on screen, and the session that asked. */
    private var prompt: Pair<AlertDialog, ULong?>? = null
    private val density = context.resources.displayMetrics.density
    private val offline = TextView(context).apply {
        text = LoadMessages.OFFLINE
        setTextColor(Color.WHITE)
        textSize = 14f
        val padH = (16 * density).toInt()
        val padV = (8 * density).toInt()
        setPadding(padH, padV, padH, padV)
        background = GradientDrawable().apply { cornerRadius = 100 * density; setColor(Color.parseColor("#E61B1F24")) }
        visibility = android.view.View.GONE
    }

    init {
        view.addView(loading.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        view.addView(reconnect.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        view.addView(offline, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            bottomMargin = (12 * density).toInt()
        })
        loading.loading(LoadMessages.STARTING)
    }

    /** Load the app for the current node session, unless it already is. */
    fun show() {
        closeStalePrompt()
        if (job?.isActive == true) return
        if (webView != null && loadedSession != null && loadedSession == NodeHost.info?.session) return
        job = scope.launch { prepare() }
    }

    /** Saved content stays readable offline; the label says changes wait. */
    fun networkChanged() {
        offline.visibility = if (!NodeHost.networkAvailable && shown && !failed) android.view.View.VISIBLE else android.view.View.GONE
    }

    /** The session the page on screen was loaded for is still current. */
    private fun current(web: WebView?, session: ULong?) =
        web != null && web === webView && session != null && session == loadedSession && session == NodeHost.info?.session

    /** Close a prompt whose session has ended; its answer is dropped. */
    private fun closeStalePrompt() {
        val (dialog, session) = prompt ?: return
        if (session != NodeHost.info?.session || session != loadedSession) {
            prompt = null
            dialog.dismiss()
        }
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
        // In the background the page stays, its session already ended; the
        // next session loads it again.
        if (!NodeHost.wantsNode) {
            if (reconnecting) keepForReconnect()
            return
        }
        if (reconnecting) keepForReconnect() else showStatus(LoadMessages.STARTING)
        val info = NodeHost.session()
            ?: return if (NodeHost.wantsNode) showError(LoadMessages.NODE_FAILED, NodeHost.lastError) else Unit
        // A saved page opens before the node joins the network.
        if (!NodeHost.hasSavedPage) {
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
        }
        if (NodeHost.info?.session != info.session) return
        val url = NodeHost.webUrl() ?: return showError(LoadMessages.NODE_FAILED, "The node is not running.")
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
        networkChanged()
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
        val session = loadedSession
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(web, "appkitAlerts", setOf(origin)) { _, message, source, isMainFrame, _ ->
                val data = message.data ?: return@addWebMessageListener
                if (!isMainFrame || source.toString().trimEnd('/') != origin || !current(web, session)) return@addWebMessageListener
                parse(data)?.let { handleAlert(web, session, it) }
            }
            WebViewCompat.addWebMessageListener(web, "appkitFrames", setOf("*")) { _, message, _, _, _ ->
                if (!current(web, session)) return@addWebMessageListener
                val body = message.data?.let { parse(it) } ?: return@addWebMessageListener
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

            // Main-frame navigations stay on the session's origin; web links go
            // to the browser and everything else is refused.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!request.isForMainFrame) return false
                if (isCurrentOrigin(request.url, session)) return false
                if (request.hasGesture() && current(view, session)) openExternally(context, request.url)
                return true
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
            // Links that open a new window: the session's pages stay in this
            // view, web links the user tapped go to the system browser.
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                val probe = WebView(context)
                probe.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        val target = request.url
                        if (isCurrentOrigin(target, session)) {
                            view.loadUrl(target.toString())
                        } else if (isUserGesture && current(view, session)) {
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
        // The node answers the shell page and the app's own requests only
        // with this session's embedder secret; HttpOnly keeps it from scripts.
        val secret = NodeHost.info?.embedderSecret ?: return
        CookieManager.getInstance().setCookie(origin, "freenet-embedder=$secret; Path=/; SameSite=Strict; HttpOnly") {
            if (webView === web) web.loadUrl(url)
        }
    }

    companion object {
        /**
         * Longest the loading view stays once the app frame has loaded, for
         * apps that draw nothing the paint check sees.
         */
        const val PAINT_FALLBACK_MS = 15_000L

        /** How long after the shell page loads to wait for its app frame. */
        const val NO_FRAME_WAIT_MS = 1_000L

        /** Largest bridge message accepted, in characters of its JSON form. */
        const val MAX_MESSAGE_CHARS = 8 * 1024
        const val MAX_TITLE = 200
        const val MAX_BODY = 1_000
    }

    private fun isCurrentOrigin(url: Uri, session: ULong?): Boolean {
        val port = NodeHost.info?.wsPort?.toInt() ?: return false
        return session != null && session == NodeHost.info?.session &&
            url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
    }

    /** A bridge message within the size limit, as JSON. */
    private fun parse(data: String): JSONObject? =
        if (data.length > MAX_MESSAGE_CHARS) null else runCatching { JSONObject(data) }.getOrNull()

    private fun handleAlert(web: WebView, session: ULong?, body: JSONObject) {
        when (body.optString("kind")) {
            "permission" -> askPermission(web, session)
            "show" -> {
                if (NodeHost.alertGrant != AlertGrant.GRANTED) return
                val id = body.optString("id").filter { it.isDigit() }.take(16)
                val title = body.optString("title", app.title).take(MAX_TITLE)
                val text = body.optString("body").take(MAX_BODY)
                NodeHost.present(InAppAlert(id, title, text) {
                    if (current(web, session)) {
                        web.evaluateJavascript("window.__appkitAlertClick && window.__appkitAlertClick('$id')", null)
                    }
                })
            }
        }
    }

    private fun askPermission(web: WebView, session: ULong?) {
        val answer = { grant: AlertGrant ->
            web.evaluateJavascript("window.__appkitAlertPermission && window.__appkitAlertPermission('${grant.key}')", null)
        }
        if (NodeHost.alertGrant != AlertGrant.NOT_ASKED) {
            answer(NodeHost.alertGrant)
            return
        }
        if (prompt != null) return
        // The answer counts only if the session that asked is still current.
        val decide = { grant: AlertGrant ->
            prompt = null
            if (current(web, session)) {
                NodeHost.alertGrant = grant
                answer(grant)
            }
        }
        val dialog = AlertDialog.Builder(context)
            .setTitle("Show message alerts from ${app.title}?")
            .setMessage("Alerts appear only while ${AppInfo.shortName(context)} is open.")
            .setNegativeButton("Don't allow") { _, _ -> decide(AlertGrant.DENIED) }
            .setPositiveButton("Allow") { _, _ -> decide(AlertGrant.GRANTED) }
            .setOnCancelListener { prompt = null }
            .show()
        prompt = dialog to session
    }
}
