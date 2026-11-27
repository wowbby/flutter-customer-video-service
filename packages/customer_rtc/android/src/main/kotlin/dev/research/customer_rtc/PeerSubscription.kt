package dev.research.customer_rtc

/** All tracks start unsubscribed. Only one eligible peer may publish to this client. */
internal class PeerSubscription(private val expected: Int?) {
    var selected: Int? = null
        private set

    fun join(uid: Int, audio: (Int, Boolean) -> Int, video: (Int, Boolean) -> Int): Int? {
        if (selected != null || expected != null && uid != expected) return null
        val audioCode = audio(uid, false)
        if (audioCode != 0) return audioCode
        val videoCode = video(uid, false)
        if (videoCode != 0) {
            audio(uid, true)
            return videoCode
        }
        selected = uid
        return 0
    }

    fun left(uid: Int) { if (selected == uid) selected = null }
}
