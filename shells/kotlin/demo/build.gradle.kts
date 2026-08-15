plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "kit.camera.demo"
    compileSdk = 36

    defaultConfig {
        applicationId = "kit.camera.demo"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":camerakit"))
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.appcompat:appcompat:1.7.1")
}

// The face model bundle ships as an app asset, synced from the repo's
// fetched model set so the apk always carries the pinned bytes.
val syncFaceModel by tasks.registering(Copy::class) {
    from(rootProject.projectDir.resolve("../../.models/face_landmarker.task"))
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.named("preBuild") { dependsOn(syncFaceModel) }

// The beauty engine's shader and lookup assets, synced from the pinned
// vendor tree. Assets ship read-only inside the apk; the app extracts
// them to a real path at first run since the effects engine opens them
// with plain file i/o, not the asset manager.
val syncBeautyRes by tasks.registering(Copy::class) {
    from(rootProject.projectDir.resolve("../../.vendor/gpupixel/src/res"))
    into(layout.projectDirectory.dir("src/main/assets/res"))
}
tasks.named("preBuild") { dependsOn(syncBeautyRes) }
