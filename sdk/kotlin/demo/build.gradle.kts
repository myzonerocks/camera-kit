plugins {
    id("com.android.application")
}

android {
    namespace = "com.gosslens.demo"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.gosslens.demo"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    implementation(project(":"))
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.appcompat:appcompat:1.7.1")
}

// The face model bundle ships as an app asset, synced from the repo's
// fetched model set so the apk always carries the pinned bytes.
val syncFaceModel = tasks.register<Copy>("syncFaceModel") {
    from(rootProject.projectDir.resolve("../../.models/face_landmarker.task"))
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.named("preBuild") { dependsOn(syncFaceModel) }

// The beauty engine's shader and lookup assets, synced from the pinned
// vendor tree. Assets ship read-only inside the apk; the app extracts
// them to a real path at first run since the effects engine opens them
// with plain file i/o, not the asset manager.
val syncBeautyRes = tasks.register<Copy>("syncBeautyRes") {
    from(rootProject.projectDir.resolve("../../.vendor/gpupixel/src/res"))
    into(layout.projectDirectory.dir("src/main/assets/res"))
}
tasks.named("preBuild") { dependsOn(syncBeautyRes) }

// The beauty-baseline reference lens, synced straight from the tracked
// bundle so the demo always ships exactly what the validator checked.
val syncReferenceLens = tasks.register<Copy>("syncReferenceLens") {
    from(rootProject.projectDir.resolve("../../lenses/reference/beauty-baseline"))
    into(layout.projectDirectory.dir("src/main/assets/lenses/beauty-baseline"))
}
tasks.named("preBuild") { dependsOn(syncReferenceLens) }

// Row 8's conformance corpus frame, synced from the fetched model set -
// ConformanceRunner feeds this through the real ABI in place of live
// capture, behind the GossConformance intent extra a normal launch
// never sets.
val syncConformanceCorpus = tasks.register<Copy>("syncConformanceCorpus") {
    from(rootProject.projectDir.resolve("../../.models/corpus/face_frontal_b.jpg"))
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.named("preBuild") { dependsOn(syncConformanceCorpus) }
