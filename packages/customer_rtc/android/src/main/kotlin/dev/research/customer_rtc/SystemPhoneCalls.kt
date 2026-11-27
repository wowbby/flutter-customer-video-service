package dev.research.customer_rtc

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.TelephonyManager

internal enum class PhoneCallState(val wire: String) {
    IDLE("idle"), RINGING("ringing"), ACTIVE("active"), UNKNOWN("unknown");
    val busy get() = this == RINGING || this == ACTIVE
}

internal interface PhoneCallMonitor {
    fun needsPermission(): Boolean
    fun read(): PhoneCallState
    fun observe(onChange: (PhoneCallState) -> Unit)
    fun stop()
}

/** Uses only the state in the protected Android phone broadcast. No numbers or call log. */
internal class SystemPhoneCalls(private val context: Context) : PhoneCallMonitor {
    private var receiver: BroadcastReceiver? = null
    override fun needsPermission() = Build.VERSION.SDK_INT >= 23 &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) &&
        context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED

    // The aggregate, three-valued device state includes other SIMs. isInCall alone also
    // includes unanswered calls, so it cannot distinguish answering from dismissing a ring.
    @Suppress("DEPRECATION")
    override fun read(): PhoneCallState {
        val phone = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        return try {
            when (phone?.callState) {
                TelephonyManager.CALL_STATE_IDLE -> PhoneCallState.IDLE
                TelephonyManager.CALL_STATE_RINGING -> PhoneCallState.RINGING
                TelephonyManager.CALL_STATE_OFFHOOK -> PhoneCallState.ACTIVE
                else -> PhoneCallState.UNKNOWN
            }
        } catch (_: RuntimeException) { PhoneCallState.UNKNOWN }
    }

    override fun observe(onChange: (PhoneCallState) -> Unit) {
        stop()
        val observer = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (receiver !== this || intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
                val changed = when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                    TelephonyManager.EXTRA_STATE_OFFHOOK -> PhoneCallState.ACTIVE
                    TelephonyManager.EXTRA_STATE_RINGING -> PhoneCallState.RINGING
                    TelephonyManager.EXTRA_STATE_IDLE -> PhoneCallState.IDLE
                    else -> return
                }
                // OFFHOOK is conclusive even if the system call ended before delivery.
                // One subscription going idle does not clear a call on another SIM.
                onChange(if (changed == PhoneCallState.IDLE) {
                    read().takeIf { it.busy } ?: changed
                } else changed)
            }
        }
        try {
            // PHONE_STATE is a protected system broadcast, also sent by the privileged phone process.
            val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(observer, filter, Context.RECEIVER_EXPORTED)
            else context.registerReceiver(observer, filter)
            receiver = observer
        } catch (_: RuntimeException) { /* Optional on devices without telephony access. */ }
    }

    override fun stop() {
        val old = receiver ?: return
        receiver = null
        context.unregisterReceiver(old)
    }
}
