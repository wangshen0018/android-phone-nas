plugins {
    id("com.android.application")
}

// 固定签名：云端 runner 每次都是干净环境，若不指定 keystore，
// AGP 会现场随机生成 debug 密钥 → 每次构建签名都不同 → 新包无法覆盖安装。
// 密钥库由 CI 首次生成并回填仓库（仅调试用途，密码公开可接受）。
val fixedKs = rootProject.file("keystore/nasbak.p12")

android {
    namespace = "com.nasbak.shell"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.nasbak.shell"
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
        // debug 用固定签名即可直接安装；release 需要另配 keystore
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

// 刻意不引入任何 AndroidX 依赖：这个壳只需要系统自带的 Activity + WebView，
// 依赖越少构建越快、越不容易因为版本冲突失败。
