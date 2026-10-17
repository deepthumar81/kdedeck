plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.deepthumar81.kdedeck"
    compileSdk = 36

    // Validation builds deliberately use the Android debug key so that CI and
    // contributors can build without access to the private release key. A
    // production-signed build must opt in explicitly and provide every input;
    // a partial or missing configuration fails during Gradle configuration.
    val signingRequired = providers.environmentVariable("KDEDECK_ANDROID_SIGNING_REQUIRED")
        .orNull
        ?.equals("true", ignoreCase = true) == true
    val keystorePath = providers.environmentVariable("KDEDECK_ANDROID_KEYSTORE_PATH").orNull
    val keystorePassword = providers.environmentVariable("KDEDECK_ANDROID_KEYSTORE_PASSWORD").orNull
    val keyAlias = providers.environmentVariable("KDEDECK_ANDROID_KEY_ALIAS").orNull
    val keyPassword = providers.environmentVariable("KDEDECK_ANDROID_KEY_PASSWORD").orNull
    val signingInputs = listOf(keystorePath, keystorePassword, keyAlias, keyPassword)

    require(!signingInputs.any { !it.isNullOrBlank() } || signingRequired) {
        "Android signing inputs are set but KDEDECK_ANDROID_SIGNING_REQUIRED is not true"
    }

    if (signingRequired) {
        val requiredKeystorePath = keystorePath?.takeIf { it.isNotBlank() }
            ?: error("KDEDECK_ANDROID_KEYSTORE_PATH is required for a signed release")
        val requiredKeystorePassword = keystorePassword?.takeIf { it.isNotBlank() }
            ?: error("KDEDECK_ANDROID_KEYSTORE_PASSWORD is required for a signed release")
        val requiredKeyAlias = keyAlias?.takeIf { it.isNotBlank() }
            ?: error("KDEDECK_ANDROID_KEY_ALIAS is required for a signed release")
        val requiredKeyPassword = keyPassword?.takeIf { it.isNotBlank() }
            ?: error("KDEDECK_ANDROID_KEY_PASSWORD is required for a signed release")
        val keystoreFile = file(requiredKeystorePath)
        require(keystoreFile.isFile && keystoreFile.length() > 0) {
            "KDEDECK_ANDROID_KEYSTORE_PATH must point to a non-empty keystore file"
        }

        signingConfigs.create("production") {
            storeFile = keystoreFile
            storePassword = requiredKeystorePassword
            this.keyAlias = requiredKeyAlias
            this.keyPassword = requiredKeyPassword
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.deepthumar81.kdedeck"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (signingRequired) "production" else "debug")
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
