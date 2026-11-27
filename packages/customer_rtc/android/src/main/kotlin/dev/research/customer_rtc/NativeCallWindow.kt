package dev.research.customer_rtc

import android.graphics.BitmapFactory
import android.graphics.Rect
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.WindowInsets
import android.view.ViewTreeObserver
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** Lives inside the visible host root. Its two RTC textures stay attached across layout changes. */
internal class NativeCallWindow(
    private val root: FrameLayout,
    private val action: (String, String) -> Unit
) {
    private val context = root.context
    private fun dp(value: Int) = context.pixels(value)
    private fun label(size: Float) = TextView(context).apply {
        textSize = size
        setTextColor(Color.WHITE)
        gravity = Gravity.CENTER
    }
    private fun avatar() = ImageView(context).apply {
        setImageResource(R.drawable.service_avatar)
        scaleType = ImageView.ScaleType.CENTER_CROP
        // The exported asset includes a transparent margin and the original shadow.
        scaleX = 1.295f
        scaleY = 1.295f
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private fun cardAvatar() = avatar().apply {
        // In the 259px export, the opaque 180px portrait is centred at (129.5, 114.5).
        scaleX = 259f / 180f
        scaleY = scaleX
    }
    private val panel = FrameLayout(context).apply {
        isClickable = true
        clipToOutline = true
        elevation = dp(12).toFloat()
    }
    private val controls = FrameLayout(context)
    private var appliedInsets: WindowInsets? = null
    private val media = FrameLayout(context)
    val local = TextureView(context)
    val remote = TextureView(context)
    private fun videoFrame(texture: TextureView) = FrameLayout(context).apply {
        background = rounded(Color.BLACK, dp(12).toFloat())
        addView(texture, FrameLayout.LayoutParams(-1, -1))
    }
    private val localFrame = videoFrame(local)
    private val remoteFrame = videoFrame(remote)
    private val waitBackdrop = ImageView(context).apply {
        setImageResource(R.drawable.call_wait_background)
        scaleType = ImageView.ScaleType.CENTER_CROP
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val blankMain = View(context).apply {
        setBackgroundColor(0xFF1D2626.toInt())
    }
    private val avatarCard = FrameLayout(context).apply {
        background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(0xFF70C2BE.toInt(), 0xFF53908D.toInt())).apply { cornerRadius = dp(20).toFloat() }
        clipToOutline = true
        addView(cardAvatar(), FrameLayout.LayoutParams(dp(58), dp(58), Gravity.CENTER))
    }
    private val localAvatar = ImageView(context).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        background = rounded(0xFF465355.toInt(), dp(100).toFloat())
        clipToOutline = true
        setImageResource(R.drawable.call_user_avatar)
    }
    private var localAvatarPath: String? = null
    private val localPaused = FrameLayout(context).apply {
        contentDescription = "本机摄像头已关闭"
        background = rounded(0xFF283133.toInt(), dp(20).toFloat())
        clipToOutline = true
        addView(localAvatar, FrameLayout.LayoutParams(dp(50), dp(50), Gravity.CENTER))
    }
    private fun updateLocalAvatar(path: String?) {
        if (path == localAvatarPath) return
        localAvatarPath = path
        localAvatar.setImageResource(R.drawable.call_user_avatar)
        if (path == null || !java.io.File(path).isAbsolute) return
        // Read only the local thumbnail the host provided. Discard stale results on redial.
        avatarLoader.execute {
            val bitmap = runCatching {
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, options)
                options.inSampleSize = 1
                while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 512) {
                    options.inSampleSize *= 2
                }
                options.inJustDecodeBounds = false
                BitmapFactory.decodeFile(path, options)
            }.getOrNull()
            if (bitmap != null) root.post {
                if (localAvatarPath == path) localAvatar.setImageBitmap(bitmap)
            }
        }
    }
    private companion object {
        val avatarLoader = java.util.concurrent.Executors.newSingleThreadExecutor()
    }
    private val cardOverlay = FrameLayout(context).apply {
        background = rounded(Color.TRANSPARENT, dp(20).toFloat())
        foreground = rounded(Color.TRANSPARENT, dp(20).toFloat()).apply {
            setStroke((1.5f * resources.displayMetrics.density).roundToInt().coerceAtLeast(1), 0xBFFFFFFF.toInt())
        }
        clipToOutline = true
        setOnClickListener { if (!mini && state["canSwapVideo"] == true) emit("swapVideo") }
    }
    private val cardTime = label(14f).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        setBackgroundColor(0x6609403D)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private val waiting = LinearLayout(context).apply {
        clipChildren = false
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
    }
    private val waitingText = label(13f)
    private val compactAvatar = cardAvatar()
    private fun cardGradient(top: Int, bottom: Int, radius: Float) =
        GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(top, bottom)).apply {
            cornerRadius = radius * context.resources.displayMetrics.density
        }
    private val waitingBody = cardGradient(0xFF222D2D.toInt(), 0xFF273434.toInt(), 18.5f)
    private val answeredBody = cardGradient(0xFF70C2BE.toInt(), 0xFF53908D.toInt(), 18.5f)
    // White at 70–80% over the waiting and answered background stops.
    private val waitingBorder = cardGradient(0xFFBDC0C0.toInt(), 0xFFD4D6D6.toInt(), 20f)
    private val answeredBorder = cardGradient(0xFFD4EDEB.toInt(), 0xFFDDE9E8.toInt(), 20f)
    private val cardStroke = (1.5f * context.resources.displayMetrics.density).roundToInt().coerceAtLeast(1)
    private val videoBorder = rounded(Color.TRANSPARENT, dp(20).toFloat()).apply {
        setStroke(cardStroke, 0xBFFFFFFF.toInt())
    }
    private fun TextView.styleCardFooter(backgroundColor: Int) {
        gravity = Gravity.CENTER
        textSize = 14f
        setTextColor(Color.WHITE)
        isSingleLine = true
        includeFontPadding = false
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setBackgroundColor(backgroundColor)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val compactLabel = label(14f).apply {
        styleCardFooter(0x66455353)
    }
    private val compactClock = label(14f).apply {
        styleCardFooter(0x6609403D)
    }
    private val compactBody = FrameLayout(context).apply {
        clipToOutline = true
        addView(compactAvatar, FrameLayout.LayoutParams(dp(58), dp(58), Gravity.CENTER))
        addView(compactLabel, FrameLayout.LayoutParams(-1, dp(28), Gravity.BOTTOM))
        addView(compactClock, FrameLayout.LayoutParams(-1, dp(28), Gravity.BOTTOM))
    }
    private val compactCard = FrameLayout(context).apply {
        clipToOutline = true
        addView(compactBody, FrameLayout.LayoutParams(-1, -1).apply {
            setMargins(cardStroke, cardStroke, cardStroke, cardStroke)
        })
        isFocusable = true
        setOnClickListener { emit("restore") }
        setOnTouchListener(::drag)
    }
    private var callClockBase: Long? = null
    private var frozenDurationMs: Long? = null
    private val clockTick = object : Runnable {
        override fun run() {
            val base = callClockBase ?: return
            val elapsed = frozenDurationMs ?: (SystemClock.elapsedRealtime() - base).coerceAtLeast(0)
            val text = formattedDuration(elapsed / 1000)
            clock.text = text
            if (callMini) {
                compactClock.text = text
                compactCard.contentDescription = "通话时长 ${text}，恢复全屏"
            } else cardTime.text = text
            if (frozenDurationMs == null) panel.postDelayed(this, 1000L - elapsed % 1000L)
        }
    }
    private val shadeTop = View(context).apply {
        background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
            intArrayOf(0xB3000000.toInt(), Color.TRANSPARENT))
    }
    private val shadeBottom = View(context).apply {
        background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
            intArrayOf(0xB3000000.toInt(), Color.TRANSPARENT))
    }
    // A rotated presentation or side-mounted three-button bar can put system icons
    // along a logical side of the call. Keep a dark fade beneath those icons too.
    private fun sideShade(direction: GradientDrawable.Orientation) = View(context).apply {
        background = GradientDrawable(direction, intArrayOf(0xB3000000.toInt(), Color.TRANSPARENT))
    }
    private val shadeLeft = sideShade(GradientDrawable.Orientation.LEFT_RIGHT)
    private val shadeRight = sideShade(GradientDrawable.Orientation.RIGHT_LEFT)
    private val mode = ImageButton(context).apply {
        setImageResource(R.drawable.call_minimize)
        scaleType = ImageView.ScaleType.FIT_CENTER
        setPadding(dp(12), dp(12), dp(12), dp(12))
        setColorFilter(Color.WHITE)
        background = rounded(Color.TRANSPARENT, dp(24).toFloat())
        setOnClickListener { emit(if (mini) "restore" else "minimize") }
    }
    private val clock = label(17f).apply {
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private val networkToast = label(14f).apply {
        setPadding(dp(14), dp(8), dp(14), dp(8))
        background = rounded(0xE62A2C2D.toInt(), dp(10).toFloat())
        elevation = dp(16).toFloat()
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    private var weakMask = 0
    private val dismissNetworkToast = Runnable { root.removeView(networkToast) }
    private fun updateNetworkToast(mask: Int, announce: Boolean) {
        if (weakMask == mask) return
        val newSide = (mask and weakMask.inv()) != 0
        weakMask = mask
        root.removeCallbacks(dismissNetworkToast)
        root.removeView(networkToast)
        if (!newSide || !announce || !root.isShown) return
        networkToast.text = when (mask) {
            1 -> "当前你的网络不佳"
            2 -> "当前对方网络不佳"
            else -> "当前双方网络不佳"
        }
        root.addView(networkToast, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        root.postDelayed(dismissNetworkToast, 3000)
    }
    private val timerCaption = label(13f).apply { text = "通话时长" }
    private val clockStack = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        addView(clock)
        addView(timerCaption)
    }
    private val qualityLabel = label(15f)
    private val quality = LinearLayout(context).apply {
        gravity = Gravity.CENTER
        orientation = LinearLayout.HORIZONTAL
        addView(qualityLabel)
        addView(ImageView(context).apply {
            setImageResource(R.drawable.call_quality_arrow)
            setColorFilter(Color.WHITE)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(9), dp(9)).apply { leftMargin = dp(4) })
        setOnClickListener { menuCover.visibility = View.VISIBLE }
    }
    private val diagnostic = label(13f).apply {
        setPadding(dp(8), dp(3), dp(8), dp(3))
        background = rounded(0xB32F302F.toInt(), dp(10).toFloat())
    }
    private val recovery = label(14f).apply {
        isFocusable = true
        setOnClickListener { emit(if (state["canRefreshToken"] == true) "refreshToken" else "rebindVideo") }
        background = rounded(0xCC3B5653.toInt(), dp(10).toFloat())
    }
    private fun button(icon: Int, command: String) = NativeCallButton(context, icon).apply {
        setOnClickListener { emit(command) }
    }
    private val mic = button(R.drawable.call_mic, "toggleMuted")
    private val speaker = button(R.drawable.call_speaker, "toggleSpeaker")
    private val camera = button(R.drawable.call_camera, "toggleCamera")
    private val turn = button(R.drawable.call_rotate, "toggleOrientation")
    private val flip = button(R.drawable.call_flip, "switchCamera")
    private val end = button(R.drawable.call_end, "hangup")
    private val buttons = listOf(mic, speaker, camera, turn, end, flip)
    private val selectedQualityFont = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        Typeface.create(Typeface.DEFAULT, 600, false) else Typeface.create("sans-serif-medium", Typeface.NORMAL)
    private val sd = qualityItem("标清", "setQualitySd")
    private val hd = qualityItem("高清", "setQualityHd")
    private val qualityMenu = ScrollView(context).apply {
        background = rounded(Color.WHITE, dp(16).toFloat())
        clipToOutline = true
        elevation = dp(4).toFloat()
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(sd, LinearLayout.LayoutParams(-1, dp(48)))
            addView(hd, LinearLayout.LayoutParams(-1, dp(48)))
        })
    }
    private val menuCover: FrameLayout = FrameLayout(context).apply {
        visibility = View.GONE
        setOnClickListener { visibility = View.GONE }
        addView(qualityMenu)
    }
    private val miniTitle = label(14f).apply {
        setOnClickListener { emit("restore") }
        setOnTouchListener(::drag)
    }
    private val miniRestore = label(15f).apply {
        text = "恢复"
        setOnClickListener { emit("restore") }
    }
    private val miniEnd = label(15f).apply { setOnClickListener { emit("hangup") } }
    private var sessionId: String? = null
    private var state: Map<*, *> = emptyMap<Any, Any>()
    private var mini = false
    private enum class MiniStyle { WAITING, CALL, PROBE }
    private var miniStyle: MiniStyle? = null
    private var legacyPeerBase: Long? = null
    private val callMini get() = miniStyle == MiniStyle.CALL
    private val compactMini get() = miniStyle != null
    private var x: Float? = null
    private var y: Float? = null
    private var dockRight: Boolean? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0f
    private var startY = 0f
    private var dragged = false
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val rootLayout = View.OnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
        if (r - l != or - ol || b - t != ob - ot) layout()
    }

    // API 21–29 may stop dispatch at an earlier sibling that consumes insets.
    // Observe window layout as well, without replacing the host's inset listener.
    private val lastLayoutInsets = Rect()
    private val measuredInsets = Rect()
    private val visibleFrame = Rect()
    private val hostLocation = IntArray(2)
    private val legacyInsetsObserver = ViewTreeObserver.OnPreDrawListener {
        val edges = safeInsets()
        if (sessionId != null && edges != lastLayoutInsets) {
            layout(edges)
            false // Measure controls at their new position before presenting this frame.
        } else true
    }

    init {
        if (Build.VERSION.SDK_INT < 30) {
            panel.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(view: View) {
                    view.viewTreeObserver.addOnPreDrawListener(legacyInsetsObserver)
                }
                override fun onViewDetachedFromWindow(view: View) {
                    view.viewTreeObserver.removeOnPreDrawListener(legacyInsetsObserver)
                }
            })
        }
        media.setOnClickListener { if (mini) emit("restore") }
        cardOverlay.addView(cardTime, FrameLayout.LayoutParams(-1, dp(28), Gravity.BOTTOM).apply {
            setMargins(cardStroke, 0, cardStroke, cardStroke)
        })
        listOf(localFrame, remoteFrame, blankMain, avatarCard, localPaused, cardOverlay).forEach { media.addView(it) }
        waiting.addView(avatar(), LinearLayout.LayoutParams(dp(100), dp(100)))
        waiting.addView(waitingText, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(20) })
        listOf(media, waitBackdrop, shadeTop, shadeBottom, shadeLeft, shadeRight, controls).forEach { panel.addView(it) }
        listOf(waiting, mode, quality, clockStack, diagnostic, recovery,
            miniTitle, miniRestore, miniEnd, compactCard).forEach { controls.addView(it) }
        buttons.forEach { controls.addView(it) }
        controls.addView(menuCover)
        panel.setOnApplyWindowInsetsListener { _, insets ->
            appliedInsets = insets
            layout()
            insets
        }
        root.addOnLayoutChangeListener(rootLayout)
    }

    private fun formattedDuration(seconds: Long): String {
        if (seconds < 3600) return String.format(java.util.Locale.ROOT, "%02d:%02d", seconds / 60, seconds % 60)
        return String.format(java.util.Locale.ROOT, "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private fun updateClock(base: Long?, frozen: Long? = null) {
        panel.removeCallbacks(clockTick)
        callClockBase = base
        frozenDurationMs = frozen
        if (base != null) clockTick.run()
    }

    private fun emit(command: String) { sessionId?.let { action(it, command) } }

    private fun qualityItem(label: String, command: String): TextView = label(14f).apply {
        text = label
        isFocusable = true
        setOnClickListener {
            menuCover.visibility = View.GONE
            if (!isSelected) emit(command)
        }
    }

    private fun blockingDiagnosticLabel(): String? = when {
        state["restartRequired"] == true -> "释放失败，请重启 App"
        state["errorCode"] == "cleanupFailed" -> "通话资源释放未确认"
        state["phase"] == "ending" -> "正在结束通话"
        state["errorCode"] == "tokenRefreshFailed" -> "通话授权更新失败"
        state["needsToken"] == true -> "通话授权需要更新"
        state["bindingFailed"] == true -> "视频画面绑定失败"
        state["phase"] == "reconnecting" -> "正在重连"
        state["errorCode"] != null -> "通话操作异常"
        else -> null
    }

    private fun resolveMiniStyle(timed: Boolean): MiniStyle? {
        if (!mini || state["restartRequired"] == true || state["errorCode"] == "cleanupFailed") return null
        val probe = state["probe"] == true
        // Once a peer call is under way, transient notices belong to the restored full window.
        if (timed && !probe) return MiniStyle.CALL
        if (blockingDiagnosticLabel() != null) return null
        if (probe) return MiniStyle.PROBE
        if (state["awaitingAnswer"] == true) return MiniStyle.WAITING
        if ("answeredMiniCard" in state || "previewMiniCard" in state || "showsCallSurface" !in state) return null
        return MiniStyle.WAITING
    }

    @JvmOverloads
    fun update(snapshot: Map<*, *>, receivedAtMs: Long, announceWeak: Boolean = true) {
        val id = snapshot["sessionId"] as? String
        if (id == null) {
            clear()
            return
        }
        if (sessionId != id) {
            updateNetworkToast(0, false)
            updateLocalAvatar(null)
            x = null
            y = null
            dockRight = null
            legacyPeerBase = null
            menuCover.visibility = View.GONE
        }
        sessionId = id
        state = snapshot
        mini = state["mode"] != "full"
        val durationMs = (state["connectedDurationMs"] as? Number)?.toLong()
        // After the seat answers, all visible clocks use the same business duration.
        val duration = (durationMs ?: (state["miniElapsedMs"] as? Number)?.toLong())?.coerceAtLeast(0)
        // Old media-only snapshots have no join timestamp. Anchor to the first observed
        // remote-media presentation for this session and retain that base across layout changes.
        if ("miniElapsedMs" !in state && legacyPeerBase == null && durationMs == null &&
            state["probe"] != true && state["showsCallSurface"] == true) legacyPeerBase = receivedAtMs
        val callBase = duration?.let { receivedAtMs - it } ?: legacyPeerBase?.takeIf { "miniElapsedMs" !in state }
        val frozen = if (state["phase"] == "ending") callBase?.let { receivedAtMs - it } else null
        miniStyle = resolveMiniStyle(callBase != null)
        if (panel.parent == null) root.addView(panel)
        updateLocalAvatar(state["localAvatarPath"] as? String)
        val mask = if (state["phase"] == "ending") 0 else
            (if (state["localWeak"] == true) 1 else 0) or (if (state["remoteWeak"] == true) 2 else 0)
        updateNetworkToast(mask, announceWeak)
        layout()
        val fullCard = !mini && state["probe"] != true && state["showsCallSurface"] == true
        updateClock(if (callMini || fullCard || (!mini && durationMs != null)) callBase else null, frozen)
    }

    private fun drag(view: View, event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.rawX
                downY = event.rawY
                startX = panel.translationX
                startY = panel.translationY
                dragged = false
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (abs(dx) > slop || abs(dy) > slop) dragged = true
                if (dragged) {
                    dockRight = null
                    x = startX + dx
                    y = startY + dy
                    placePanel()
                }
            }
            MotionEvent.ACTION_UP -> if (dragged) {
                val midpoint = (root.width - root.paddingLeft - root.paddingRight) / 2
                dockRight = panel.translationX + panel.width / 2 > midpoint
                placePanel()
            } else view.performClick()
        }
        return true
    }

    /** Intersect window exclusions with this host, which may already be inset or resized by the IME. */
    @Suppress("DEPRECATION")
    private fun safeInsets(): Rect {
        val insets = (if (Build.VERSION.SDK_INT >= 23) root.rootWindowInsets else null) ?: appliedInsets
        val window = root.rootView
        val edges = measuredInsets
        if (insets == null) edges.setEmpty() else if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
            edges.set(bars.left, bars.top, bars.right, bars.bottom)
        } else {
            val cutout = if (Build.VERSION.SDK_INT >= 28) insets.displayCutout else null
            edges.set(maxOf(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0),
                maxOf(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0),
                maxOf(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0),
                maxOf(insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0))
        }
        val pos = hostLocation
        root.getLocationInWindow(pos)
        edges.set((edges.left - pos[0] - root.paddingLeft).coerceAtLeast(0),
            (edges.top - pos[1] - root.paddingTop).coerceAtLeast(0),
            (edges.right - (window.width - pos[0] - root.width) - root.paddingRight).coerceAtLeast(0),
            (edges.bottom - (window.height - pos[1] - root.height) - root.paddingBottom).coerceAtLeast(0))
        if (Build.VERSION.SDK_INT < 30 && root.isAttachedToWindow) {
            // Legacy IMEs also pan a focused window. Intersect the screen-space frame
            // directly with the host, so the window's pan offset is applied only once.
            val visible = visibleFrame
            root.getWindowVisibleDisplayFrame(visible)
            root.getLocationOnScreen(pos)
            edges.set(maxOf(edges.left, visible.left - pos[0] - root.paddingLeft),
                maxOf(edges.top, visible.top - pos[1] - root.paddingTop),
                maxOf(edges.right, pos[0] + root.width - visible.right - root.paddingRight),
                maxOf(edges.bottom, pos[1] + root.height - visible.bottom - root.paddingBottom))
        }
        return edges
    }

    private fun placePanel(edges: Rect = safeInsets()): Pair<Int, Int> {
        val availableW = (root.width - root.paddingLeft - root.paddingRight).coerceAtLeast(0)
        val availableH = (root.height - root.paddingTop - root.paddingBottom).coerceAtLeast(0)
        val rotated = !mini && state["rotated"] == true
        val usableW = (availableW - edges.left - edges.right).coerceAtLeast(0)
        val usableH = (availableH - edges.top - edges.bottom).coerceAtLeast(0)
        val w = if (mini) min(dp(if (compactMini) 84 else 190), usableW) else if (rotated) availableH else availableW
        val h = if (mini) min(dp(if (compactMini) 150 else 250), usableH) else if (rotated) availableW else availableH
        if (panel.layoutParams.width != w || panel.layoutParams.height != h) {
            panel.layoutParams = FrameLayout.LayoutParams(w, h, Gravity.LEFT or Gravity.TOP)
        }
        panel.rotation = if (rotated) 90f else 0f
        if (mini) {
            val room = usableW - w
            val dockInset = if (compactMini) min(dp(16), room / 2) else 0
            val initialY = if (compactMini && y == null) cardTop() else dp(72)
            panel.translationX = when (dockRight) {
                true -> (edges.left + room - dockInset).toFloat()
                false -> (edges.left + dockInset).toFloat()
                null -> (x ?: (edges.left + room - dp(if (compactMini) 16 else 12)).toFloat()).coerceIn(edges.left.toFloat(), (edges.left + room).toFloat())
            }
            panel.translationY = (y ?: initialY.toFloat()).coerceIn(edges.top.toFloat(), (edges.top + usableH - h).toFloat())
        } else {
            panel.translationX = (availableW - w) / 2f
            panel.translationY = (availableH - h) / 2f
        }
        return Pair(w, h)
    }

    private fun cardTop(): Int {
        val location = IntArray(2)
        root.getLocationInWindow(location)
        return dp(105) - root.paddingTop - location[1]
    }

    private fun View.place(left: Int, top: Int, width: Int, height: Int) {
        val params = layoutParams as FrameLayout.LayoutParams
        if (params.leftMargin != left || params.topMargin != top || params.width != width ||
            params.height != height || params.gravity != (Gravity.TOP or Gravity.LEFT)) {
            layoutParams = FrameLayout.LayoutParams(width.coerceAtLeast(0), height.coerceAtLeast(0),
                Gravity.TOP or Gravity.LEFT).apply { leftMargin = left; topMargin = top }
        }
    }

    private fun View.show(visible: Boolean) { visibility = if (visible) View.VISIBLE else View.GONE }

    private fun layout(insets: Rect = safeInsets()) {
        if (sessionId == null || panel.parent !== root) return
        lastLayoutInsets.set(insets)
        if (networkToast.parent === root) {
            networkToast.maxWidth = (root.width - root.paddingLeft - root.paddingRight - insets.left - insets.right).coerceAtLeast(0)
            networkToast.translationX = (insets.left - insets.right) / 2f
            networkToast.translationY = (insets.top - insets.bottom) / 2f
        }
        val (w, h) = placePanel(insets)
        val safe = when {
            mini -> Rect()
            state["rotated"] == true -> Rect(insets.top, insets.right, insets.bottom, insets.left)
            else -> insets
        }
        val controlsW = (w - safe.left - safe.right).coerceAtLeast(0)
        val controlsH = (h - safe.top - safe.bottom).coerceAtLeast(0)
        controls.place(safe.left, safe.top, controlsW, controlsH)
        if (w <= 0 || h <= 0) return
        val probe = state["probe"] == true
        val showCall = state["showsCallSurface"] == true || probe
        val controlsReady = state["canControl"] == true
        val restart = state["restartRequired"] == true
        val failed = state["errorCode"] == "cleanupFailed"
        val ending = state["phase"] == "ending"
        val issue = blockingDiagnosticLabel() ?: if (probe) "窗口测试 · 无媒体" else null
        val endLabel = when {
            failed && !restart -> "重试结束"
            probe -> "结束测试"
            showCall -> "挂断"
            else -> "取消"
        }
        val canEnd = !restart && (!ending || failed)
        panel.background = rounded(Color.rgb(29, 38, 38), dp(if (compactMini) 20 else if (mini) 16 else 0).toFloat())
        val header = if (mini && !compactMini) min(dp(42), h / 3) else 0
        val footer = if (mini && !compactMini) min(dp(48), h / 3) else 0
        val mediaHeight = h - header - footer
        media.place(0, header, w, mediaHeight)
        media.isClickable = mini && !compactMini
        val mainLocal = !mini && state["primaryVideo"] == "local"
        val main = if (mainLocal) localFrame else remoteFrame
        val sub = if (mainLocal) remoteFrame else localFrame
        main.place(0, 0, w, mediaHeight)
        blankMain.place(0, 0, w, mediaHeight)
        blankMain.show(probe || !showCall)
        val cardWidth = if (mini) min(dp(50), w / 4) else min(dp(84), controlsW)
        val cardHeight = if (mini) min(cardWidth * 150 / 84, mediaHeight / 3) else min(dp(150), controlsH)
        val cardX = (w - safe.right - cardWidth - dp(if (mini) 4 else 16)).coerceAtLeast(safe.left)
        val cardY = if (mini) 0 else cardTop().coerceIn(safe.top, (h - safe.bottom - cardHeight).coerceAtLeast(safe.top))
        sub.place(cardX, cardY, cardWidth, cardHeight)
        val mainFallback = if (mainLocal) localPaused else avatarCard
        val subFallback = if (mainLocal) avatarCard else localPaused
        mainFallback.place(0, 0, w, mediaHeight)
        subFallback.place(cardX, cardY, cardWidth, cardHeight)
        val diameter = if (mainLocal) minOf(dp(100), w, mediaHeight) else minOf(dp(58), cardWidth, cardHeight)
        val avatarParams = localAvatar.layoutParams as FrameLayout.LayoutParams
        if (avatarParams.width != diameter) {
            avatarParams.width = diameter
            avatarParams.height = diameter
            localAvatar.layoutParams = avatarParams
        }
        (mainFallback.background as GradientDrawable).cornerRadius = 0f
        (subFallback.background as GradientDrawable).cornerRadius = dp(20).toFloat()
        sub.background = rounded(Color.BLACK, dp(if (mini) 12 else 20).toFloat())
        if (mainLocal) layoutCardAvatar(avatarCard.getChildAt(0), cardWidth, cardHeight)
        else layoutCardAvatar(avatarCard.getChildAt(0), w, mediaHeight, primary = true)
        cardOverlay.place(cardX, cardY, cardWidth, cardHeight)
        val fullCard = !mini && !probe && showCall
        val canSwap = fullCard && state["canSwapVideo"] == true
        cardOverlay.show(fullCard)
        cardOverlay.isClickable = canSwap
        cardOverlay.isFocusable = canSwap
        cardOverlay.contentDescription = if (!canSwap) null else if (mainLocal)
            "切换到对方主画面" else "切换到本机主画面"
        localPaused.importantForAccessibility = if (!mainLocal && canSwap)
            View.IMPORTANT_FOR_ACCESSIBILITY_NO else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        cardTime.show(state["miniElapsedMs"] is Number || state["connectedDurationMs"] is Number ||
            ("miniElapsedMs" !in state && legacyPeerBase != null))
        cardTime.importantForAccessibility = if (canSwap || state["connectedDurationMs"] is Number)
            View.IMPORTANT_FOR_ACCESSIBILITY_NO else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        sub.clipToOutline = true
        main.clipToOutline = false
        // Keep both textures alive behind opaque wait/fallback content, including before the first frame.
        main.bringToFront()
        mainFallback.bringToFront()
        sub.bringToFront()
        subFallback.bringToFront()
        cardOverlay.bringToFront()
        val cardRemoteVideo = state["miniRemoteVideo"] as? Boolean ?: (state["remoteVideo"] == true)
        avatarCard.show(!compactMini && !probe && showCall && !cardRemoteVideo)
        localPaused.show(!mini && !probe && showCall && state["cameraEnabled"] == false)
        localFrame.alpha = if (mini) 0f else 1f
        if (probe || !showCall) blankMain.bringToFront()
        val showCompactVideo = callMini && cardRemoteVideo
        if (showCompactVideo) remoteFrame.bringToFront()
        layoutCompactCard(w, h, showCompactVideo)
        miniTitle.show(mini && !compactMini)
        miniRestore.show(mini && !compactMini)
        miniEnd.show(mini && !compactMini)
        miniTitle.text = issue ?: "查看通话状态"
        miniTitle.place(0, 0, w, header)
        miniRestore.place(0, h - footer, w / 2, footer)
        miniEnd.place(w / 2, h - footer, w - w / 2, footer)
        miniEnd.text = endLabel
        miniEnd.isEnabled = canEnd
        val fullCall = !mini && showCall
        val fullWait = !mini && !showCall
        shadeTop.show(fullCall)
        shadeBottom.show(fullCall)
        shadeTop.place(0, 0, w, (h * 0.186f).toInt())
        shadeBottom.place(0, h - (h * 0.355f).toInt(), w, (h * 0.355f).toInt())
        shadeLeft.show(!mini && safe.left > 0)
        shadeRight.show(!mini && safe.right > 0)
        val leftFade = min(w, min(safe.left, dp(70)) + dp(16))
        val rightFade = min(w, min(safe.right, dp(70)) + dp(16))
        shadeLeft.place(0, 0, leftFade, h)
        shadeRight.place(w - rightFade, 0, rightFade, h)
        waitBackdrop.show(fullWait)
        waitBackdrop.place(0, 0, w, h)
        waiting.show(fullWait)
        waitingText.text = state["queueLabel"] as? String ?: "等待坐席接听，请稍等…"
        val groupWidth = min(controlsW, dp(188))
        val waitTop = if (controlsH < dp(440)) dp(40) else ((h * 250f / 812) - safe.top).toInt().coerceAtLeast(dp(50))
        val avatarSide = min(dp(100), controlsH / 5)
        val avatarView = waiting.getChildAt(0)
        if (avatarView.layoutParams.width != avatarSide) avatarView.layoutParams = LinearLayout.LayoutParams(avatarSide, avatarSide)
        waiting.place((controlsW - groupWidth) / 2, waitTop, groupWidth, min(controlsH - waitTop, avatarSide + dp(84)))
        mode.setImageResource(if (fullWait) R.drawable.call_minimize_wait else R.drawable.call_minimize)
        mode.show(!mini)
        mode.contentDescription = "缩小"
        mode.place(dp(4), dp(4), dp(48), dp(48))
        val timed = state["connectedDurationMs"] != null
        clockStack.show(fullCall && timed)
        clockStack.place((controlsW - dp(169)) / 2, (dp(54) - safe.top).coerceAtLeast(0), dp(169), dp(50))
        val qualityEnabled = fullCall && !probe && controlsReady
        quality.show(fullCall && !probe)
        quality.isEnabled = qualityEnabled
        quality.alpha = if (qualityEnabled) 1f else .5f
        qualityLabel.text = when (state["quality"]) { "hd" -> "高清"; "sd" -> "标清"; else -> "清晰度" }
        quality.contentDescription = "清晰度，" + qualityLabel.text
        val headerTop = if (controlsH < dp(400)) 0 else (dp(44) - safe.top).coerceAtLeast(0)
        val headerHeight = min(dp(60), controlsH / 3)
        quality.place((controlsW - dp(92)).coerceAtLeast(0), headerTop, dp(88), min(dp(44), headerHeight))
        sd.isSelected = state["quality"] == "sd"
        hd.isSelected = state["quality"] == "hd"
        listOf(sd, hd).forEach { item ->
            item.setTextColor(if (item.isSelected) 0xFF008781.toInt() else 0xFF22292A.toInt())
            item.typeface = if (item.isSelected) selectedQualityFont else Typeface.DEFAULT
        }
        if (!qualityEnabled) menuCover.show(false)
        menuCover.place(0, 0, controlsW, controlsH)
        val menuWidth = min(dp(120), (controlsW - dp(12)).coerceAtLeast(0))
        val menuHeight = min(dp(48) * 2, controlsH)
        val menuTop = min(headerTop + headerHeight, controlsH - menuHeight)
        qualityMenu.place((controlsW - dp(12) - menuWidth).coerceAtLeast(0), menuTop, menuWidth, menuHeight)
        diagnostic.show(!mini && issue != null)
        diagnostic.text = issue
        val infoWidth = min(dp(220), controlsW)
        diagnostic.place((controlsW - infoWidth) / 2, dp(58), infoWidth, dp(34))
        val retryToken = state["canRefreshToken"] == true
        recovery.show(!mini && !restart && !ending && (retryToken || (fullCall && state["bindingFailed"] == true)))
        recovery.text = if (retryToken) "重试通话授权" else "恢复画面"
        recovery.isEnabled = retryToken || controlsReady
        val recoveryWidth = min(dp(112), controlsW)
        val recoveryHeight = min(dp(44), controlsH)
        recovery.place((controlsW - recoveryWidth) / 2, min(dp(96), controlsH - recoveryHeight),
            recoveryWidth, recoveryHeight)
        layoutButtons(controlsW, controlsH, safe.bottom, fullCall, probe, controlsReady, endLabel, canEnd)
    }

    private fun layoutCompactCard(w: Int, h: Int, showVideo: Boolean) {
        compactCard.show(compactMini)
        if (!compactMini) return
        compactCard.place(0, 0, w, h)
        val teal = miniStyle != MiniStyle.WAITING
        compactCard.background = when {
            showVideo -> null
            teal -> answeredBorder
            else -> waitingBorder
        }
        compactCard.foreground = if (showVideo) videoBorder else null
        compactBody.background = when {
            showVideo -> null
            teal -> answeredBody
            else -> waitingBody
        }
        compactAvatar.show(!showVideo)
        compactLabel.show(!callMini)
        compactClock.show(callMini)
        if (!callMini) {
            compactLabel.text = if (miniStyle == MiniStyle.PROBE) "无媒体测试" else "等待接听"
            compactLabel.setBackgroundColor(if (teal) 0x6609403D else 0x66455353)
            compactCard.contentDescription = "${compactLabel.text}，恢复全屏"
        }
        layoutCardAvatar(compactAvatar, w, h)
    }

    private fun layoutCardAvatar(view: View, w: Int, h: Int, primary: Boolean = false) {
        val side = min(dp(if (primary) 100 else 58), min((w * .7f).toInt(), h / 2))
        view.translationY = (if (primary) 0f else -h * (11f / 150)) + side * (15f / 180)
        if (view.layoutParams.width != side) view.layoutParams = FrameLayout.LayoutParams(side, side, Gravity.CENTER)
    }

    private fun layoutButtons(w: Int, h: Int, bottomInset: Int, fullCall: Boolean, probe: Boolean,
                              canControl: Boolean, endLabel: String, canEnd: Boolean) {
        val short = h < dp(440)
        val rowHeight = min(dp(if (short) 58 else if (fullCall) 101 else 98), h / 4)
        val bottom = if (short) dp(6) else if (fullCall) (dp(29) - bottomInset).coerceAtLeast(0)
            else (dp(47) - bottomInset).coerceAtLeast(0)
        val rowWidth = min(w, dp(327))
        val colWidth = rowWidth / 3
        val activeMic = state["muted"] != true
        val activeCam = state["cameraEnabled"] != false
        val speakerActive = state["speaker"] == true
        mic.bind(if (activeMic) "麦克风已开" else "麦克风已关", canControl, activeMic)
        camera.bind(if (activeCam) "摄像头已开" else "摄像头已关", canControl, activeCam)
        val audioLabel = when (state["audioRoute"]) {
            "bluetooth" -> "蓝牙耳机"
            "wired" -> "有线耳机"
            "earpiece" -> "听筒已开"
            else -> if (speakerActive) "扬声器已开" else "扬声器已关"
        }
        speaker.bind(audioLabel, canControl, speakerActive)
        turn.bind(if (w > h) "切换竖屏" else "切换横屏", state["canToggleOrientation"] == true)
        flip.bind("翻转摄像头", canControl && activeCam)
        end.bind(endLabel, canEnd, end = true)
        buttons.forEachIndexed { i, button ->
            button.show(!mini && (button === end || (fullCall && !probe) || (fullCall && button === turn)))
            button.setDiameter(if (short) 36 else if (!fullCall && button === end) 65 else 55)
            val left = (w - rowWidth) / 2 + (i % 3) * colWidth
            val top = h - bottom - rowHeight * (2 - i / 3)
            button.place(left, top, colWidth, rowHeight)
        }
    }

    fun handlesBack(): Boolean {
        if (sessionId == null || mini) return false
        if (menuCover.visibility == View.VISIBLE) menuCover.show(false) else emit("minimize")
        return true
    }

    private fun clear() {
        sessionId = null
        updateNetworkToast(0, false)
        updateLocalAvatar(null)
        updateClock(null)
        menuCover.show(false)
        if (panel.parent === root) root.removeView(panel)
    }

    fun close() {
        clear()
        root.removeOnLayoutChangeListener(rootLayout)
    }
}
