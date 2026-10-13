package com.hisvpn.service

import android.app.Service
import com.hisvpn.common.BroadcastAction
import com.hisvpn.common.GlobalState
import com.hisvpn.common.sendBroadcast

interface ManagedService {
    fun start()

    fun stop()
}

internal fun Service.notifyVpnStartRequested() {
    GlobalState.log("VPN start requested")
    BroadcastAction.VPN_START_REQUESTED.sendBroadcast()
}

internal fun Service.notifyVpnRevoked() {
    GlobalState.log("VPN permission revoked")
    BroadcastAction.VPN_REVOKED.sendBroadcast()
}
