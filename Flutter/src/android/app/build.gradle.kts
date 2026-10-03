import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Properties
import java.util.jar.JarInputStream
import java.util.zip.ZipFile

val huahuoApplicationId = "com.hangzhouchuda.huahuoai"

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use(::load)
    }
}

fun buildValue(gradleName: String, environmentName: String, propertyName: String): String? {
    return providers.gradleProperty(gradleName).orNull?.trim()?.takeIf(String::isNotEmpty)
        ?: providers.environmentVariable(environmentName).orNull?.trim()?.takeIf(String::isNotEmpty)
        ?: releaseProperties.getProperty(propertyName)?.trim()?.takeIf(String::isNotEmpty)
}

fun flutterDartDefine(name: String): String? {
    val encodedDefines = providers.gradleProperty("dart-defines").orNull ?: return null
    return encodedDefines.split(',').asSequence()
        .mapNotNull { encoded ->
            runCatching {
                String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8)
            }.getOrNull()
        }
        .map { define -> define.split('=', limit = 2) }
        .firstOrNull { parts -> parts.size == 2 && parts[0] == name }
        ?.get(1)
        ?.trim()
        ?.takeIf(String::isNotEmpty)
}

val formalApiBaseUrl = buildValue(
    "HUAHUO_API_BASE_URL",
    "HUAHUO_API_BASE_URL",
    "apiBaseUrl",
) ?: "https://chuda.cc"

fun encodedFlutterDartDefine(name: String, value: String): String =
    Base64.getEncoder().encodeToString("$name=$value".toByteArray(StandardCharsets.UTF_8))

val configuredFlutterDartDefines =
    providers.gradleProperty("dart-defines").orNull
        ?.split(',')
        ?.filter(String::isNotBlank)
        ?.toMutableList()
        ?: mutableListOf()
val hasFormalApiBaseUrl = configuredFlutterDartDefines.any { encoded ->
    runCatching {
        String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8)
    }.getOrNull()?.startsWith("HUAHUO_API_BASE_URL=") == true
}
if (!hasFormalApiBaseUrl) {
    configuredFlutterDartDefines += encodedFlutterDartDefine(
        "HUAHUO_API_BASE_URL",
        formalApiBaseUrl,
    )
}

val releaseStoreFile = buildValue(
    "HUAHUO_ANDROID_STORE_FILE",
    "HUAHUO_ANDROID_STORE_FILE",
    "storeFile",
)
val releaseStorePassword = buildValue(
    "HUAHUO_ANDROID_STORE_PASSWORD",
    "HUAHUO_ANDROID_STORE_PASSWORD",
    "storePassword",
)
val releaseKeyAlias = buildValue(
    "HUAHUO_ANDROID_KEY_ALIAS",
    "HUAHUO_ANDROID_KEY_ALIAS",
    "keyAlias",
)
val releaseKeyPassword = buildValue(
    "HUAHUO_ANDROID_KEY_PASSWORD",
    "HUAHUO_ANDROID_KEY_PASSWORD",
    "keyPassword",
)
val releaseSigningConfigured = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }
val jpushAppKey = flutterDartDefine("JPUSH_APP_KEY")
    ?: providers.gradleProperty("JPUSH_APP_KEY").orNull
    ?: providers.environmentVariable("JPUSH_APP_KEY").orNull
    ?: ""
val jpushChannel = flutterDartDefine("JPUSH_CHANNEL")
    ?: providers.gradleProperty("JPUSH_CHANNEL").orNull
    ?: providers.environmentVariable("JPUSH_CHANNEL").orNull
    ?: "huahuo-production"

android {
    namespace = huahuoApplicationId
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = huahuoApplicationId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["JPUSH_PKGNAME"] = huahuoApplicationId
        manifestPlaceholders["JPUSH_APPKEY"] = jpushAppKey
        manifestPlaceholders["JPUSH_CHANNEL"] = jpushChannel
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

val verifyTencentRealtimeAsrAar by tasks.registering {
    group = "verification"
    description = "Verifies classes reflectively loaded from the Tencent realtime-ASR AAR."
    doLast {
        val artifact = file("libs/asr-realtime-speakerSeparation-release.aar")
        check(artifact.isFile) {
            "Tencent realtime-ASR AAR is missing: ${artifact.path}"
        }
        val requiredClasses = setOf(
            "com/tencent/aai/AAIClient.class",
            "com/tencent/aai/audio/data/PcmAudioDataSource.class",
            "com/tencent/aai/model/AudioRecognizeRequest\$Builder.class",
            "com/tencent/aai/model/AudioRecognizeConfiguration\$Builder.class",
            "com/tencent/aai/listener/AudioRecognizeResultListener.class",
            "com/tencent/aai/listener/AudioRecognizeStateListener.class",
        )
        val classes = ZipFile(artifact).use { aar ->
            val classesJar = aar.getEntry("classes.jar")
                ?: error("Tencent realtime-ASR AAR has no classes.jar")
            JarInputStream(aar.getInputStream(classesJar)).use { jar ->
                buildSet {
                    while (true) {
                        val entry = jar.nextJarEntry ?: break
                        add(entry.name)
                    }
                }
            }
        }
        val missing = requiredClasses - classes
        check(missing.isEmpty()) {
            "Tencent realtime-ASR AAR is incompatible; missing ${missing.sorted().joinToString()}"
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyTencentRealtimeAsrAar)
    doFirst {
        check(releaseSigningConfigured) {
            "Android release signing is not configured. Supply key.properties or HUAHUO_ANDROID_* values."
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Flutter reads this project property while configuring each compile task.
// Preserve a caller-supplied Define, then supply the formal default otherwise.
project.extensions.extraProperties["dart-defines"] = configuredFlutterDartDefines.joinToString(",")

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20180813")
    implementation("com.squareup.okhttp3:okhttp:4.2.2")
    implementation(files("libs/asr-realtime-speakerSeparation-release.aar"))
}
