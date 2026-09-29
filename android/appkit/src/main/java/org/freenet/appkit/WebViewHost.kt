package org.freenet.appkit

import android.annotation.SuppressLint
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.freenet.mobile.WebBridge
import org.freenet.mobile.WebBundle
import org.freenet.mobile.bridgeScript

/**
 * Serves a verified [WebBundle] to a WebView at `http://appkit.bundle/<name>/`.
 * Only files the bundle's manifest lists are served; everything else is 404.
 * Call [intercept] from `WebViewClient.shouldInterceptRequest`.
 */
class WebBundleServer(private val bundle: WebBundle) {
    companion object {
        const val HOST = "appkit.bundle"
        const val ORIGIN = "http://$HOST"
    }

    val indexUrl: String get() = "$ORIGIN/${bundle.name()}/index.html"

    fun intercept(request: WebResourceRequest): WebResourceResponse? {
        val url = request.url
        if (url.host != HOST) return null
        val prefix = "/${bundle.name()}"
        val path = url.path.orEmpty().removePrefix(prefix)
        val file = bundle.resolve(if (path.isEmpty()) "/" else path)
        val headers = mapOf("Cache-Control" to "no-store")
        return if (file != null) {
            val (mime, charset) = splitContentType(file.contentType)
            WebResourceResponse(mime, charset, 200, "OK", headers + ("X-Content-SHA256" to file.sha256),
                ByteArrayInputStream(file.body))
        } else {
            WebResourceResponse("text/plain", "utf-8", 404, "Not Found", headers,
                ByteArrayInputStream("not in the bundle manifest".toByteArray()))
        }
    }

    private fun splitContentType(value: String): Pair<String, String?> {
        val parts = value.split(";").map { it.trim() }
        val charset = parts.drop(1).firstOrNull { it.startsWith("charset=") }?.removePrefix("charset=")
        return parts.first() to charset
    }
}

/**
 * Carries bridge messages between a page and [WebBridge]. The page sends text
 * through `window.freenetHostPort.postMessage`, and replies and events come
 * back through the same object's `onmessage`.
 */
class WebBridgeHost(val bridge: WebBridge) {
    companion object {
        const val PORT_NAME = "freenetHostPort"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var reply: JavaScriptReplyProxy? = null

    /** Install the bridge on [webView] for pages from [origin]. */
    @SuppressLint("RequiresFeature")
    fun install(webView: WebView, origin: String) {
        require(WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            "this WebView cannot carry bridge messages"
        }
        WebViewCompat.addWebMessageListener(webView, PORT_NAME, setOf(origin)) { _, message, _, _, proxy ->
            reply = proxy
            val text = message.data ?: return@addWebMessageListener
            scope.launch {
                val answer = bridge.handle(text)
                proxy.postMessage(answer)
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(webView, bridgeScript(), setOf(origin))
        }
    }

    /** Send an event to the page, once it has sent its first message. */
    fun deliver(json: String) {
        scope.launch { reply?.postMessage(json) }
    }

    fun close() {
        reply = null
    }
}

/** The origin of an http URL, such as `http://127.0.0.1:7509`. */
fun originOf(url: String): String {
    val uri = Uri.parse(url)
    val port = if (uri.port > 0) ":${uri.port}" else ""
    return "${uri.scheme}://${uri.host}$port"
}
