plugins { id("com.android.application") }

android {
    namespace = "com.qemut8030.launcher"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.qemut8030.launcher"
        minSdk = 26
        targetSdk = 35
        versionCode = 50
        versionName = "1.7.0"
    }
    // Committed debug key (standard "android" passwords) so every build signs
    // the same and installs over the previous one without an uninstall.
    signingConfigs {
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes {
        release { isMinifyEnabled = false }
        debug { isDebuggable = true }
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    }
    androidResources {
        noCompress += listOf("kvmcheck-arm64", "tgz", "tar.gz", "gz")
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.github.topjohnwu.libsu:core:5.2.2")
}
