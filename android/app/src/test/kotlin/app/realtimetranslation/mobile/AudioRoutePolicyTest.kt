package app.realtimetranslation.mobile

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioRoutePolicyTest {
    @Test
    fun `uses speaker when the phone has no external route`() {
        val selected = AudioRoutePolicy.preferredType(
            listOf(
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            ),
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        )

        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, selected)
    }

    @Test
    fun `external route wins over the built in speaker`() {
        val selected = AudioRoutePolicy.preferredType(
            listOf(
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                AudioDeviceInfo.TYPE_USB_HEADSET,
            ),
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )

        assertEquals(AudioDeviceInfo.TYPE_USB_HEADSET, selected)
    }

    @Test
    fun `keeps the current external route when several are connected`() {
        val selected = AudioRoutePolicy.preferredType(
            listOf(
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            ),
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        )

        assertEquals(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, selected)
    }

    @Test
    fun `falls back deterministically after the current route disappears`() {
        val selected = AudioRoutePolicy.preferredType(
            listOf(
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
            ),
            AudioDeviceInfo.TYPE_USB_HEADSET,
        )

        assertEquals(AudioDeviceInfo.TYPE_WIRED_HEADSET, selected)
    }

    @Test
    fun `detects only supported external communication routes`() {
        assertTrue(
            AudioRoutePolicy.hasExternal(
                listOf(AudioDeviceInfo.TYPE_HEARING_AID),
            ),
        )
        assertTrue(
            AudioRoutePolicy.hasExternal(
                listOf(AudioDeviceInfo.TYPE_BLE_HEADSET),
            ),
        )
        assertFalse(
            AudioRoutePolicy.hasExternal(
                listOf(
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                ),
            ),
        )
    }

    @Test
    fun `does not select an unsupported route`() {
        assertEquals(
            null,
            AudioRoutePolicy.preferredType(
                listOf(AudioDeviceInfo.TYPE_REMOTE_SUBMIX),
                null,
            ),
        )
    }
}
