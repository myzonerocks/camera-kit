plugins {
    id("com.android.library")
}

android {
    namespace = "com.gosslens"
    compileSdk = 37

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
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}
