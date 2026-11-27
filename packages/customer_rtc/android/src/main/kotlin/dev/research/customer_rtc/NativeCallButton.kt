package dev.research.customer_rtc

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

internal fun Context.pixels(dp: Int) = (resources.displayMetrics.density * dp).roundToInt()

internal fun rounded(fill: Int, radius: Float) = GradientDrawable().apply {
    setColor(fill)
    cornerRadius = radius
}

/** The whole labeled cell is the touch and accessibility target. */
internal class NativeCallButton(context: Context, icon: Int) : LinearLayout(context) {
    private val image = ImageView(context).apply {
        setImageResource(icon)
        scaleType = ImageView.ScaleType.FIT_CENTER
        adjustViewBounds = true
    }
    private val caption = TextView(context).apply {
        textSize = 13f
        includeFontPadding = false
        minHeight = context.pixels(18)
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        maxLines = 1
        setShadowLayer(2f, 0f, 1f, Color.BLACK)
    }

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER
        isFocusable = true
        isClickable = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        image.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        caption.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(image, LayoutParams(context.pixels(48), context.pixels(48)))
        addView(caption, LayoutParams(-1, -2).apply { topMargin = context.pixels(8) })
        foregroundRipple()
    }

    private fun foregroundRipple() {
        background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), null,
            rounded(Color.WHITE, context.pixels(12).toFloat()))
    }

    fun bind(label: String, enabled: Boolean, active: Boolean = false, end: Boolean = false) {
        if (caption.text != label) caption.text = label
        contentDescription = label
        isEnabled = enabled
        alpha = if (enabled) 1f else .48f
        if (end) image.setBackgroundResource(R.drawable.customer_rtc_end_background)
        else image.background = rounded(if (active) 0xF0FFFFFF.toInt() else 0x4DFFFFFF, context.pixels(32).toFloat())
        image.setColorFilter(if (active && !end) Color.rgb(35, 36, 38) else Color.WHITE)
    }

    fun setDiameter(sizeDp: Int) {
        val diameter = context.pixels(sizeDp)
        if (image.layoutParams.width != diameter) image.layoutParams = LayoutParams(diameter, diameter)
        val inset = (diameter - context.pixels(if (sizeDp < 40) 20 else 28)) / 2
        image.setPadding(inset, inset, inset, inset)
    }
}
