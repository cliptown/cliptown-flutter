import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("release", ignoreCase = true)
}

val requiredReleaseEnvironment: (String) -> String = { name ->
    val value = providers.environmentVariable(name).orNull?.trim().orEmpty()
    if (value.isEmpty()) {
        throw GradleException(
            "$name is required for Android release builds. " +
                "Provision it through the protected mobile-release environment.",
        )
    }
    value
}

val releaseSigningValues = if (releaseTaskRequested) {
    val keystorePath = requiredReleaseEnvironment("CLIPTOWN_ANDROID_KEYSTORE_PATH")
    val keystoreFile = file(keystorePath)
    if (!keystoreFile.isFile) {
        throw GradleException(
            "CLIPTOWN_ANDROID_KEYSTORE_PATH must reference an existing non-committed keystore file.",
        )
    }

    mapOf(
        "storePath" to keystoreFile.absolutePath,
        "storePassword" to requiredReleaseEnvironment("CLIPTOWN_ANDROID_KEYSTORE_PASSWORD"),
        "keyAlias" to requiredReleaseEnvironment("CLIPTOWN_ANDROID_KEY_ALIAS"),
        "keyPassword" to requiredReleaseEnvironment("CLIPTOWN_ANDROID_KEY_PASSWORD"),
    )
} else {
    emptyMap()
}

android {
    namespace = "com.cliptown.cliptown_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // This is the durable Google Play / Android developer-verification identity.
        applicationId = "com.cliptown.cliptown_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // universal_ble's Android backend requires API 24. Keeping this
        // explicit prevents a dependency update from silently changing the
        // minimum supported ClipTown device.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseTaskRequested) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("storePath"))
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseTaskRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
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
