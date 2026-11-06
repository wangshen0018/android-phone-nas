#!/system/bin/sh
# lib-sidecar.sh — 判读结果随归档文件落地
#
# 设计参照 PhotoPrism：originals 只读，元数据放在旁挂文件里，应用删了照片和名字都还在。
# 本项目原先的判读结果只存在 state/analysis/<id>.json，而 id = sha256(rel+":"+size)，
# 文件一移动 id 就变，导致归档后的成品脱离脚本就无法解读。
#
# 本库在归档成功后，把该文件的完整判读行（来自 analysis.jsonl）追加到事件夹内的
# _manifest.jsonl。好处：
#   · 元数据跟着文件走，rclone sync 自动带上云盘
#   · 不依赖 id、不依赖 state/，K40 换机或 state 丢失也能还原
#   · 单一隐藏文件，不在照片目录里制造大量碎文件
#
# 由 apply.cgi 在 RES="archived" 分支调用，要求调用方已就绪以下变量：
#   ARC    归档根 /data/media/0/nasbak/archive
#   YM     YYYY-MM
#   FOLDER 事件夹名
#   AL     analysis.jsonl 中该 id 的完整 JSON 行（可能为空）

sidecar_append() {
  [ -n "$ARC" ] && [ -n "$YM" ] && [ -n "$FOLDER" ] || return 0
  [ -n "$AL" ] || return 0

  _sd="$ARC/$YM/$FOLDER"
  [ -d "$_sd" ] || return 0

  _mf="$_sd/_manifest.jsonl"

  # 幂等：同一行已在则跳过（apply.cgi 重跑不会重复追加）
  if [ -f "$_mf" ] && grep -qxF "$AL" "$_mf" 2>/dev/null; then
    return 0
  fi

  printf '%s\n' "$AL" >> "$_mf" 2>/dev/null
  return 0
}
