package org.freenet.appkit.demo

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Message
import android.view.Gravity
import android.view.View
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.freenet.appkit.WebBridgeHost
import org.freenet.appkit.WebBundleServer
import org.freenet.appkit.originOf
import org.freenet.mobile.WebBridge
import org.freenet.mobile.WebBundle
import org.json.JSONObject

/** The live web view of each web app, for the harness. */
object WebViews {
    val byApp = mutableMapOf<DemoWebApp, WebView>()
}

/** Load timeline of each web app, read by the harness. */
object WebTimeline {
    data class Mark(val event: String, val ms: Double)

    private val marks = mutableMapOf<DemoWebApp, MutableList<Mark>>()

    @Synchronized fun reset(app: DemoWebApp) { marks[app] = mutableListOf() }

    @Synchronized fun mark(app: DemoWebApp, event: String) {
        marks.getOrPut(app) { mutableListOf() }.add(Mark(event, System.currentTimeMillis().toDouble()))
    }

    @Synchronized fun marks(app: DemoWebApp): List<Mark> = marks[app]?.toList() ?: emptyList()

    fun has(app: DemoWebApp, prefix: String) = marks(app).any { it.event.startsWith(prefix) }
}

/** A `Notification` for the node's shell page that hands alerts to the host. */
object AlertShim {
    fun script(permission: String) = """
        (function () {
          var granted = '$permission';
          var live = {};
          var next = 0;
          var waiting = [];
          function post(msg) {
            try { window.appkitAlerts.postMessage(JSON.stringify(msg)); } catch (e) {}
          }
          function HostNotification(title, options) {
            options = options || {};
            this.title = String(title);
            this.body = typeof options.body === 'string' ? options.body : '';
            this.tag = typeof options.tag === 'string' ? options.tag : '';
            this.data = options.data;
            this.onclick = null;
            this._id = String(++next);
            live[this._id] = this;
            post({ kind: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag });
          }
          HostNotification.prototype.close = function () { delete live[this._id]; };
          HostNotification.prototype.addEventListener = function (type, cb) {
            if (type === 'click') { this.onclick = cb; }
          };
          Object.defineProperty(HostNotification, 'permission', { get: function () { return granted; } });
          HostNotification.requestPermission = function (callback) {
            return new Promise(function (resolve) {
              waiting.push(function (answer) {
                granted = answer;
                if (typeof callback === 'function') { callback(answer); }
                resolve(answer);
              });
              post({ kind: 'permission' });
            });
          };
          window.__appkitAlertPermission = function (answer) {
            granted = answer;
            var pending = waiting;
            waiting = [];
            pending.forEach(function (f) { f(answer); });
          };
          window.__appkitAlertClick = function (id) {
            var n = live[id];
            if (n && typeof n.onclick === 'function') { n.onclick({ target: n }); }
          };
          window.Notification = HostNotification;
        })();
    """.trimIndent()

    /**
     * Every frame reports when its document is ready. The app frame also
     * reports when it first shows text or media, which ends the loading view.
     */
    const val FRAME_REPORT = """
        (function () {
          function post(msg) {
            try { window.appkitFrames.postMessage(JSON.stringify(msg)); } catch (e) {}
          }
          var top = window === window.top;
          post({ kind: 'frame', top: top, href: String(location.href) });
          if (top) { return; }
          function painted() {
            var body = document.body;
            if (!body) { return false; }
            if (body.innerText && body.innerText.trim().length > 0) { return true; }
            var media = body.querySelectorAll('img, svg, canvas, video, input, button');
            for (var i = 0; i < media.length; i++) {
              var r = media[i].getBoundingClientRect();
              if (r.width > 0 && r.height > 0) { return true; }
            }
            return false;
          }
          var done = false, queued = false, observer;
          function check() {
            queued = false;
            if (done || !painted()) { return; }
            done = true;
            if (observer) { observer.disconnect(); }
            post({ kind: 'painted', top: false });
          }
          observer = new MutationObserver(function () {
            if (!queued) { queued = true; requestAnimationFrame(check); }
          });
          observer.observe(document, { childList: true, subtree: true, characterData: true });
          check();
        })();
    """
}

/**
 * A spinner and a line of text over the whole page, or the error and a retry
 * button once loading failed.
 */
class LoadingView(context: Context) {
    private val spinner = ProgressBar(context).apply { isIndeterminate = true }
    private val text = TextView(context).apply {
        gravity = Gravity.CENTER
        setPadding(48, 24, 48, 24)
    }
    private val retry = Button(context).apply {
        text = "Try again"
        isAllCaps = false
    }
    val view = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        isClickable = true
        setBackgroundColor(backgroundColor(context))
        addView(spinner, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(text, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(retry, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    fun loading(message: String) {
        spinner.visibility = View.VISIBLE
        retry.visibility = View.GONE
        text.text = message
        view.visibility = View.VISIBLE
        view.bringToFront()
    }

    fun failed(message: String, onRetry: (() -> Unit)?) {
        spinner.visibility = View.GONE
        text.text = message
        retry.visibility = if (onRetry == null) View.GONE else View.VISIBLE
        retry.setOnClickListener { onRetry?.invoke() }
        view.visibility = View.VISIBLE
        view.bringToFront()
    }

    fun hide() {
        view.visibility = View.GONE
    }

    private fun backgroundColor(context: Context): Int {
        val attrs = context.obtainStyledAttributes(intArrayOf(android.R.attr.colorBackground))
        val color = attrs.getColor(0, android.graphics.Color.WHITE)
        attrs.recycle()
        return color
    }
}

/**
 * River or Atlas, served by the embedded node. The shell page gets a
 * `Notification` that shows in-app alerts while the app is open.
 */
@SuppressLint("SetJavaScriptEnabled")
class WebAppPage(private val context: Context, val app: DemoWebApp) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val view = FrameLayout(context)
    private val loading = LoadingView(context)
    private var webView: WebView? = null
    private var loadedGeneration = -1
    /** Set from the WebView's network thread when the app frame is requested. */
    @Volatile private var appFrameSeen = false
    private var shown = false
    private val fallback = Runnable { reveal() }

    init {
        view.addView(loading.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        loading.loading("Starting the node")
    }

    /** Prepare and load the app for the current node session. */
    fun show() {
        if (loadedGeneration == NodeHost.sessionGeneration && webView != null) return
        loadedGeneration = NodeHost.sessionGeneration
        scope.launch { prepare() }
    }

    private fun retry() {
        loadedGeneration = NodeHost.sessionGeneration
        scope.launch { prepare() }
    }

    private suspend fun prepare() {
        WebTimeline.reset(app)
        WebTimeline.mark(app, "prepare")
        showStatus("Starting the node")
        if (NodeHost.start() == null) {
            return showError("The node did not start.\n${NodeHost.lastError}")
        }
        WebTimeline.mark(app, "node_running")
        if (NodeHost.profile != NetworkProfile.LOCAL) {
            showStatus("Waiting for a peer")
            if (!NodeHost.waitForPeers()) {
                return showError("No peer answered.\n${NodeHost.lastError}")
            }
            WebTimeline.mark(app, "first_peer")
        } else {
            showStatus("Loading ${app.title} into the local node")
            try {
                NodeHost.preloadIfLocal(context, app)
                WebTimeline.mark(app, "preloaded")
            } catch (e: Exception) {
                return showError("${app.title} is not available offline.\n${e.message}")
            }
        }
        val url = NodeHost.webUrl(app) ?: return showError("The node is not running")
        WebTimeline.mark(app, "load_start")
        load(url)
    }

    private fun removeWebView() {
        view.removeCallbacks(fallback)
        webView?.let { view.removeView(it); it.destroy() }
        webView = null
    }

    private fun showStatus(text: String) {
        removeWebView()
        loading.loading(text)
    }

    private fun showError(text: String) {
        removeWebView()
        loading.failed(text) { retry() }
    }

    /** The app has drawn something, or the node showed its own page. */
    private fun reveal() {
        view.removeCallbacks(fallback)
        if (shown) return
        shown = true
        loading.hide()
    }

    private fun appFrameLoaded() {
        if (shown) return
        loading.loading("Starting ${app.title}")
        view.removeCallbacks(fallback)
        view.postDelayed(fallback, PAINT_FALLBACK_MS)
    }

    private fun loadFailed(message: String) {
        WebTimeline.mark(app, "load_failed:$message")
        view.removeCallbacks(fallback)
        shown = true
        loading.failed("${app.title} did not load.\n$message") { retry() }
    }

    private fun load(url: String) {
        removeWebView()
        val origin = originOf(url)
        val web = WebView(context)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.settings.mediaPlaybackRequiresUserGesture = false
        web.settings.setSupportMultipleWindows(true)
        WebView.setWebContentsDebuggingEnabled(true)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(web, AlertShim.script(NodeHost.alertGrant.key), setOf(origin))
            WebViewCompat.addDocumentStartJavaScript(web, AlertShim.FRAME_REPORT, setOf("*"))
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(web, "appkitAlerts", setOf(origin)) { _, message, _, _, _ ->
                message.data?.let { handleAlert(web, JSONObject(it)) }
            }
            WebViewCompat.addWebMessageListener(web, "appkitFrames", setOf("*")) { _, message, _, _, _ ->
                val body = message.data?.let { JSONObject(it) } ?: JSONObject()
                val top = body.optBoolean("top")
                if (body.optString("kind") == "painted") {
                    WebTimeline.mark(app, "app_painted")
                    // The DOM has content; reveal once the view has drawn it.
                    web.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            WebTimeline.mark(app, "app_drawn")
                            reveal()
                        }
                    })
                } else {
                    WebTimeline.mark(app, if (top) "shell_dom" else "app_frame_dom")
                    if (!top) appFrameLoaded()
                }
            }
        }
        web.webViewClient = object : WebViewClient() {
            // With no app frame, the node answered with its own page, such as
            // an error, so show it. The app frame's request can arrive just
            // after this callback, so look again a moment later.
            override fun onPageFinished(view: WebView, url: String) {
                WebTimeline.mark(app, "shell_loaded")
                if (!appFrameSeen) view.postDelayed({ if (!appFrameSeen && webView === view) reveal() }, NO_FRAME_WAIT_MS)
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) loadFailed(error.description.toString())
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.url.getQueryParameter("__sandbox") == "1" && request.isForMainFrame.not()) {
                    appFrameSeen = true
                    WebTimeline.mark(app, "app_frame_request")
                }
                return null
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView, title: String?) {
                if (!title.isNullOrEmpty() && !title.startsWith("http")) WebTimeline.mark(app, "title:$title")
            }

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
                            context.startActivity(Intent(Intent.ACTION_VIEW, target))
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
        loading.loading(
            if (NodeHost.profile == NetworkProfile.LOCAL) "Opening ${app.title}" else "Fetching ${app.title} from the network")
        webView = web
        WebViews.byApp[app] = web
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
                WebTimeline.mark(app, "alert_shown")
                NodeHost.present(InAppAlert(id, body.optString("title", app.title), body.optString("body"), app) {
                    WebTimeline.mark(app, "alert_opened")
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

/** The host-served bundle route: a test page from the app's own verified files. */
@SuppressLint("SetJavaScriptEnabled")
class BridgePage(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val view = FrameLayout(context)
    private val loading = LoadingView(context)
    private var webView: WebView? = null
    private var bridgeHost: WebBridgeHost? = null
    private val sinks = mutableListOf<String>()
    private var loadedGeneration = -1
    var latestReport: JSONObject? = null
        private set

    init {
        view.addView(loading.view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    }

    fun show(autorun: Boolean) {
        if (loadedGeneration == NodeHost.sessionGeneration && webView != null) return
        loadedGeneration = NodeHost.sessionGeneration
        loading.loading("Starting the node")
        scope.launch {
            if (NodeHost.start() == null) {
                loading.failed("The node did not start.\n${NodeHost.lastError}", null)
                return@launch
            }
            load(autorun)
            loading.hide()
        }
    }

    private fun load(autorun: Boolean) {
        close()
        latestReport = null
        val bundle = WebBundle.open(AppResources.bridgeTestBundle(context).absolutePath)
        val server = WebBundleServer(bundle)
        val bridge = WebBridge(NodeHost.node, bundle)
        val web = WebView(context)
        web.settings.javaScriptEnabled = true
        WebView.setWebContentsDebuggingEnabled(true)
        val host = WebBridgeHost(bridge)
        host.install(web, WebBundleServer.ORIGIN)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(web, "appkitHarness", setOf(WebBundleServer.ORIGIN)) { _, message, _, _, _ ->
                message.data?.let { latestReport = JSONObject(it) }
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) = server.intercept(request)
        }
        sinks += NodeHost.addEventSink { event -> host.deliver(bridge.eventFor(event)) }
        sinks += NodeHost.addLifecycleSink { phase -> host.deliver(bridge.lifecycleEvent(phase)) }
        view.addView(web, 0, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        webView = web
        bridgeHost = host
        web.loadUrl(server.indexUrl + if (autorun) "?autorun=1" else "")
    }

    private fun close() {
        sinks.forEach(NodeHost::removeSink)
        sinks.clear()
        bridgeHost?.close()
        webView?.let { view.removeView(it); it.destroy() }
        webView = null
    }
}

/** Open [url] outside the app. */
fun openExternally(context: Context, url: String) {
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
}
