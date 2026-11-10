# runtime.zip 由 pack-assets.py 生成，不入库

CI 每次构建前跑 `python3 apps/server/pack-assets.py`，把 `bin/`、`www/`、`etc/`、`httpd.conf`
打成这个 zip 塞进 APK。App 首次启动解压到私有目录 `files/runtime`，
以后按 `versionCode + zip 字节数` 判断要不要重解压。

包里有用的东西：脚本、页面、App 版路径配置。不放任何二进制——
HTTP 服务在 Java 里实现，命令走系统 toybox，缩略图由 App 自己生成。
