package dev.research.customer_rtc

import android.content.Context
import android.graphics.Color
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.TextureView
import android.view.View
import android.widget.TextView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

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
