package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TencentLiveAsrAndroidBridgeTest {
    @Test
    fun checkedInStateListenerUsesOnlyOnStartRecordAsReadyBoundary() {
        val methods = Class.forName("com.tencent.aai.listener.AudioRecognizeStateListener")
            .declaredMethods
            .map { it.name }

        assertTrue("onStartRecord" in methods)
        assertTrue(isTencentRecognizerReadyCallback("onStartRecord"))
        assertTrue(!isTencentRecognizerReadyCallback("onVoiceVolume"))
        assertTrue(!isTencentRecognizerReadyCallback("onNextAudioData"))
        assertTrue(!isTencentRecognizerReadyCallback("onStopRecord"))
    }

    @Test
    fun diagnosticOutputIsBoundedAndDoesNotReflectThrowableMessage() {
        val diagnostic = formatTencentLiveAsrDiagnostic(
            "start_failed",
            IllegalStateException("token=should-not-be-logged"),
        )

        assertEquals(
            "[TencentLiveAsr] stage=start_failed cause=IllegalStateException",
            diagnostic,
        )
        assertTrue(!diagnostic.contains("should-not-be-logged"))
        assertEquals(
            "[TencentLiveAsr] stage=unknown cause=UnknownThrowable",
            formatTencentLiveAsrDiagnostic("unexpected-stage", RuntimeException("session=hidden")),
        )
    }

    @Test
    fun providerFailureClassificationKeepsOnlyBoundedPublicCauses() {
        assertEquals(
            "TENCENT_LIVE_ASR_NETWORK_FAILED",
            classifyTencentRecognitionFailure(-106, hasServerFailure = false),
        )
        assertEquals(
            "TENCENT_LIVE_ASR_MICROPHONE_BUSY",
            classifyTencentRecognitionFailure(-102, hasServerFailure = false),
        )
        assertEquals(
            "TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED",
            classifyTencentRecognitionFailure(-101, hasServerFailure = false),
        )
        assertEquals(
            "TENCENT_LIVE_ASR_PROVIDER_REJECTED",
            classifyTencentRecognitionFailure(null, hasServerFailure = true),
        )
        assertEquals(
            "TENCENT_LIVE_ASR_RECOGNITION_FAILED",
            classifyTencentRecognitionFailure(-1, hasServerFailure = false),
        )
        assertEquals(
            "[TencentLiveAsr] stage=recognition_failed clientCode=-106 serverFailure=false",
            formatTencentLiveAsrFailureDiagnostic(-106, hasServerFailure = false),
        )
    }

    @Test
    fun providerCodesDistinguishAuthenticationFromOtherRejections() {
        val categories = mapOf(
            4001 to "PROVIDER_REQUEST_INVALID",
            4002 to "PROVIDER_AUTH_FAILED",
            4003 to "PROVIDER_NOT_ENABLED",
            4004 to "PROVIDER_QUOTA_EXHAUSTED",
            4005 to "PROVIDER_SUSPENDED",
            4006 to "PROVIDER_RATE_LIMITED",
            4007 to "PROVIDER_AUDIO_INVALID",
            4008 to "AUDIO_SOURCE_TIMEOUT",
            4009 to "NETWORK_FAILED",
            4010 to "PROVIDER_REQUEST_INVALID",
            5000 to "PROVIDER_UNAVAILABLE",
            5001 to "PROVIDER_UNAVAILABLE",
            5002 to "PROVIDER_UNAVAILABLE",
            6001 to "PROVIDER_REGION_RESTRICTED",
            4999 to "PROVIDER_REJECTED",
        )
        categories.forEach { (providerCode, category) ->
            val raw = """{"code":$providerCode,"message":"token=must-stay-private"}"""
            val parsedCode = parseTencentProviderFailureCode(raw)
            assertEquals(providerCode, parsedCode)
            assertEquals(
                "TENCENT_LIVE_ASR_$category",
                classifyTencentRecognitionFailure(null, true, parsedCode),
            )
            assertEquals(
                "[TencentLiveAsr] stage=recognition_failed serverFailure=true providerCode=$providerCode",
                formatTencentLiveAsrFailureDiagnostic(null, true, parsedCode),
            )
            assertTrue(parseTencentRawRecognitionEvents(raw).isEmpty())
        }
        assertEquals(
            "TENCENT_LIVE_ASR_NETWORK_FAILED",
            classifyTencentRecognitionFailure(-106, true, 4002),
        )
        assertEquals(
            "TENCENT_LIVE_ASR_RECOGNITION_FAILED",
            classifyTencentRecognitionFailure(null, false, 4002),
        )
    }

    @Test
    fun providerFailureParserRejectsSuccessAndMalformedCodes() {
        val invalid = listOf(
            null,
            4002,
            "",
            "invalid-json",
            """{"message":"code=4002"}""",
            """{"code":0}""",
            """{"code":-4002}""",
            """{"code":4002.0}""",
            """{"code":"4002"}""",
            """{"code":true}""",
            """{"code":2147483648}""",
            """{"code":4002,"message":"${"x".repeat(1_000_000)}"}""",
        )
        invalid.forEach { raw ->
            assertNull(parseTencentProviderFailureCode(raw))
        }
        assertEquals(
            "[TencentLiveAsr] stage=recognition_failed serverFailure=false",
            formatTencentLiveAsrFailureDiagnostic(null, false, 4002),
        )
    }

    @Test
    fun checkedInAarClientSelectionUsesExactStringTokenOverload() {
        val clientClass = Class.forName("com.tencent.aai.AAIClient")
        val constructor = findTencentTokenClientConstructor(clientClass)

        assertEquals(2, clientClass.constructors.count { it.parameterTypes.size == 6 })
        assertNotNull(constructor)
        assertEquals(String::class.java, constructor?.parameterTypes?.last())
    }

    @Test
    fun checkedInAarResultListenerUsesRawAndFinalStringCallbacks() {
        val methods = Class.forName("com.tencent.aai.listener.AudioRecognizeResultListener")
            .declaredMethods
            .associate { it.name to it.parameterTypes.toList() }

        assertEquals(setOf("onSuccess", "onFailure", "onRawResponse"), methods.keys)
        assertEquals(String::class.java, methods.getValue("onSuccess").last())
        assertEquals(String::class.java, methods.getValue("onRawResponse").last())
        assertEquals(
            listOf(
                "com.tencent.aai.model.AudioRecognizeRequest",
                "com.tencent.aai.exception.ClientException",
                "com.tencent.aai.exception.ServerException",
                "java.lang.String",
            ),
            methods.getValue("onFailure").map { it.name },
        )
    }

    @Test
    fun nonFinalSliceBecomesPartialEvent() {
        assertEquals(
            mapOf(
                "type" to "partial",
                "sequence" to 3,
                "text" to "recognizing",
            ),
            parseTencentRawRecognitionEvent(
                rawEnvelope(
                    """{"voice_text_str":"recognizing","slice_type":1,"index":3}""",
                ),
            ),
        )
    }

    @Test
    fun completedSliceBecomesTimedStableSegment() {
        assertEquals(
            mapOf(
                "type" to "segment",
                "sequence" to 8,
                "text" to "stable text",
                "startMs" to 120,
                "endMs" to 920,
            ),
            parseTencentRawRecognitionEvent(
                rawEnvelope(
                    """{"voice_text_str":"stable text","slice_type":2,"index":8,"start_time":120,"end_time":920}""",
                ),
            ),
        )
    }

    @Test
    fun speakerSeparationEnvelopeEmitsBoundedSpeakerSentences() {
        assertEquals(
            listOf(
                mapOf(
                    "type" to "segment",
                    "sequence" to 0,
                    "text" to "第一位说话人",
                    "speakerId" to 2,
                ),
                mapOf(
                    "type" to "partial",
                    "sequence" to 1,
                    "text" to "暂未确定",
                ),
            ),
            parseTencentRawRecognitionEvents(
                """{"code":0,"sentences":{"sentence_list":[{"sentence_id":0,"sentence_type":1,"speaker_id":2,"sentence":"第一位说话人"},{"sentence_id":1,"sentence_type":0,"speaker_id":-1,"sentence":"暂未确定"}]}}""",
            ),
        )
    }

    @Test
    fun malformedSpeakerSeparationEnvelopeIsRejected() {
        assertTrue(
            parseTencentRawRecognitionEvents(
                """{"code":0,"sentences":{"sentence_list":[{"sentence_id":0,"sentence_type":1,"speaker_id":10,"sentence":"越界"}]}}""",
            ).isEmpty(),
        )
    }

    @Test
    fun finalAndFailedEnvelopesAreIgnored() {
        assertNull(
            parseTencentRawRecognitionEvent(
                """{"code":0,"final":1,"result":{"voice_text_str":"duplicate","slice_type":2,"index":9}}""",
            ),
        )
        assertNull(
            parseTencentRawRecognitionEvent(
                """{"code":0,"final":"1","result":{"voice_text_str":"duplicate","slice_type":2,"index":9}}""",
            ),
        )
        assertNull(
            parseTencentRawRecognitionEvent(
                """{"code":4000,"message":"failed","result":{"voice_text_str":"error text","slice_type":1,"index":2}}""",
            ),
        )
    }

    @Test
    fun finalSuccessEnvelopeEmitsItsLastStableSentence() {
        assertEquals(
            listOf(
                mapOf(
                    "type" to "segment",
                    "sequence" to 9,
                    "text" to "final sentence",
                ),
            ),
            parseTencentRawRecognitionEvents(
                """{"code":0,"final":1,"result":{"voice_text_str":"final sentence","slice_type":2,"index":9}}""",
                acceptFinalEnvelope = true,
            ),
        )
    }

    @Test
    fun plainSuccessTextIsAcceptedOnlyAsABoundedFallback() {
        assertEquals(
            listOf(
                mapOf(
                    "type" to "segment",
                    "sequence" to 0,
                    "text" to "完整识别文字",
                ),
            ),
            parseTencentSuccessRecognitionEvents("  完整识别文字  "),
        )
        assertTrue(
            parseTencentSuccessRecognitionEvents(
                "完整识别文字",
                acceptPlainText = false,
            ).isEmpty(),
        )
        assertTrue(parseTencentSuccessRecognitionEvents("{malformed").isEmpty())
        assertTrue(
            parseTencentSuccessRecognitionEvents("x".repeat(100_001)).isEmpty(),
        )
    }

    @Test
    fun malformedOrOutOfBoundsPayloadsAreRejected() {
        val invalidPayloads = listOf<Any?>(
            null,
            1,
            "",
            "{",
            "{}",
            rawEnvelope("""{"voice_text_str":"text","slice_type":3,"index":1}"""),
            rawEnvelope("""{"voice_text_str":"text","slice_type":1,"index":-1}"""),
            rawEnvelope("""{"voice_text_str":"   ","slice_type":1,"index":1}"""),
            rawEnvelope(
                """{"voice_text_str":"text","slice_type":1,"index":1,"start_time":-1}""",
            ),
            rawEnvelope("""{"voice_text_str":"text","slice_type":1.5,"index":1}"""),
            rawEnvelope(
                """{"voice_text_str":"${"x".repeat(100_001)}","slice_type":1,"index":1}""",
            ),
        )

        invalidPayloads.forEach { assertNull(parseTencentRawRecognitionEvent(it)) }
    }

    @Test
    fun sharedRecorderPcmCopiesSamplesAndDoesNotLeakAcrossCaptureSessions() {
        val source = SharedTencentPcmSource(maximumBufferedSamples = 8)
        source.beginCapture()
        source.append(byteArrayOf(1, 0, 2, 0, 3, 0, 4, 0), 8)
        val proxy = source.newProxy()
        assertNotNull(proxy)
        val dataSource = proxy as com.tencent.aai.audio.data.PcmAudioDataSource
        dataSource.start()
        val target = ShortArray(4)
        assertEquals(4, dataSource.read(target, 4))
        assertTrue(target.contentEquals(shortArrayOf(1, 2, 3, 4)))
        source.endCapture(clearBufferedSamples = true)
        assertEquals(-1, dataSource.read(ShortArray(1), 1))

        source.beginCapture()
        val nextProxy = source.newProxy()
        assertNotNull(nextProxy)
        (nextProxy as com.tencent.aai.audio.data.PcmAudioDataSource).stop()
    }

    @Test
    fun sharedRecorderPcmReturnsCompleteFortyMillisecondFrames() {
        val source = SharedTencentPcmSource(maximumBufferedSamples = 1_024)
        source.beginCapture()
        val bytes = ByteArray(640 * 2)
        repeat(640) { index ->
            bytes[index * 2] = (index and 0xff).toByte()
            bytes[index * 2 + 1] = ((index ushr 8) and 0xff).toByte()
        }
        source.append(bytes, 320 * 2)
        val proxy = source.newProxy()
        assertNotNull(proxy)
        val dataSource = proxy as com.tencent.aai.audio.data.PcmAudioDataSource
        val target = ShortArray(640)

        assertEquals(0, dataSource.read(target, target.size))
        source.append(bytes.copyOfRange(320 * 2, bytes.size), 320 * 2)
        assertEquals(target.size, dataSource.read(target, target.size))
        assertEquals(0, target.first().toInt())
        assertEquals(639, target[639].toInt())

        source.append(bytes, 320 * 2)
        source.endCapture(clearBufferedSamples = false)
        assertEquals(-1, dataSource.read(target, target.size))
    }

    private fun rawEnvelope(result: String): String =
        """{"code":0,"message":"success","voice_id":"voice-1","result":$result}"""
}
