plugins { id("com.android.application") }

android {
    namespace = "com.qemut8030.launcher"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.qemut8030.launcher"
        minSdk = 26
        targetSdk = 35
        versionCode = 15
        versionName = "1.2.4"
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
        noCompress += listOf("kvmcheck-arm64")
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.github.topjohnwu.libsu:core:5.2.2")
}
