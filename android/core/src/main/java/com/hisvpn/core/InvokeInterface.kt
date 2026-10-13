package com.hisvpn.core

import androidx.annotation.Keep

@Keep
interface InvokeInterface {
    fun onResult(result: ByteArray?)
}