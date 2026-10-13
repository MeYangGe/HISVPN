package com.hisvpn

import android.app.Application
import android.content.Context
import com.hisvpn.common.GlobalState

class HISVPNApplication : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        GlobalState.init(this)
    }
}
