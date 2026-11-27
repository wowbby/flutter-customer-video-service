package dev.research.customer_rtc

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.TextureView
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.TextView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

internal class NativeVideoFactory(private val owner: CustomerRtcPlugin) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<Any, Any>()
        return NativeVideoView(context, owner, params["role"] as? String ?: "remote", params["probe"] == true)
    }
}
internal class NativeVideoView(context: Context, private val owner: CustomerRtcPlugin,
    val role: String, val probe: Boolean) : PlatformView {
    private var disposed = false
    private val nativeView: View = if (probe) TextView(context).apply {
        text = "NATIVE\n${role.uppercase()}\n无媒体"
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        setBackgroundColor(if (role == "local") 0xff285160.toInt() else 0xff173b4b.toInt())
        textSize = if (role == "local") 10f else 14f
        if (Build.VERSION.SDK_INT >= 26) {
            setAutoSizeTextTypeUniformWithConfiguration(8, 14, 1, TypedValue.COMPLEX_UNIT_SP)
        }
    } else TextureView(context)
    init { require(role == "local" || role == "remote"); owner.addVideo(this) }
    override fun getView(): View = nativeView
    override fun dispose() { if (!disposed) { disposed = true; owner.removeVideo(this) } }
}
internal class NativeWebFactory(private val owner: CustomerRtcPlugin) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<Any, Any>()
        return NativeWebView(context, id, params["html"] as? String ?: "", owner)
    }
}
/** No foreign resources/frames can load; the JS interface is never exposed to a foreign document. */
@SuppressLint("SetJavaScriptEnabled")
internal class NativeWebView(context: Context, private val id: Int, html: String,
    private val owner: CustomerRtcPlugin) : PlatformView {
    private val main = Handler(Looper.getMainLooper())
    private val web = WebView(context)
    @Volatile private var disposed = false
    private var trustedReady = false
    private val trustedUrl = "https://customer-rtc.invalid/bundled/$id/index.html"
    private val content = html.toByteArray(Charsets.UTF_8)
    init {
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
        }
        web.addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(message: String) {
                if (message.length > 32768) return
                main.post {
                    if (!disposed && trustedReady && web.url == trustedUrl) {
                        owner.emit(mapOf("type" to "bridge", "viewId" to id, "message" to message))
                    }
                }
            }
        }, "CustomerBridge")
        web.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            @Deprecated("Legacy callback needed on API 21")
            override fun shouldOverrideUrlLoading(view: WebView, url: String) = true
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                if (!disposed && request.isForMainFrame && request.method == "GET" && request.url.toString() == trustedUrl) {
                    return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf(
                        "Content-Security-Policy" to "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-src 'none'; child-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'",
                        "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"
                    ), ByteArrayInputStream(content))
                }
                return WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
            }
            override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) { trustedReady = false }
            override fun onPageFinished(view: WebView, url: String?) {
                trustedReady = !disposed && url == trustedUrl
                if (trustedReady) owner.emit(mapOf("type" to "webReady", "viewId" to id))
            }
        }
        owner.addWeb(id, this)
        web.loadUrl(trustedUrl)
    }
    fun reply(json: String) {
        val obj = JSONObject(json) // Require an object, never interpolate arbitrary executable text.
        if (!disposed && trustedReady) web.evaluateJavascript("window.onNativeMessage && window.onNativeMessage(${obj});", null)
    }
    override fun getView(): View = web
    override fun dispose() {
        if (disposed) return
        disposed = true
        trustedReady = false
        owner.removeWeb(id)
        web.removeJavascriptInterface("CustomerBridge")
        web.stopLoading()
        web.destroy()
    }
}
