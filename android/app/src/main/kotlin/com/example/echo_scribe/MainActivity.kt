package com.example.echo_scribe

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dart-side result parked while the location permission dialog is up. */
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        setupRecordingChannel(engine)
        setupLocationChannel(engine)
    }

    private fun setupRecordingChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, RECORDING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // The service's notification is user-visible on 13+;
                        // ask up front — denial only hides the notification.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQUEST_NOTIFICATIONS,
                            )
                        }
                        try {
                            val intent = Intent(this, RecordingService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("fgs_failed", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, RecordingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun setupLocationChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, LOCATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestLocationPermission(result)
                    "getLocation" -> thread {
                        val location = fetchLocation()
                        mainHandler.post { result.success(location) }
                    }
                    "openMap" -> openMap(
                        call.argument<Number>("lat")?.toDouble(),
                        call.argument<Number>("lon")?.toDouble(),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        val permissions = arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (permissions.any {
                checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }
        ) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        requestPermissions(permissions, REQUEST_LOCATION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_LOCATION) return
        pendingPermissionResult?.success(
            grantResults.isNotEmpty() &&
                grantResults.any { it == PackageManager.PERMISSION_GRANTED },
        )
        pendingPermissionResult = null
    }

    /**
     * One-shot best-effort fix for tagging a recording: newest cached
     * location, a short fresh fix when the cache is stale/empty, then a
     * reverse geocode for a readable address. Blocking (geocoding hits
     * the network) — must run off the main thread. Framework APIs only,
     * so it works without Google services. Null when nothing is available.
     */
    private fun fetchLocation(): Map<String, Any?>? {
        val lm = getSystemService(LocationManager::class.java) ?: return null
        val lastKnown = runCatching {
            lm.getProviders(true)
                .mapNotNull { lm.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
        }.getOrNull()
        val fix =
            lastKnown?.takeIf { System.currentTimeMillis() - it.time < STALE_MS }
                ?: currentFix(lm)
                ?: lastKnown // a stale fix still identifies the place
                ?: return null

        var address: String? = null
        if (runCatching { Geocoder.isPresent() }.getOrDefault(false)) {
            address = runCatching {
                @Suppress("DEPRECATION") // sync variant; we're off the main thread
                Geocoder(this).getFromLocation(fix.latitude, fix.longitude, 1)
                    ?.firstOrNull()
                    ?.let(::formatAddress)
            }.getOrNull()
        }
        return mapOf(
            "lat" to fix.latitude,
            "lon" to fix.longitude,
            "accuracy" to fix.accuracy.toDouble(),
            "address" to address,
        )
    }

    /** Short fresh fix (API 30+) so indoor Wi-Fi/cell locations still land. */
    private fun currentFix(lm: LocationManager): Location? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val provider = listOf("network", "gps").firstOrNull {
            runCatching { lm.isProviderEnabled(it) }.getOrDefault(false)
        } ?: return null
        val latch = CountDownLatch(1)
        var fix: Location? = null
        val started = runCatching {
            lm.getCurrentLocation(provider, null, Runnable::run) { location ->
                fix = location
                latch.countDown()
            }
        }.isSuccess
        if (!started || !latch.await(FIX_TIMEOUT_SECONDS, TimeUnit.SECONDS)) return null
        return fix
    }

    private fun formatAddress(address: Address): String =
        listOfNotNull(
            address.locality ?: address.adminArea,
            address.subLocality,
            address.thoroughfare ?: address.featureName,
            address.subThoroughfare,
        ).joinToString("")

    private fun openMap(lat: Double?, lon: Double?, result: MethodChannel.Result) {
        if (lat == null || lon == null) {
            result.error("bad_args", "lat/lon required", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lon?q=$lat,$lon")),
            )
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    companion object {
        private const val RECORDING_CHANNEL = "echo_scribe/background"
        private const val LOCATION_CHANNEL = "echo_scribe/location"
        private const val REQUEST_NOTIFICATIONS = 1
        private const val REQUEST_LOCATION = 2
        private const val STALE_MS = 2 * 60_000L
        private const val FIX_TIMEOUT_SECONDS = 5L
    }
}
