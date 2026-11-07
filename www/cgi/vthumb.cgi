#!/system/bin/sh
# vthumb.cgi — 兼容层，实际逻辑已合并到 thumb.cgi
#
# 2026-11-07：缩略图接口不再区分图片/视频，统一走 thumb.cgi。
# 保留这个文件是怕有旧页面缓存还在请求它；新页面一律用 cgi/thumb.cgi。
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"ok":false,"err":"use cgi/thumb.cgi"}\n'
