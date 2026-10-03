package com.hangzhouchuda.huahuoai

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.provider.Settings
import androidx.core.location.LocationManagerCompat

internal enum class RecordingCardBluetoothPermissionProfile {
    NONE,
    LEGACY_LOCATION,
    NEARBY_DEVICES,
}

internal fun recordingCardBluetoothPermissionProfile(
    apiLevel: Int,
): RecordingCardBluetoothPermissionProfile = when {
    apiLevel >= Build.VERSION_CODES.S -> RecordingCardBluetoothPermissionProfile.NEARBY_DEVICES
    apiLevel >= Build.VERSION_CODES.M -> RecordingCardBluetoothPermissionProfile.LEGACY_LOCATION
    else -> RecordingCardBluetoothPermissionProfile.NONE
}

internal fun recordingCardBleRequiresLegacyLocation(apiLevel: Int): Boolean =
    recordingCardBluetoothPermissionProfile(apiLevel) ==
        RecordingCardBluetoothPermissionProfile.LEGACY_LOCATION

internal fun recordingCardBluetoothPermissionStatus(
    granted: Boolean,
    requestAttempted: Boolean,
    shouldShowRationale: Boolean,
): String = when {
    granted -> "granted"
    !requestAttempted -> "not_determined"
    shouldShowRationale -> "denied"
    else -> "blocked"
}

internal fun recordingCardShouldRetryInitialGattFailure(
    status: Int,
    completedRetries: Int,
): Boolean = completedRetries == 0 && (status == 8 || status == 133)

internal enum class RecordingCardBluetoothReadiness {
    READY,
    PERMISSION_REQUIRED,
    UNSUPPORTED,
    POWERED_OFF,
    LOCATION_SERVICES_DISABLED,
}

internal data class RecordingCardBluetoothFailure(
    val code: String,
    val permissionProblem: String,
    val safeMessage: String,
    val statusMessage: String,
)

internal fun RecordingCardBluetoothReadiness.failureOrNull(): RecordingCardBluetoothFailure? =
    when (this) {
        RecordingCardBluetoothReadiness.READY -> null
        RecordingCardBluetoothReadiness.PERMISSION_REQUIRED -> RecordingCardBluetoothFailure(
            code = "RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED",
            permissionProblem = "bluetooth_permission_required",
            safeMessage = "Bluetooth permission is required.",
            statusMessage = "需要蓝牙权限才能连接录音卡",
        )
        RecordingCardBluetoothReadiness.UNSUPPORTED -> RecordingCardBluetoothFailure(
            code = "RECORDING_CARD_BLUETOOTH_UNSUPPORTED",
            permissionProblem = "bluetooth_unsupported",
            safeMessage = "Bluetooth LE is not supported on this device.",
            statusMessage = "当前设备不支持蓝牙低功耗连接",
        )
        RecordingCardBluetoothReadiness.POWERED_OFF -> RecordingCardBluetoothFailure(
            code = "RECORDING_CARD_BLUETOOTH_POWERED_OFF",
            permissionProblem = "bluetooth_powered_off",
            safeMessage = "Bluetooth is powered off.",
            statusMessage = "蓝牙已关闭",
        )
        RecordingCardBluetoothReadiness.LOCATION_SERVICES_DISABLED ->
            RecordingCardBluetoothFailure(
                code = "RECORDING_CARD_LOCATION_SERVICES_DISABLED",
                permissionProblem = "location_services_disabled",
                safeMessage =
                    "System location services are required for Bluetooth discovery on this Android version.",
                statusMessage = "需要开启系统定位服务才能搜索录音卡",
            )
    }

internal class RecordingCardBluetoothAccess(
    private val context: Context,
) {
    val adapter: BluetoothAdapter?
        get() = context.getSystemService(BluetoothManager::class.java)?.adapter

    fun runtimePermissions(): Array<String> = when (
        recordingCardBluetoothPermissionProfile(Build.VERSION.SDK_INT)
    ) {
        RecordingCardBluetoothPermissionProfile.NEARBY_DEVICES -> arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
        )
        RecordingCardBluetoothPermissionProfile.LEGACY_LOCATION -> arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
        RecordingCardBluetoothPermissionProfile.NONE -> emptyArray()
    }

    fun connectionReadiness(): RecordingCardBluetoothReadiness = readiness(
        forDiscovery = false,
    )

    fun discoveryReadiness(): RecordingCardBluetoothReadiness = readiness(
        forDiscovery = true,
    )

    @SuppressLint("MissingPermission")
    private fun readiness(forDiscovery: Boolean): RecordingCardBluetoothReadiness {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return RecordingCardBluetoothReadiness.UNSUPPORTED
        }
        if (!hasBluetoothPermissions(forDiscovery)) {
            return RecordingCardBluetoothReadiness.PERMISSION_REQUIRED
        }
        val currentAdapter = adapter ?: return RecordingCardBluetoothReadiness.UNSUPPORTED
        if (!runCatching { currentAdapter.isEnabled }.getOrDefault(false)) {
            return RecordingCardBluetoothReadiness.POWERED_OFF
        }
        if (forDiscovery && !legacyLocationServicesEnabled()) {
            return RecordingCardBluetoothReadiness.LOCATION_SERVICES_DISABLED
        }
        return RecordingCardBluetoothReadiness.READY
    }

    private fun hasBluetoothPermissions(forDiscovery: Boolean): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val connectGranted = hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
            return connectGranted &&
                (!forDiscovery || hasPermission(Manifest.permission.BLUETOOTH_SCAN))
        }
        if (!hasPermission(Manifest.permission.BLUETOOTH) ||
            !hasPermission(Manifest.permission.BLUETOOTH_ADMIN)
        ) {
            return false
        }
        return !forDiscovery ||
            !recordingCardBleRequiresLegacyLocation(Build.VERSION.SDK_INT) ||
            hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun hasPermission(permission: String): Boolean =
        context.packageManager.checkPermission(permission, context.packageName) ==
            PackageManager.PERMISSION_GRANTED

    private fun legacyLocationServicesEnabled(): Boolean {
        if (!recordingCardBleRequiresLegacyLocation(Build.VERSION.SDK_INT)) return true
        val manager = context.getSystemService(LocationManager::class.java) ?: return false
        return LocationManagerCompat.isLocationEnabled(manager)
    }

    fun foregroundScanSettings(): ScanSettings = ScanSettings.Builder()
        .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
        .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
        .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
        .setReportDelay(0L)
        .build()

    @SuppressLint("MissingPermission")
    fun connectGatt(
        device: BluetoothDevice,
        callback: BluetoothGattCallback,
        handler: Handler,
    ): BluetoothGatt? = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> device.connectGatt(
            context,
            false,
            callback,
            BluetoothDevice.TRANSPORT_LE,
            BluetoothDevice.PHY_LE_1M_MASK,
            handler,
        )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> device.connectGatt(
            context,
            false,
            callback,
            BluetoothDevice.TRANSPORT_LE,
        )
        else -> device.connectGatt(context, false, callback)
    }

    fun locationSettingsIntent(): Intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
}
