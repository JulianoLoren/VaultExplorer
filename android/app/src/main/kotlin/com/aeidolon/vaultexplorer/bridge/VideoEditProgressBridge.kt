package com.aeidolon.vaultexplorer.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Pushes Video Editor export progress from `VideoEditHandlers` to Dart,
 * mirroring [SplitJoinProgressBridge]. Event name: `"onVideoEditProgress"`.
 *
 * [phase] is `"cutting"` (stream-copying samples into the temp file) or
 * `"saving"` (moving the finished temp file into the vault / folder);
 * [fraction] is 0..1 within that phase for output number [outputIndex]
 * (0-based) out of [outputCount].
 */
object VideoEditProgressBridge {
    @Volatile
    var channel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    @JvmStatic
    fun reportProgress(opId: Int, outputIndex: Int, outputCount: Int, phase: String, fraction: Float) {
        val ch = channel ?: return
        mainHandler.post {
            ch.invokeMethod(
                "onVideoEditProgress",
                mapOf(
                    "opId" to opId,
                    "outputIndex" to outputIndex,
                    "outputCount" to outputCount,
                    "phase" to phase,
                    "fraction" to fraction.toDouble(),
                ),
            )
        }
    }
}
