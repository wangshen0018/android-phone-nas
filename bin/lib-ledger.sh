#!/system/bin/sh
# 注意：本文件是被 source 的库，不自己定位 lib-path.sh。
# $0 在 source 场景里指向调用者而不是这里，而且 POSIX 下 "." 找不到
# 文件会让整个脚本直接退出，所以路径库由调用者负责 source。
# lib-ledger.sh — 统一台账库（静默版，可安全被 CGI source）
# 台账文件: $NASBAK_ROOT/state/ledger.jsonl
#
# 动作类型:
#   recv     K80 -> K40 inbox 来源目录
#   mvdate   inbox 来源目录 -> inbox/<拍摄日期>
#   arc      归档 -> archive/<YYYY-MM>/<事件夹>
#   dup      重复文件 -> _dup_backup
#
# 字段: ts / t / id / name / size / act / from / to / note

LEDGER=$NASBAK_ROOT/state/ledger.jsonl
mkdir -p $NASBAK_ROOT/state 2>/dev/null
touch "$LEDGER" 2>/dev/null

_ljesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

# 写一条台账。参数: id name size act from to [note]
ledger_add() {
  _id="$1"; _name="$2"; _sz="$3"; _act="$4"; _from="$5"; _to="$6"; _note="$7"
  _ts=$(date +%s)
  _t=$(date '+%Y-%m-%dT%H:%M:%S%z')
  _n=$(_ljesc "$_name"); _f=$(_ljesc "$_from"); _o=$(_ljesc "$_to"); _nt=$(_ljesc "$_note")
  [ -z "$_sz" ] && _sz=0
  if [ -n "$_nt" ]; then
    printf '{"ts":%s,"t":"%s","id":"%s","name":"%s","size":%s,"act":"%s","from":"%s","to":"%s","note":"%s"}\n' \
      "$_ts" "$_t" "$_id" "$_n" "$_sz" "$_act" "$_f" "$_o" "$_nt" >> "$LEDGER" 2>/dev/null
  else
    printf '{"ts":%s,"t":"%s","id":"%s","name":"%s","size":%s,"act":"%s","from":"%s","to":"%s"}\n' \
      "$_ts" "$_t" "$_id" "$_n" "$_sz" "$_act" "$_f" "$_o" >> "$LEDGER" 2>/dev/null
  fi
}

# 按文件名查最近的 id
ledger_find_id() {
  _nm=$(_ljesc "$1")
  grep -F "\"name\":\"$_nm\"" "$LEDGER" 2>/dev/null | tail -1 | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

# 台账轮转：>5MB 时把 30 天前记录移到 ledger-arch/
ledger_rotate() {
  [ -f "$LEDGER" ] || return 0
  _sz=$("$BB" stat -c %s "$LEDGER" 2>/dev/null)
  [ -z "$_sz" ] && return 0
  [ "$_sz" -lt 5242880 ] && return 0
  _cut=$(date -d '30 days ago' +%s 2>/dev/null) || return 0
  _dir=$NASBAK_ROOT/state/ledger-arch
  mkdir -p "$_dir" 2>/dev/null
  : > /tmp/_led_old; : > /tmp/_led_new
  while IFS= read -r ln; do
    _ts=$(printf '%s' "$ln" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')
    [ -z "$_ts" ] && { printf '%s\n' "$ln" >> /tmp/_led_new; continue; }
    if [ "$_ts" -lt "$_cut" ]; then printf '%s\n' "$ln" >> /tmp/_led_old
    else printf '%s\n' "$ln" >> /tmp/_led_new; fi
  done < "$LEDGER"
  if [ -s /tmp/_led_old ]; then
    _f="$_dir/ledger-$(date +%Y%m).jsonl"
    cat /tmp/_led_old >> "$_f" 2>/dev/null
    cat /tmp/_led_new > "$LEDGER" 2>/dev/null
    "$BB" gzip -f "$_f" 2>/dev/null
  fi
  rm -f /tmp/_led_old /tmp/_led_new 2>/dev/null
}
