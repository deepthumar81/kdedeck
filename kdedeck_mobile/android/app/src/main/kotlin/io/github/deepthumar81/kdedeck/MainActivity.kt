package io.github.deepthumar81.kdedeck

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "io.github.deepthumar81.kdedeck/onboarding"
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "discoverKdeDeck") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                discover(result, (call.argument<Int>("timeoutMs") ?: 5000).coerceIn(500, 15000))
            }
    }

    private fun discover(result: MethodChannel.Result, timeoutMs: Int) {
        val nsd = getSystemService(NSD_SERVICE) as NsdManager
        acquireMulticastLock()
        val found = mutableListOf<Map<String, Any>>()
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        fun finish() {
            if (finished) return
            finished = true
            discoveryListener?.let { listener ->
                runCatching { nsd.stopServiceDiscovery(listener) }
            }
            discoveryListener = null
            releaseMulticastLock()
            result.success(found)
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = finish()
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val address = info.host ?: return
                        val host = address.hostAddress ?: return
                        // The Dart side repeats endpoint validation and only
                        // allows TLS enrollment for a remote host.
                        if (info.port !in 1..65535 || host.isBlank()) return
                        val name = info.serviceName.ifBlank { "KDE Deck PC" }
                        synchronized(found) {
                            if (found.none { it["host"] == host && it["port"] == info.port }) {
                                found.add(mapOf("name" to name, "host" to host, "port" to info.port))
                            }
                        }
                    }
                })
            }
        }
        discoveryListener = listener
        handler.postDelayed({ finish() }, timeoutMs.toLong())
        runCatching { nsd.discoverServices("_kde-deck._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { finish() }
    }

    override fun onDestroy() {
        discoveryListener?.let { listener ->
            val nsd = getSystemService(NSD_SERVICE) as NsdManager
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        discoveryListener = null
        releaseMulticastLock()
        super.onDestroy()
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        multicastLock = runCatching {
            wifi.createMulticastLock("kdedeck-nsd").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) runCatching { lock.release() }
        }
        multicastLock = null
    }
}
