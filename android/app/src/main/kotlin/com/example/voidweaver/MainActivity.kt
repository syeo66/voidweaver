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
    private var lastFocusRequestTime: Long = 0
    private val FOCUS_CHANGE_GRACE_PERIOD_MS = 300L
    
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
                "hasAudioFocus" -> {
                    // Return true if we have an active audio focus request
                    result.success(audioFocusRequest != null)
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
                    handleAudioFocusChange(focusChange)
                }
                .build()
            
            audioFocusRequest = focusRequest
            lastFocusRequestTime = System.currentTimeMillis()
            val result = audioManager.requestAudioFocus(focusRequest)
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            // Android 7.1 and below
            @Suppress("DEPRECATION")
            lastFocusRequestTime = System.currentTimeMillis()
            val result = audioManager.requestAudioFocus(
                { focusChange -> handleAudioFocusChange(focusChange) },
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
    
    private fun handleAudioFocusChange(focusChange: Int) {
        val timeSinceRequest = System.currentTimeMillis() - lastFocusRequestTime
        
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // Audio focus gained - safe to resume playback if needed
                android.util.Log.d("AudioFocus", "Focus gained")
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent loss - should stop playback
                // But ignore if it happens immediately after requesting focus (likely a conflict)
                if (timeSinceRequest > FOCUS_CHANGE_GRACE_PERIOD_MS) {
                    android.util.Log.d("AudioFocus", "Focus lost permanently")
                    // Let the app handle this through other means
                } else {
                    android.util.Log.d("AudioFocus", "Focus loss ignored - too soon after request ($timeSinceRequest ms)")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary loss - should pause playback
                // But ignore if it happens immediately after requesting focus
                if (timeSinceRequest > FOCUS_CHANGE_GRACE_PERIOD_MS) {
                    android.util.Log.d("AudioFocus", "Focus lost temporarily")
                    // Let the app handle this through other means
                } else {
                    android.util.Log.d("AudioFocus", "Transient focus loss ignored - too soon after request ($timeSinceRequest ms)")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Can lower volume instead of pausing
                android.util.Log.d("AudioFocus", "Focus lost - can duck")
            }
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
