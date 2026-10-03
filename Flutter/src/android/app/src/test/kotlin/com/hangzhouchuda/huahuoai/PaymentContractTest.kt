package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PaymentContractTest {
    @Test
    fun validatesOnlySafeInternalOrderIdentifiers() {
        assertTrue(PaymentContract.validOrderId("order_abc-123"))
        assertFalse(PaymentContract.validOrderId("../order"))
        assertFalse(PaymentContract.validOrderId("order secret"))
        assertFalse(PaymentContract.validOrderId(null))
    }

    @Test
    fun advisoryEventContainsNoProviderPayloadOrTrustedSuccess() {
        val event = PaymentContract.advisoryEvent(
            provider = "wechat",
            orderId = "order_1",
            result = "returned",
            clientCode = "0",
        )

        assertEquals("returned", event["result"])
        assertNull(event["sign"])
        assertNull(event["orderString"])
        assertNull(event["success"])
    }

    @Test
    fun rejectsUnknownProviderAndResult() {
        assertThrows(IllegalArgumentException::class.java) {
            PaymentContract.advisoryEvent("unknown", "order_1", "returned")
        }
        assertThrows(IllegalArgumentException::class.java) {
            PaymentContract.advisoryEvent("alipay", "order_1", "succeeded")
        }
    }
}
