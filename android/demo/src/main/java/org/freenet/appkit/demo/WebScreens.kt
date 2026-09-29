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
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
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

    /** Every frame reports when its document is ready. */
    const val FRAME_REPORT = """
        (function () {
          try {
            window.appkitFrames.postMessage(JSON.stringify({ top: window === window.top, href: String(location.href) }));
          } catch (e) {}
        })();
    """
}

/**
 * River or Atlas, served by the embedded node. The shell page gets a
 * `Notification` that shows in-app alerts while the app is open.
 */
@SuppressLint("SetJavaScriptEnabled")
class WebAppPage(private val context: Context, val app: DemoWebApp) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val view = FrameLayout(context)
    private val status = TextView(context).apply {
        gravity = Gravity.CENTER
        setPadding(48, 48, 48, 48)
        text = "Starting the node"
    }
    private var webView: WebView? = null
    private var loadedGeneration = -1

    init {
        view.addView(status)
    }

    /** Prepare and load the app for the current node session. */
    fun show() {
        if (loadedGeneration == NodeHost.sessionGeneration && webView != null) return
        loadedGeneration = NodeHost.sessionGeneration
        scope.launch { prepare() }
    }

    private suspend fun prepare() {
        WebTimeline.reset(app)
        WebTimeline.mark(app, "prepare")
        showStatus("Starting the node")
        if (NodeHost.start() == null) {
            showStatus("The node did not start.\n${NodeHost.lastError}")
            return
        }
        WebTimeline.mark(app, "node_running")
        if (NodeHost.profile != NetworkProfile.LOCAL) {
            showStatus("Waiting for a peer")
            if (!NodeHost.waitForPeers()) {
                showStatus("No peer answered.\n${NodeHost.lastError}")
                return
            }
            WebTimeline.mark(app, "first_peer")
        } else {
            showStatus("Loading ${app.title} into the local node")
            try {
                NodeHost.preloadIfLocal(context, app)
                WebTimeline.mark(app, "preloaded")
            } catch (e: Exception) {
                showStatus("${app.title} is not available offline.\n${e.message}")
                return
            }
        }
        val url = NodeHost.webUrl(app) ?: return showStatus("The node is not running")
        WebTimeline.mark(app, "load_start")
        load(url)
    }

    private fun showStatus(text: String) {
        webView?.let { view.removeView(it); it.destroy() }
        webView = null
        status.text = text
        status.visibility = View.VISIBLE
    }

    private fun load(url: String) {
        webView?.let { view.removeView(it); it.destroy() }
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
                val top = message.data?.let { JSONObject(it).optBoolean("top") } ?: false
                WebTimeline.mark(app, if (top) "shell_dom" else "app_frame_dom")
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                WebTimeline.mark(app, "shell_loaded")
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.url.getQueryParameter("__sandbox") == "1" && request.isForMainFrame.not()) {
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
        view.addView(web, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        status.visibility = View.GONE
        webView = web
        WebViews.byApp[app] = web
        web.loadUrl(url)
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
    private var webView: WebView? = null
    private var bridgeHost: WebBridgeHost? = null
    private val sinks = mutableListOf<String>()
    private var loadedGeneration = -1
    var latestReport: JSONObject? = null
        private set

    fun show(autorun: Boolean) {
        if (loadedGeneration == NodeHost.sessionGeneration && webView != null) return
        loadedGeneration = NodeHost.sessionGeneration
        scope.launch {
            if (NodeHost.start() == null) return@launch
            load(autorun)
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
        view.addView(web, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
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
