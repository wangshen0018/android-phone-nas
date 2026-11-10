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

rootProject.name = "NasBakShell"
// :app = 自用遥控器壳（WebView 指向 K40 的 8083）
// :hub = 给亲友的分发版：服务端内置在 App 里，无 root 可跑
include(":app")
// :hub 仍在开发中（缺 SetupActivity / HubService），先不参与构建，
// 否则 assembleDebug 会在配置阶段就失败。写完后取消下面这行注释。
// include(":hub")
