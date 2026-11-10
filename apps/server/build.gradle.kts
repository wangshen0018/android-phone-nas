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
        versionCode = 4
        versionName = "0.3"
    }

    // 内置 aria2c / curl 是静态 ELF，借 lib*.so 之名让系统解压到可执行的
    // nativeLibraryDir。两处必须配套：
    //   1) extractNativeLibs=true，保证 .so 落成真实文件而不是留在 APK 里；
    //   2) keepDebugSymbols 让 strip 任务「原样放行」这两个文件。
    // 千万别把 stripDebugDebugSymbols 整个 enabled=false：它是 AGP 把 .so
    // 交给 packageDebug 的必经环节，禁掉之后 package 的输入变空，
    // APK 里会一个 lib/ 都没有，而且构建照样成功、不报错。
    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libaria2c.so"
            keepDebugSymbols += "**/libcurl.so"
        }
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
