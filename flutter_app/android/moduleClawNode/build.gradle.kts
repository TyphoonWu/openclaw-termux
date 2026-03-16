val androidStoreFile = providers.gradleProperty("OPENCLAW_ANDROID_STORE_FILE").orNull?.takeIf { it.isNotBlank() }
val androidStorePassword = providers.gradleProperty("OPENCLAW_ANDROID_STORE_PASSWORD").orNull?.takeIf { it.isNotBlank() }
val androidKeyAlias = providers.gradleProperty("OPENCLAW_ANDROID_KEY_ALIAS").orNull?.takeIf { it.isNotBlank() }
val androidKeyPassword = providers.gradleProperty("OPENCLAW_ANDROID_KEY_PASSWORD").orNull?.takeIf { it.isNotBlank() }
val resolvedAndroidStoreFile =
    androidStoreFile?.let { storeFilePath ->
        if (storeFilePath.startsWith("~/")) {
            "${System.getProperty("user.home")}/${storeFilePath.removePrefix("~/")}"
        } else {
            storeFilePath
        }
    }

val hasAndroidReleaseSigning =
    listOf(resolvedAndroidStoreFile, androidStorePassword, androidKeyAlias, androidKeyPassword).all { it != null }

val wantsAndroidReleaseBuild =
    gradle.startParameter.taskNames.any { taskName ->
        taskName.contains("Release", ignoreCase = true) ||
            Regex("""(^|:)(bundle|assemble)$""").containsMatchIn(taskName)
    }

if (wantsAndroidReleaseBuild && !hasAndroidReleaseSigning) {
    println("WARNING: Missing Android release signing properties. Library will be built without custom signing.")
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jlleitschuh.gradle.ktlint")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "ai.openclaw.app"
    compileSdk = 36

    sourceSets {
        getByName("main") {
            assets.directories.add("../../shared/OpenClawKit/Sources/OpenClawKit/Resources")
        }
    }

    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        
        // 手动注入 VERSION_CODE 和 VERSION_NAME 到 BuildConfig，解决代码引用报错
        buildConfigField("int", "VERSION_CODE", "202603130")
        buildConfigField("String", "VERSION_NAME", "\"2026.3.13\"")

        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            excludes +=
                setOf(
                    "/META-INF/{AL2.0,LGPL2.1}",
                    "/META-INF/*.version",
                    "/META-INF/LICENSE*.txt",
                    "DebugProbesKt.bin",
                    "kotlin-tooling-metadata.json",
                )
        }
    }

    lint {
        disable +=
            setOf(
                "AndroidGradlePluginVersion",
                "GradleDependency",
                "IconLauncherShape",
                "NewerVersionAvailable",
            )
        warningsAsErrors = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        // 核心修复：禁用 K2 前端以支持 SDK 36
        freeCompilerArgs.add("-Xuse-k2=false")
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

ktlint {
    android.set(true)
    ignoreFailures.set(false)
    filter {
        exclude("**/build/**")
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.webkit:webkit:1.15.0")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("androidx.security:security-crypto:1.1.0")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    
    // 补齐 Commonmark 及其所有扩展，解决 ChatMarkdown.kt 编译报错
    val commonmarkVersion = "0.22.0"
    implementation("org.commonmark:commonmark:$commonmarkVersion")
    implementation("org.commonmark:commonmark-ext-autolink:$commonmarkVersion")
    implementation("org.commonmark:commonmark-ext-gfm-strikethrough:$commonmarkVersion")
    implementation("org.commonmark:commonmark-ext-gfm-tables:$commonmarkVersion")
    implementation("org.commonmark:commonmark-ext-task-list-items:$commonmarkVersion")

    implementation("androidx.camera:camera-core:1.4.0")
    implementation("androidx.camera:camera-camera2:1.4.0")
    implementation("androidx.camera:camera-lifecycle:1.4.0")
    implementation("androidx.camera:camera-video:1.4.0")
    implementation("androidx.camera:camera-view:1.4.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("dnsjava:dnsjava:3.6.1")

    testImplementation("junit:junit:4.13.2")
}
