pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Pantry"

// 两个独立 APK，不能合并：
//   :client = 家人手机上的 WebView 壳，只负责看照片
//   :server = 当库房那台手机上的常驻服务，管文件和服务
// :hub 是早期用 Java 重写 HTTP 的草案，不参与构建，留着 references。
include(":client")
include(":server")
