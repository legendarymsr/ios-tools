// SPDX-License-Identifier: GPL-3.0-or-later
plugins { id("com.android.application") }

android {
    namespace = "com.qemut8030.launcher"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.qemut8030.launcher"
        minSdk = 26
        targetSdk = 35
        versionCode = 135
        versionName = "2.10.2"
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

// The app runs the hackios.sh in its assets (copied into the chroot on every step), not the module's
// payload: the assets are refreshed from the module's files before every build, so the two never differ.
val syncPayload by tasks.registering(Copy::class) {
    val mod = rootProject.file("..")
    from(mod) {
        include("hackios.sh", "setup-debian-chroot.sh", "xz-arm64", "LICENSE-xz",
                "ws.hbang.newterm3_iphoneos-arm64.deb", "NewTerm-NOTICE.md")
    }
    from(File(mod, "timesync")) { include("timesync-arm64") }
    from(File(mod, "rootful")) { include("rootful-arm64") }
    into(file("src/main/assets/payload"))
}
tasks.named("preBuild") { dependsOn(syncPayload) }

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.github.topjohnwu.libsu:core:5.2.2")
}
