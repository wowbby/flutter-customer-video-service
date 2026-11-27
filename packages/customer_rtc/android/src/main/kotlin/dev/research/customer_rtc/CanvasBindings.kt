package dev.research.customer_rtc

internal class RtcOperationException(val code: Int) : Exception("RTC operation rejected")

/** A retry may bind both roles. Report each result and retain the first failure for the caller. */
internal class CanvasBindings(private val report: (String, Boolean, Int?) -> Unit) {
    var failure: Exception? = null
        private set

    fun apply(role: String, hasView: Boolean, setup: () -> Int) {
        val code = try { setup() } catch (_: RuntimeException) { null }
        if (code == 0) {
            if (hasView) report(role, true, null)
            return
        }
        report(role, false, code)
        if (failure == null) {
            failure = if (code == null) IllegalStateException("RTC canvas binding failed") else RtcOperationException(code)
        }
    }
}
