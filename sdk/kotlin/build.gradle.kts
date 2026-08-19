plugins {
    id("com.android.application") version "9.3.0" apply false
    id("com.android.library") version "9.3.0"
    `maven-publish`
}

group = "com.myzonerocks"
version = "0.1.0"

android {
    namespace = "com.gosslens"
    compileSdk = 37

    defaultConfig {
        minSdk = 29
    }

    sourceSets {
        getByName("main") {
            // The .so comes from zig build android; gradle only packages it.
            jniLibs.srcDir("../../zig-out/android")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

// Publishes the library so it resolves straight from the repository over
// JitPack for release builds, the counterpart to the Swift package's own
// git-URL install. A consumer app takes it from the published coordinate;
// for local work it swaps in an included build of this project instead.
publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.myzonerocks"
            artifactId = "gosslens"
            afterEvaluate { from(components["release"]) }
        }
    }
}
