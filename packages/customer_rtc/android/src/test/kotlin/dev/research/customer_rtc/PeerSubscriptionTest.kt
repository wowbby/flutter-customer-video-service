package dev.research.customer_rtc

import org.junit.Assert.*
import org.junit.Test

class PeerSubscriptionTest {
    @Test fun onlyTrustedPeerCanSubscribeIncludingUnsignedUid() {
        val largeUid = 0xffffffffL.toInt()
        val peer = PeerSubscription(largeUid)
        val tracks = mutableListOf<Int>()
        val subscribe = { uid: Int, _: Boolean -> tracks.add(uid); 0 }
        assertNull(peer.join(3, subscribe, subscribe))
        assertEquals(0, peer.join(largeUid, subscribe, subscribe))
        peer.left(3)
        assertNull(peer.join(3, subscribe, subscribe))
        assertNull(peer.join(largeUid, subscribe, subscribe))
        assertEquals(listOf(largeUid, largeUid), tracks)
    }
    @Test fun failedVideoSubscriptionRollsBackAudioAndNeverSelectsPeer() {
        val peer = PeerSubscription(7)
        val muted = mutableListOf<Boolean>()
        assertEquals(-5, peer.join(7, { _, mute -> muted.add(mute); 0 }, { _, _ -> -5 }))
        assertEquals(listOf(false, true), muted)
        assertNull(peer.selected)
    }
    @Test fun legacyFirstPeerReservesBothTracksUntilItLeaves() {
        val peer = PeerSubscription(null)
        val subscribe = { _: Int, _: Boolean -> 0 }
        assertEquals(0, peer.join(6, subscribe, subscribe))
        assertNull(peer.join(7, subscribe, subscribe))
        peer.left(6)
        assertEquals(0, peer.join(7, subscribe, subscribe))
    }
}
