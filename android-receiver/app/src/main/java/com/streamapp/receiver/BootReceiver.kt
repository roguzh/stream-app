package com.streamapp.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// BOOT_COMPLETED is one of the implicit broadcasts still delivered to manifest-declared
// receivers despite Android 8+'s background-execution limits, so this works without
// needing a foreground service. Keeps the Mi Box always ready without manually
// reopening the app after every reboot/power cycle.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(launchIntent)
    }
}
