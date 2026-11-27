package dev.research.customer_rtc

import android.app.Activity
import android.app.Application
import android.os.Bundle

/** Audio restore must wait for a visible Activity even in hosts using only Flutter lifecycle events. */
internal class PhoneAudioVisibility(private val onReturn: () -> Unit) : Application.ActivityLifecycleCallbacks {
    private val visible = mutableSetOf<Activity>()
    var stopped = false
        private set

    override fun onActivityStarted(activity: Activity) {
        visible.add(activity)
        val returned = stopped
        stopped = false
        if (returned) onReturn()
    }

    override fun onActivityResumed(activity: Activity) = onActivityStarted(activity)

    override fun onActivityStopped(activity: Activity) {
        visible.remove(activity)
        stopped = visible.isEmpty()
    }

    override fun onActivityDestroyed(activity: Activity) = onActivityStopped(activity)
    override fun onActivityCreated(activity: Activity, state: Bundle?) {}
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
    override fun onActivityPaused(activity: Activity) {}
}
