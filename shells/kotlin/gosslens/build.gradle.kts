plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.gosslens"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
    }

    sourceSets {
        getByName("main") {
            // The .so comes from zig build android; gradle only packages it.
            jniLibs.srcDir("../../../zig-out/android")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
