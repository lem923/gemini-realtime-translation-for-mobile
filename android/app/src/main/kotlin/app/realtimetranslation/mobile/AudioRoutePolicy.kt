package app.realtimetranslation.mobile

import android.media.AudioDeviceInfo

internal object AudioRoutePolicy {
    fun preferredType(
        availableTypes: List<Int>,
        currentType: Int?,
    ): Int? {
        if (currentType != null &&
            currentType in availableTypes &&
            isExternal(currentType)
        ) {
            return currentType
        }

        return availableTypes
            .distinct()
            .filter { priority(it) < UNSUPPORTED_PRIORITY }
            .minByOrNull(::priority)
    }

    fun hasExternal(availableTypes: List<Int>): Boolean =
        availableTypes.any(::isExternal)

    private fun priority(type: Int): Int = when (type) {
        AudioDeviceInfo.TYPE_HEARING_AID -> 0
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_LINE_ANALOG -> 10
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> 20
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> 30
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC -> 40
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 100
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 110
        else -> UNSUPPORTED_PRIORITY
    }

    private fun isExternal(type: Int): Boolean = priority(type) < 100

    private const val UNSUPPORTED_PRIORITY = 1_000
}
