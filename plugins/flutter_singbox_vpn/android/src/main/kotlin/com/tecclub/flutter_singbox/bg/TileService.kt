package com.tecclub.flutter_singbox.bg

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.annotation.RequiresApi
import com.tecclub.flutter_singbox.constant.Status

@RequiresApi(Build.VERSION_CODES.N)
class TileService : TileService(), ServiceConnection.Callback {
    
    companion object {
        private const val TAG = "TileService"
    }

    private val connection = ServiceConnection(this, this)

    override fun onServiceStatusChanged(status: Status) {
        qsTile?.apply {
            state = when (status) {
                Status.Started -> Tile.STATE_ACTIVE
                Status.Stopped -> Tile.STATE_INACTIVE
                else -> Tile.STATE_UNAVAILABLE
            }
            updateTile()
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        Log.d(TAG, "Start listening")
        connection.connect()
    }

    override fun onStopListening() {
        Log.d(TAG, "Stop listening")
        connection.disconnect()
        super.onStopListening()
    }

    override fun onClick() {
        Log.d(TAG, "Tile clicked, status: ${connection.status}")
        when (connection.status) {
            Status.Stopped -> {
                BoxService.start()
            }
            Status.Started -> {
                BoxService.stop()
            }
            else -> {
                // Don't do anything if the service is in a transitional state
            }
        }
    }
}
