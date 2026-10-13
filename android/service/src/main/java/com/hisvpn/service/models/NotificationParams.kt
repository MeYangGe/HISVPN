package com.hisvpn.service.models

data class NotificationParams(
    val title: String = "HISVPN",
    val stopText: String = "STOP",
    val onlyStatisticsProxy: Boolean = false,
    val showStopAction: Boolean = true,
)
