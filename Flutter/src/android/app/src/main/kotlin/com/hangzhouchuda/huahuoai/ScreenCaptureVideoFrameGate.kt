package com.hangzhouchuda.huahuoai

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

internal class ScreenCaptureVideoFrameGate(
    private val encoderSurface: Surface,
    private val width: Int,
    private val height: Int,
    maximumFrameRate: Int,
    private val readPowerState: () -> ScreenCapturePowerState,
) : AutoCloseable {
    private val budget = ScreenCaptureFrameBudget(maximumFrameRate)
    private val pendingFrame = AtomicBoolean(false)
    private val textureTransform = FloatArray(16)
    private val vertices = ByteBuffer.allocateDirect(16 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(
                -1f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                -1f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            ))
            position(0)
        }
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var sourceTexture: SurfaceTexture? = null
    private var sourceSurface: Surface? = null
    private var textureName = 0
    private var program = 0
    private var positionLocation = -1
    private var coordinateLocation = -1
    private var transformLocation = -1
    private var samplerLocation = -1
    private var lastPowerSampleAt: Long? = null
    private var lastPresentationTime = -1L
    private var closed = false

    val surface: Surface get() = checkNotNull(sourceSurface)

    init {
        try {
            initialize()
        } catch (failure: Throwable) {
            close()
            throw failure
        }
    }

    private fun initialize() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY)
        val versions = IntArray(2)
        check(EGL14.eglInitialize(display, versions, 0, versions, 1))
        val configurations = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        ), 0, configurations, 0, 1, count, 0) && count[0] > 0)
        val configuration = checkNotNull(configurations[0])
        context = EGL14.eglCreateContext(display, configuration, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT)
        window = EGL14.eglCreateWindowSurface(display, configuration, encoderSurface,
            intArrayOf(EGL14.EGL_NONE), 0)
        check(window != EGL14.EGL_NO_SURFACE)
        check(EGL14.eglMakeCurrent(display, window, window, context))

        program = createProgram()
        positionLocation = GLES20.glGetAttribLocation(program, "aPosition")
        coordinateLocation = GLES20.glGetAttribLocation(program, "aTextureCoordinate")
        transformLocation = GLES20.glGetUniformLocation(program, "uTextureTransform")
        samplerLocation = GLES20.glGetUniformLocation(program, "uTexture")
        check(listOf(positionLocation, coordinateLocation, transformLocation, samplerLocation).all { it >= 0 })
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureName = textures[0]
        check(textureName != 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureName)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        val texture = SurfaceTexture(textureName)
        sourceTexture = texture
        texture.setDefaultBufferSize(width, height)
        texture.setOnFrameAvailableListener({ pendingFrame.set(true) }, Handler(Looper.getMainLooper()))
        sourceSurface = Surface(texture)
    }

    fun drawPendingFrame(force: Boolean = false) {
        if (closed || (!force && !pendingFrame.get())) return
        val now = SystemClock.elapsedRealtimeNanos()
        val previousSample = lastPowerSampleAt
        if (previousSample == null || now - previousSample >= 1_000_000_000L) {
            lastPowerSampleAt = now
            runCatching { readPowerState() }.getOrNull()?.let { budget.update(it, now) }
        }
        if (!force && !budget.shouldRender(now)) return
        pendingFrame.set(false)
        val texture = checkNotNull(sourceTexture)
        texture.updateTexImage()
        val timestamp = texture.timestamp
        if (timestamp <= lastPresentationTime || timestamp <= 0L) return
        texture.getTransformMatrix(textureTransform)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureName)
        GLES20.glUniform1i(samplerLocation, 0)
        GLES20.glUniformMatrix4fv(transformLocation, 1, false, textureTransform, 0)
        vertices.position(0)
        GLES20.glEnableVertexAttribArray(positionLocation)
        GLES20.glVertexAttribPointer(positionLocation, 2, GLES20.GL_FLOAT, false, 16, vertices)
        vertices.position(2)
        GLES20.glEnableVertexAttribArray(coordinateLocation)
        GLES20.glVertexAttribPointer(coordinateLocation, 2, GLES20.GL_FLOAT, false, 16, vertices)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        check(EGLExt.eglPresentationTimeANDROID(display, window, timestamp))
        check(EGL14.eglSwapBuffers(display, window))
        lastPresentationTime = timestamp
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { sourceTexture?.setOnFrameAvailableListener(null) }
        runCatching { sourceSurface?.release() }
        runCatching { sourceTexture?.release() }
        sourceSurface = null
        sourceTexture = null
        pendingFrame.set(false)
        if (display != EGL14.EGL_NO_DISPLAY) {
            if (context != EGL14.EGL_NO_CONTEXT && window != EGL14.EGL_NO_SURFACE &&
                EGL14.eglMakeCurrent(display, window, window, context)) {
                if (program != 0) GLES20.glDeleteProgram(program)
                if (textureName != 0) GLES20.glDeleteTextures(1, intArrayOf(textureName), 0)
            }
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        window = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
        program = 0
        textureName = 0
    }

    private fun createProgram(): Int {
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        var fragmentShader = 0
        var linkedProgram = 0
        try {
            fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
            linkedProgram = GLES20.glCreateProgram()
            check(linkedProgram != 0)
            GLES20.glAttachShader(linkedProgram, vertexShader)
            GLES20.glAttachShader(linkedProgram, fragmentShader)
            GLES20.glLinkProgram(linkedProgram)
            val status = IntArray(1)
            GLES20.glGetProgramiv(linkedProgram, GLES20.GL_LINK_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE)
            return linkedProgram
        } catch (failure: Throwable) {
            if (linkedProgram != 0) GLES20.glDeleteProgram(linkedProgram)
            throw failure
        } finally {
            GLES20.glDeleteShader(vertexShader)
            if (fragmentShader != 0) GLES20.glDeleteShader(fragmentShader)
        }
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        check(shader != 0)
        try {
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE)
            return shader
        } catch (failure: Throwable) {
            GLES20.glDeleteShader(shader)
            throw failure
        }
    }

    companion object {
        private const val EGL_RECORDABLE_ANDROID = 0x3142
        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoordinate;
            uniform mat4 uTextureTransform;
            varying vec2 vTextureCoordinate;
            void main() {
                gl_Position = aPosition;
                vTextureCoordinate = (uTextureTransform * aTextureCoordinate).xy;
            }
        """
        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            varying vec2 vTextureCoordinate;
            void main() {
                gl_FragColor = texture2D(uTexture, vTextureCoordinate);
            }
        """
    }
}
