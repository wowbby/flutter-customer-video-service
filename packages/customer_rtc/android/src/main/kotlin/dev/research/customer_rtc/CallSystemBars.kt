@file:Suppress("DEPRECATION")

package dev.research.customer_rtc

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

internal tailrec fun Context.hostActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> if (baseContext !== this) baseContext.hostActivity() else null
    else -> null
}

/** Acquire the visible host window only during a full presentation, restoring its original policy on exit. */
internal class CallSystemBars {
    private var saved: Saved? = null

    fun showIn(window: Window?) {
        if (saved?.window === window) return
        saved?.restore()
        saved = window?.let { Saved(it).also { state -> state.applyCall() } }
    }

    private class Saved(val window: Window) {
        private val decor = window.decorView
        private val visibility = decor.systemUiVisibility
        private val flags = window.attributes.flags
        private val statusColor = window.statusBarColor
        private val navColor = window.navigationBarColor
        private val divider = if (Build.VERSION.SDK_INT >= 28) window.navigationBarDividerColor else 0
        private val cutout = if (Build.VERSION.SDK_INT >= 28) window.attributes.layoutInDisplayCutoutMode else 0
        private val statusContrast = Build.VERSION.SDK_INT >= 29 && window.isStatusBarContrastEnforced
        private val navContrast = Build.VERSION.SDK_INT >= 29 && window.isNavigationBarContrastEnforced
        private val appearance = if (Build.VERSION.SDK_INT >= 30) window.insetsController?.systemBarsAppearance ?: 0 else 0
        private val statusVisible = if (Build.VERSION.SDK_INT >= 30) decor.rootWindowInsets?.isVisible(WindowInsets.Type.statusBars()) else null
        private val navVisible = if (Build.VERSION.SDK_INT >= 30) decor.rootWindowInsets?.isVisible(WindowInsets.Type.navigationBars()) else null
        private val layout = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        private val uiMask = layout or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        private val flagMask = WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS or
            WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS or WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION or
            WindowManager.LayoutParams.FLAG_FULLSCREEN

        fun applyCall() {
            window.setFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS, flagMask)
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
            if (Build.VERSION.SDK_INT >= 28) {
                window.navigationBarDividerColor = Color.TRANSPARENT
                window.attributes = window.attributes.apply {
                    layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= 30) WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                        else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
            if (Build.VERSION.SDK_INT >= 29) {
                window.isStatusBarContrastEnforced = false
                window.isNavigationBarContrastEnforced = false
            }
            // Layout flags are reversible even for hosts that already opted into edge-to-edge.
            decor.systemUiVisibility = (visibility and uiMask.inv()) or layout
            if (Build.VERSION.SDK_INT >= 30) window.insetsController?.apply {
                show(WindowInsets.Type.systemBars())
                setSystemBarsAppearance(0, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
            }
            decor.requestApplyInsets()
        }

        fun restore() {
            window.setFlags(flags, flagMask)
            window.statusBarColor = statusColor
            window.navigationBarColor = navColor
            if (Build.VERSION.SDK_INT >= 28) {
                window.navigationBarDividerColor = divider
                window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = cutout }
            }
            if (Build.VERSION.SDK_INT >= 29) {
                window.isStatusBarContrastEnforced = statusContrast
                window.isNavigationBarContrastEnforced = navContrast
            }
            decor.systemUiVisibility = (decor.systemUiVisibility and uiMask.inv()) or (visibility and uiMask)
            if (Build.VERSION.SDK_INT >= 30) window.insetsController?.apply {
                setSystemBarsAppearance(appearance, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
                if (statusVisible == false) hide(WindowInsets.Type.statusBars())
                if (navVisible == false) hide(WindowInsets.Type.navigationBars())
            }
            decor.requestApplyInsets()
        }
    }
}
