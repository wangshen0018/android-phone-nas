plugins {
    id("com.android.application")
}

// 服务端和客户端共用一份固定签名，方便覆盖安装。
val fixedKs = rootProject.file("keystore/nasbak.p12")

android {
    namespace = "com.pantry.server"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.pantry.server"
        minSdk = 24
        targetSdk = 34
        versionCode = 3
        versionName = "0.2.1"
    }

    signingConfigs {
        if (fixedKs.exists()) {
            create("fixed") {
                storeFile = fixedKs
                storePassword = "nasbak123"
                keyAlias = "nasbak"
                keyPassword = "nasbak123"
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        debug {
            if (fixedKs.exists()) signingConfig = signingConfigs.getByName("fixed")
        }
        release {
            isMinifyEnabled = false
            if (fixedKs.exists()) signingConfig = signingConfigs.getByName("fixed")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// 同样刻意不引入 AndroidX：只用系统 Activity / Service / Notification，
// 构建快，也不怕依赖版本冲突。
