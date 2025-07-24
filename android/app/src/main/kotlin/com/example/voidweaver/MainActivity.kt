package com.example.voidweaver

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "voidweaver/audio_focus"
    private lateinit var audioManager: AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        
        // Create high-priority notification channel for media controls
        createNotificationChannel()
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAudioFocus" -> {
                    val focusResult = requestAudioFocus()
                    result.success(focusResult)
                }
                "abandonAudioFocus" -> {
                    val abandonResult = abandonAudioFocus()
                    result.success(abandonResult) 
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
    
    private fun requestAudioFocus(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Android 8.0 and above
            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener { focusChange ->
                    // Handle focus changes if needed
                    when (focusChange) {
                        AudioManager.AUDIOFOCUS_GAIN -> {
                            // Resume playback
                        }
                        AudioManager.AUDIOFOCUS_LOSS -> {
                            // Stop playback
                        }
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                            // Pause playback
                        }
                    }
                }
                .build()
            
            audioFocusRequest = focusRequest
            val result = audioManager.requestAudioFocus(focusRequest)
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            // Android 7.1 and below
            @Suppress("DEPRECATION")
            val result = audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }
    
    private fun abandonAudioFocus(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { request ->
                val result = audioManager.abandonAudioFocusRequest(request)
                audioFocusRequest = null
                result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } ?: true
        } else {
            @Suppress("DEPRECATION")
            val result = audioManager.abandonAudioFocus(null)
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "com.voidweaver.audio",
                "Voidweaver Audio",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Voidweaver music playback controls"
                setShowBadge(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
            
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
}
