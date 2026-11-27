package dev.research.customer_rtc

/** Main-thread state for host lifecycle transitions that can precede Dart event subscription. */
internal class HostVisibility(
    private val deliverBackground: (String) -> Boolean,
    private val releaseNative: (String) -> Unit
) {
    private var background = false
    private var presentationId: String? = null
    private val interruptedIds = mutableSetOf<String>()
    private val pendingIds = linkedSetOf<String>()
    var epoch = 0L
        private set

    fun updatePresentation(id: String?) {
        presentationId = id
        if (background && id != null) interrupt(id)
    }

    fun foreground() { background = false }

    fun background(activeNativeId: String?) {
        if (!background) {
            epoch++
            interruptedIds.retainAll { it == activeNativeId || it == presentationId || it in pendingIds }
        }
        background = true
        // A native session can exist without a presentation in a Flutter-only host.
        // If they differ, ensure both the actual engine and Dart's current attempt are stopped.
        if (activeNativeId != null && activeNativeId != presentationId) interrupt(activeNativeId)
        presentationId?.let(::interrupt)
    }

    private fun interrupt(id: String) {
        if (interruptedIds.add(id)) pendingIds.add(id)
        // Signal first if possible so Dart keeps the background end reason for a pending join.
        // Native teardown also runs when the event channel is absent.
        try {
            replay()
        } finally {
            releaseNative(id)
        }
    }

    fun replay() {
        while (pendingIds.isNotEmpty()) {
            val id = pendingIds.first()
            if (!deliverBackground(id)) return
            pendingIds.remove(id)
        }
    }

    fun isInterrupted(id: String?) = id != null && id in interruptedIds

    fun joinBlockReason(id: String, requestEpoch: Long = epoch): String? = when {
        background || requestEpoch != epoch || isInterrupted(id) -> "host_background"
        presentationId != null && id != presentationId -> "cancelled"
        else -> null
    }
}
