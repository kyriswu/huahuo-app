package com.hangzhouchuda.huahuoai

internal object PaymentContract {
    private val safeOrderId = Regex("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
    private val providers = setOf("wechat", "alipay")
    private val clientResults = setOf("returned", "cancelled", "unavailable", "failed")

    fun validOrderId(value: String?): Boolean = value != null && safeOrderId.matches(value)

    fun validProvider(value: String): Boolean = providers.contains(value)

    fun advisoryEvent(
        provider: String,
        orderId: String,
        result: String,
        clientCode: String? = null,
    ): Map<String, String> {
        require(validProvider(provider))
        require(validOrderId(orderId))
        require(clientResults.contains(result))
        return buildMap {
            put("provider", provider)
            put("orderId", orderId)
            put("result", result)
            clientCode?.takeIf { it.matches(Regex("^-?[A-Za-z0-9_]{1,32}$")) }?.let {
                put("clientCode", it)
            }
        }
    }
}
