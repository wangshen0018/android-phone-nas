plugins {
    id("com.android.application")
}

// 固定签名，与 :app 共用同一个密钥库（见根目录 keystore/）
val fixedKs = rootProject.file("keystore/nasbak.p12")

android {
    namespace = "com.nasbak.hub"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.nasbak.hub"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
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

dependencies {
    // 只为一个纯 Java 的二维码编码器引依赖：引导页要让对方「扫一下就能打开」，
    // 手写 QR 编码不划算。zxing core 不依赖 Android，dex 增量约 500 KB。
    implementation("com.google.zxing:core:3.5.3")
}
