package com.vasant.whatsapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import android.widget.ImageView

class FloatingBubbleService : Service() {
    private var windowManager: WindowManager? = null
    private var bubble: ImageView? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            stopSelf()
            return
        }
        createChannel()
        startForeground(7401, notification())
        showBubble()
    }

    private fun showBubble() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        bubble = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            alpha = 0.10f
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = ColorDrawable(Color.TRANSPARENT)
            elevation = 12f
            setOnTouchListener { view, event ->
                val params = view.layoutParams as WindowManager.LayoutParams
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = event.rawX
                        downY = event.rawY
                        startX = params.x
                        startY = params.y
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        params.x = startX + (event.rawX - downX).toInt()
                        params.y = startY + (event.rawY - downY).toInt()
                        windowManager?.updateViewLayout(view, params)
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (kotlin.math.abs(event.rawX - downX) < 12 && kotlin.math.abs(event.rawY - downY) < 12) {
                            val launch = packageManager.getLaunchIntentForPackage(packageName)
                            launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            if (launch != null) startActivity(launch)
                        }
                        true
                    }
                    else -> true
                }
            }
        }
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(58, 58, type, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - 90
            y = 220
        }
        windowManager?.addView(bubble, params)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("whatsreply_bubble", "WhatsReply bubble", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun notification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(this, 7401, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, "whatsreply_bubble").setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("WhatsReply bubble active").setContentText("Tap the WR bubble to open the app").setContentIntent(pending).setOngoing(true).build()
        } else {
            Notification.Builder(this).setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("WhatsReply bubble active").setContentText("Tap the WR bubble to open the app").setContentIntent(pending).setOngoing(true).build()
        }
    }

    override fun onDestroy() {
        bubble?.let { windowManager?.removeView(it) }
        bubble = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
