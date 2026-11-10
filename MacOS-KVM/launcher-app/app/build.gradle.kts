// SPDX-License-Identifier: GPL-3.0-or-later
plugins { id("com.android.application") }

android {
    namespace = "com.macoskvm.launcher"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.macoskvm.launcher"
        minSdk = 26
        targetSdk = 35
        versionCode = 9
        versionName = "1.1.3"
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
}

// The app runs its own copies of the module scripts (assets/payload); keep
// them identical to the ones in MacOS-KVM/.
val syncPayload by tasks.registering(Copy::class) {
    val mod = rootProject.file("..")
    from(mod) {
        include("setup-debian-chroot.sh", "install-qemu-x86.sh", "setup-osx-kvm.sh",
                "macos-versions.sh", "fetch-macos.sh", "boot-macos.sh",
                "xz-arm64")
    }
    into(file("src/main/assets/payload"))
}
tasks.named("preBuild") { dependsOn(syncPayload) }

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.github.topjohnwu.libsu:core:5.2.2")
}
