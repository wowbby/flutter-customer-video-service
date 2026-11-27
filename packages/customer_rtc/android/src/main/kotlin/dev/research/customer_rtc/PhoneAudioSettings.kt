package dev.research.customer_rtc

/** A ring changes RTC audio temporarily; only successful user controls change these preferences. */
internal class PhoneAudioSettings {
    private var muted = false
    private var speaker = true
    private var captureFailed = false
    private var observingRingRecovery = false
    private var phoneCaptureFailed = false

    fun beginRing() {
        observingRingRecovery = true
        phoneCaptureFailed = captureFailed
    }

    fun endRecoveryWindow() { observingRingRecovery = false }

    fun observeCapture(failed: Boolean, recording: Boolean) {
        if (failed) {
            captureFailed = true
            if (observingRingRecovery) phoneCaptureFailed = true
        } else if (recording) {
            captureFailed = false
            phoneCaptureFailed = false
        }
    }

    // SDK acceptance does not guarantee that capture has restarted. The capture
    // callback clears this flag, so a bounded follow-up can retry a still-failed mic.
    fun restoreCapture(enable: () -> Int): Boolean =
        muted || !phoneCaptureFailed || adjusted { enable() == 0 }


    fun setMuted(value: Boolean, ringing: Boolean, enableCapture: () -> Int, apply: (Boolean) -> Int): Int {
        if (!ringing && !value && phoneCaptureFailed) {
            val code = enableCapture()
            if (code != 0) return code
        }
        return apply(ringing || value).also { if (it == 0) muted = value }
    }

    fun setSpeaker(value: Boolean, ringing: Boolean, apply: (Boolean) -> Int): Int {
        val code = if (ringing) 0 else apply(value)
        if (code == 0) speaker = value
        return code
    }

    fun adjust(ringing: Boolean, setMicMuted: (Boolean) -> Int, setVolume: (Int) -> Int,
               keepRoute: (Boolean) -> Boolean, setSpeaker: (Boolean) -> Int): Boolean {
        // Attempt all adjustments even if one SDK call fails while audio focus changes.
        val mic = adjusted { setMicMuted(ringing || muted) == 0 }
        val playback = adjusted { setVolume(if (ringing) 0 else 100) == 0 }
        val route = ringing || adjusted { keepRoute(speaker) || setSpeaker(speaker) == 0 }
        return mic && playback && route
    }

    private inline fun adjusted(action: () -> Boolean): Boolean =
        try { action() } catch (_: RuntimeException) { false }
}
