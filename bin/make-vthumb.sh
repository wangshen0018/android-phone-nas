#!/system/bin/sh
# make-vthumb.sh — 兼容层，实际逻辑已合并到 make-thumb.sh
#
# 2026-11-07：缩略图不再只做视频，图片也要做（页面网格原来直接拉原图，
# 平均 4.7 MB/张，一个 34 张的事件 158 MB）。所以 make-vthumb.sh 合并进 make-thumb.sh。
# 这个文件保留，是为了让还没重启的 daemon 进程（内存里仍是旧代码）继续能调通；
# 重启后 daemon 直接调 make-thumb.sh，这个文件就可以删了。
exec sh /data/adb/nasbak/bin/make-thumb.sh "$@"
