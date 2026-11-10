#!/system/bin/sh
. "$(dirname "$0")/../../bin/lib-path.sh"
# undo.cgi — 撤销判定页的上一次操作
#
# 设计依据（2026-11-06）：
#   decisions.jsonl 是纯追加日志，同一 id 允许有多条，读取时取最后一条。
#   所以「撤销」不需要删记录，只要追加一条把动作改回去的记录即可 —— 天然可审计、可再撤销。
#
# 动作：
#   ?a=last                返回最近 N 条操作供前端展示（默认 12 条）
#   ?a=undo&id=<16hex>     撤销指定 id 的最后一次判定（把它从当前判定里"摘掉"）
#
# 「摘掉」怎么实现：
#   追加一条 {"action":"none"} 的记录。前端 state.cgi 拿到的 actions 里
#   值为 none 等于"未判定"，卡片按钮恢复可用。apply.cgi 执行时会跳过非判定动作。
#
# 为什么不直接删 decisions.jsonl 的行：
#   · 那是审计轨迹，删了就看不出"曾经判过又撤回"
#   · 并发写时删行要重写整个文件，容易写坏；追加永远是原子的

DATA=$NASBAK_ROOT/state
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

QS="${QUERY_STRING:-}"

getp() {
  _k="$1"
  printf '%s' "$QS" | tr '&' '\n' | sed -n "s/^$_k=//p" | head -1
}

A=$(getp a)
[ -z "$A" ] && A="last"

case "$A" in

  last)
    # 最近 N 条「真正生效过」的判定，倒序。跳过 none（那是撤销记录本身）
    N=$(getp n); case "$N" in ''|*[!0-9]*) N=12 ;; esac
    [ "$N" -gt 50 ] && N=50
    KEY=$(getp key)          # 可选：只查某个 id
    # 性能（2026-11-06）：原来每个 id 都 grep 一次 analysis.jsonl（370KB），
    # 106 个 id × 0.25s ≈ 27 秒 —— 单线程 httpd 上这直接把判定页拖死。
    # 改成一次 awk 同时读三个文件：先建 analysis 与 events 散列表，再处理 decisions。
    # 实测从 27s 降到 0.2s。
    $BB awk -v N="$N" -v KEY="$KEY" '
      # 第一遍：analysis.jsonl → id => name / desc
      FNR==NR {
        if (match($0, /"id":"[0-9a-f]+"/)) {
          i = substr($0, RSTART+6, RLENGTH-7);
          if (match($0, /"name":"[^"]*"/))  nm[i] = substr($0, RSTART+8, RLENGTH-9);
          if (match($0, /"desc":"[^"]*"/))  ds[i] = substr($0, RSTART+8, RLENGTH-9);
        }
        next
      }
      # 第二遍：events.jsonl → ev-id => 中文事件名（分类 › 主题）
      FILENAME ~ /events\.jsonl$/ {
        if (match($0, /"event_id":"[^"]*"/)) {
          ei = substr($0, RSTART+12, RLENGTH-13);
          sl = ""; tp = "";
          if (match($0, /"slug":"[^"]*"/))  sl = substr($0, RSTART+8, RLENGTH-9);
          if (match($0, /"topic":"[^"]*"/)) tp = substr($0, RSTART+9, RLENGTH-10);
          if (sl != "" && tp != "") evn[ei] = sl " › " tp;
          else if (tp != "")        evn[ei] = tp;
          else if (sl != "")        evn[ei] = sl;
        }
        next
      }
      # 第四遍：receipts.jsonl → 记录哪些 id 已经真正执行过（文件已归档/已删除）
      # 为什么要这个（2026-11-06）：撤销只是往 decisions.jsonl 追加 action=none，
      # 把判定状态还原；但 apply 已经做过的文件操作是不可逆的 ——
      #   arc 的文件已在 archive/ 里、del 的源文件已被 rm。
      # 前端必须知道这个区别，才能给用户正确的警告，而不是让人以为能"回滚"。
      FILENAME ~ /receipts\.jsonl$/ {
        if (match($0, /"id":"[0-9a-f]+"/)) {
          ri = substr($0, RSTART+6, RLENGTH-7);
          if (match($0, /"action":"[a-z]*"/))     racc[ri] = substr($0, RSTART+10, RLENGTH-11)
          if (match($0, /"result":"[a-zA-Z]*"/)) rres[ri] = substr($0, RSTART+10, RLENGTH-11)
          if (match($0, /"path":"[^"]*"/))       rpath[ri] = substr($0, RSTART+8, RLENGTH-9)
        }
        next
      }
      # 第五遍：decisions.jsonl，同一 id 以最后一条为准
      {
        if (match($0, /"id":"[0-9a-f]+"/)) {
          i = substr($0, RSTART+6, RLENGTH-7);
          if (i == "") next;
          line[i] = $0;
          if (!(i in seen)) { seen[i] = 1; order[++m] = i }
        }
      }
      END {
        # 聚合同一批操作（2026-11-06 用户要求）：
        #   连续点「本日全删」或一次批量存档，会产生几十条 decisions 记录，
        #   逐条列出来没法看。这里把「动作相同 + 事件相同 + 时间相差 ≤60 秒」
        #   的相邻记录合成一条，显示成「把 A、B 等 16 个文件归入 X」。
        #   60 秒是实测值：手动连续点批量按钮的间隔都在几秒内，
        #   而不同批次之间至少隔着几分钟。
        # 注意 order 是「首次出现」顺序，需要按时间重排后再聚合。
        ng = 0
        for (k = m; k >= 1; k--) {
          i = order[k]; L = line[i]
          a = ""; if (match(L, /"action":"[a-z]*"/)) a = substr(L, RSTART+10, RLENGTH-11)
          if (a == "none" || a == "") continue;          # 撤销掉的不进列表
          t = 0;  if (match(L, /"ts":[0-9]*/))     t = substr(L, RSTART+5, RLENGTH-5)
          e = ""; if (match(L, /"event":"[^"]*"/)) e = substr(L, RSTART+9, RLENGTH-10)
          # 归到哪个组：动作+事件相同，且与上一组最后一个成员的时间差 ≤60 秒
          # 注意方向（2026-11-07 修正）：本循环是「从新到旧」遍历，所以 t（当前这条）
          # 比 gt_last[ng]（组内已有成员）更旧，间隔应为 gt_last[ng] - t。
          # 原写成 (t - gt_last[ng]) 恒为负数、恒 ≤60，等于不设时间限制地把
          # 所有「动作+事件相同」的相邻记录合并，历史会被压缩成很少几条。
          if (ng > 0 && ga[ng] == a && ge[ng] == e && (gt_last[ng] - t) <= 60) {
            gn[ng]++
            gi[ng] = gi[ng] "," i
            if (i in rres) gen[ng]++          # 这一条已经执行过（文件已归档/已删除）
            # 组内可能有查不到文件名的老件，取前两个「有名字」的做代表
            if (nm[i] != "") {
              if (gfirst[ng] == "" || nm[gfirst[ng]] == "") gfirst[ng] = i
              else if (gname2[ng] == "" && nm[i] != nm[gfirst[ng]]) gname2[ng] = nm[i]
            }
            gt_last[ng] = t
            if (t > gt_top[ng]) gt_top[ng] = t
          } else {
            ng++
            ga[ng] = a; ge[ng] = e; gn[ng] = 1; gi[ng] = i
            gen[ng] = (i in rres) ? 1 : 0
            gt_last[ng] = t; gt_top[ng] = t
            gfirst[ng] = (nm[i] != "") ? i : ""
            gname2[ng] = ""
            gcat[ng] = ""; if (match(L, /"cat":"[^"]*"/)) gcat[ng] = substr(L, RSTART+7, RLENGTH-8)
          }
        }

        # 输出：最新的一组排最前
        # 组号语义（2026-11-07 修正）：上面的循环是「从新到旧」遍历，最先遇到的
        # 记录开第 1 组 —— 所以 1 号组最新，ng 号组最旧，必须正序输出。
        # 原写成 for (k = ng; k >= 1; k--) 是反的，导致前端收起时（只取前 2 条）
        # 显示的是「最早的两条」，还把最早那条标成「最新」。
        out = ""; cnt = 0
        for (k = 1; k <= ng; k++) {
          if (KEY != "" && index("," gi[k] ",", "," KEY ",") == 0) continue
          # 代表 id：优先取查得到文件名的那个；都没有就用本组第一个（显示 id 前缀）
          i = (gfirst[k] != "") ? gfirst[k] : substr(gi[k], 1, 16)
          e = ge[k]; en = (e in evn) ? evn[e] : e; c = gcat[k]
          first = nm[i]; second = gname2[k]
          if (first == "") first = i           # 查不到名字就显示 id，不留空
          gsub(/\\/, "\\\\", e);  gsub(/"/, "\\\"", e)
          gsub(/\\/, "\\\\", en); gsub(/"/, "\\\"", en)
          gsub(/\\/, "\\\\", first); gsub(/"/, "\\\"", first)
          gsub(/\\/, "\\\\", second); gsub(/"/, "\\\"", second)
          gsub(/\\/, "\\\\", ds[i]); gsub(/"/, "\\\"", ds[i])
          if (cnt > 0) out = out ","
          out = out sprintf("{\"id\":\"%s\",\"act\":\"%s\",\"event\":\"%s\",\"event_name\":\"%s\",\"cat\":\"%s\",\"ts\":%s,\"n\":%d,\"exec_n\":%d,\"ids\":\"%s\",\"name\":\"%s\",\"name2\":\"%s\",\"desc\":\"%s\"}", \
                 i, ga[k], e, en, c, gt_top[k]+0, gn[k], gen[k]+0, gi[k], first, second, ds[i])
          if (++cnt >= N) break
        }
        printf "{\"ok\":true,\"items\":[%s]}\n", out
      }' "$DATA/analysis.jsonl" "$DATA/events.jsonl" "$DATA/receipts.jsonl" "$DATA/decisions.jsonl" 2>/dev/null
    ;;

  undo)
    # 支持两种调用：
    #   ?a=undo&id=<16hex>           撤单个
    #   ?a=undo&ids=<id,id,...>      撤一整批（前端把聚合组的 ids 传过来）
    #
    # 撤销 = 两件事（2026-11-06 用户要求真正还原文件）：
    #   ① 把已归档的文件从 archive/ 搬回 inbox 原位置
    #   ② 追加 action=none，让 state.cgi 认为未判定
    # 顺序很重要：先搬文件，搬成功了才改判定状态 ——
    # 万一搬失败（目标被占、文件已不在），判定状态不动，用户还能再试。
    # del 的源文件已被 rm，救不回来，只能改状态并在返回值里说明。
    IDS=$(getp ids)
    ID=$(getp id)
    [ -z "$IDS" ] && IDS="$ID"
    [ -z "$IDS" ] && { echo '{"ok":false,"err":"缺少 id"}'; exit 0; }

    STG=$NASBAK_ROOT/inbox
    ARC=$NASBAK_ROOT/archive
    MEDIA_DIR=$NASBAK_ROOT/state/media

    NOW=$(date +%s)
    OKN=0; SKIPN=0; FIRSTACT=""
    RESTORED=0; RESTFAIL=0; DELETED=0
    _old=$IFS; IFS=','
    for ID in $IDS; do
      IFS=$_old
      case "$ID" in
        ''|*[!0-9a-f]*) SKIPN=$((SKIPN+1)); continue ;;
      esac
      [ ${#ID} -eq 16 ] || { SKIPN=$((SKIPN+1)); continue; }

      # 确认这个 id 当前确实有生效的判定（否则没什么可撤）
      CUR=$($BB awk '{l[NR]=$0} END{for(i=NR;i>=1;i--) print l[i]}' "$DATA/decisions.jsonl" 2>/dev/null \
            | $BB grep -F "\"id\":\"$ID\"" 2>/dev/null | head -1)
      [ -z "$CUR" ] && { SKIPN=$((SKIPN+1)); continue; }
      CURACT=$(printf '%s' "$CUR" | sed -n 's/.*"action":"\([a-z]*\)".*/\1/p')
      [ "$CURACT" = "none" ] && { SKIPN=$((SKIPN+1)); continue; }
      [ -z "$FIRSTACT" ] && FIRSTACT="$CURACT"

      # ---- ① 先把已归档的文件搬回来 ----
      if [ "$CURACT" = "arc" ]; then
        # receipts.jsonl 里这一 id 最后一条成功的归档记录，path 形如
        #   2026-10/2026-10-17_home_family-kid出生第一年/VID_xxx.mp4
        RPATH=$($BB awk -v want="$ID" '
          {
            if (match($0, /"id":"[0-9a-f]+"/)) {
              i = substr($0, RSTART+6, RLENGTH-7)
              if (i != want) next
              if (!match($0, /"path":"[^"]*"/)) next
              p = substr($0, RSTART+8, RLENGTH-9)
              if (p != "") last = p
            }
          } END { print last }' "$DATA/receipts.jsonl" 2>/dev/null)

        if [ -n "$RPATH" ] && [ -f "$ARC/$RPATH" ]; then
          BN=$(basename "$RPATH")
          # 原位置（inbox 下的相对路径）按可靠性依次尝试：
          #   ① analysis.jsonl 的 rel —— 最准，形如 2026-11-02/IMG_xxx.jpg
          #   ② 文件名里的日期 —— 命名规则带日期（IMG_20261017_xxx / 2026-10-17_xxx）
          #   ③ 兜底放 inbox 根
          # 不能只用 basename 丢到根目录：那样会破坏 inbox 的日期结构，
          # 判定页按日期分组，散落根目录的文件会被当成"无日期"（2026-11-06 发现）。
          OREL=$($BB grep -F "\"id\":\"$ID\"" "$DATA/analysis.jsonl" 2>/dev/null \
                 | head -1 | sed -n 's/.*"rel":"\([^"]*\)".*/\1/p')
          if [ -z "$OREL" ]; then
            # 文件名里的 YYYYMMDD 或 YYYY-MM-DD
            FD=""
            case "$BN" in
              *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*) FD=$(printf '%s' "$BN" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1) ;;
            esac
            [ -z "$FD" ] && case "$BN" in
              *20[0-9][0-9][01][0-9][0-3][0-9]_*) FD=$(printf '%s' "$BN" | sed -n 's/.*\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1) ;;
            esac
            if [ -n "$FD" ]; then
              OREL="$FD/$BN"
            else
              OREL="$BN"
            fi
          fi
          ODIR=$(dirname "$OREL")
          mkdir -p "$STG/$ODIR" 2>/dev/null
          DST="$STG/$OREL"
          # 目标位置若已被占用（重复件），加序号，不覆盖
          if [ -e "$DST" ]; then
            BASE="${OREL%.*}"; EXT="${OREL##*.}"
            N=1
            while [ -e "$STG/${BASE}_undo$N.$EXT" ] && [ $N -lt 50 ]; do N=$((N+1)); done
            DST="$STG/${BASE}_undo$N.$EXT"
          fi
          if mv -f "$ARC/$RPATH" "$DST" 2>/dev/null; then
            RESTORED=$((RESTORED+1))
            # 清掉搬空的归档目录。注意目录里通常还有 _manifest.jsonl（apply 归档时写的
            # 清单），光 rmdir 删不掉，得先把清单一起清掉（2026-11-06 实测：
            # 撤销后 archive/2026-11/... 剩下一个只有 _manifest.jsonl 的空壳）。
            EVDIR=$(dirname "$ARC/$RPATH")
            if [ -d "$EVDIR" ]; then
              # 只剩清单（没有其他媒体文件）才连清单一起删，避免误删别的事件
              REST=$(find "$EVDIR" -maxdepth 1 -type f ! -name '_manifest.jsonl' 2>/dev/null | wc -l | tr -d ' ')
              if [ "${REST:-0}" -eq 0 ]; then
                rm -f "$EVDIR/_manifest.jsonl" 2>/dev/null
                rmdir "$EVDIR" 2>/dev/null
                # 月份目录如果也空了，一并清
                YMDIR=$(dirname "$EVDIR")
                rmdir "$YMDIR" 2>/dev/null
              fi
            fi
            RL=$(printf '%s' "$DST" | sed "s#^$STG/##")
            if [ -f $NASBAK_HOME/bin/lib-ledger.sh ]; then
              . $NASBAK_HOME/bin/lib-ledger.sh 2>/dev/null
              ledger_add "$ID" "$BN" "0" "unarc" "archive/$RPATH" "inbox/$RL" "撤销归档，文件搬回原位置" 2>/dev/null
            fi
          else
            RESTFAIL=$((RESTFAIL+1))
          fi
        fi
      elif [ "$CURACT" = "del" ]; then
        # 「删除」现在只是移进回收站（30 天后才清），所以撤销能真正找回来。
        # 回收站里的文件名是 <id>__<原文件名>，按 id 前缀匹配即可定位。
        TRASH="$DATA/_media_gc_trash"
        # 回收站里两种命名都要认：
        #   新：<id>__<原文件名>   —— apply.cgi 的删除（带原始文件名，能还原）
        #   老：<id>.<ext>         —— media-gc 收的孤儿副本（只有 id，原文件名靠 analysis 反查）
        TFILE=$(find "$TRASH" -maxdepth 2 -type f -name "${ID}__*" 2>/dev/null | head -1)
        [ -z "$TFILE" ] && TFILE=$(find "$TRASH" -maxdepth 2 -type f -name "${ID}.*" 2>/dev/null | head -1)
        # 排除缩略图副本（<id>.thumb.ext）
        case "$TFILE" in *.thumb.*) TFILE="" ;; esac
        if [ -n "$TFILE" ] && [ -f "$TFILE" ]; then
          # 去掉 id__ 前缀，还原原始文件名；老格式没有前缀，就用 analysis 的 name
          TBN=$(basename "$TFILE")
          case "$TBN" in
            "${ID}__"*) ORIG=${TBN#${ID}__} ;;
            *) ORIG=$($BB grep -F "\"id\":\"$ID\"" "$DATA/analysis.jsonl" 2>/dev/null \
                      | head -1 | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
               [ -z "$ORIG" ] && ORIG="$TBN" ;;
          esac
          # 原位置：优先 analysis 的 rel
          OREL=$($BB grep -F "\"id\":\"$ID\"" "$DATA/analysis.jsonl" 2>/dev/null \
                 | head -1 | sed -n 's/.*"rel":"\([^"]*\)".*/\1/p')
          if [ -z "$OREL" ]; then
            FD=""
            case "$ORIG" in
              *20[0-9][0-9][01][0-9][0-3][0-9]_*) FD=$(printf '%s' "$ORIG" | sed -n 's/.*\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1) ;;
            esac
            [ -n "$FD" ] && OREL="$FD/$ORIG" || OREL="$ORIG"
          fi
          ODIR=$(dirname "$OREL")
          mkdir -p "$STG/$ODIR" 2>/dev/null
          DST="$STG/$OREL"
          if [ -e "$DST" ]; then
            BASE="${OREL%.*}"; EXT="${OREL##*.}"; N=1
            while [ -e "$STG/${BASE}_undo$N.$EXT" ] && [ $N -lt 50 ]; do N=$((N+1)); done
            DST="$STG/${BASE}_undo$N.$EXT"
          fi
          if mv -f "$TFILE" "$DST" 2>/dev/null; then
            RESTORED=$((RESTORED+1))
            # 顺手把它的 media 缩略图副本也放回原位（页面上才能正常显示）
            EXT="${ORIG##*.}"
            TTHUMB=$(find "$TRASH" -maxdepth 2 -type f -name "${ID}.thumb.*" 2>/dev/null | head -1)
            if [ -n "$TTHUMB" ] && [ -f "$TTHUMB" ]; then
              mv -f "$TTHUMB" "$MEDIA_DIR/$ID.$EXT" 2>/dev/null
            fi
            # 回收站日期目录空了就删掉
            TDIR=$(dirname "$TFILE")
            rmdir "$TDIR" 2>/dev/null
            RL=$(printf '%s' "$DST" | sed "s#^$STG/##")
            if [ -f $NASBAK_HOME/bin/lib-ledger.sh ]; then
              . $NASBAK_HOME/bin/lib-ledger.sh 2>/dev/null
              ledger_add "$ID" "$ORIG" "0" "undel" "trash" "inbox/$RL" "撤销删除，从回收站找回" 2>/dev/null
            fi
          else
            RESTFAIL=$((RESTFAIL+1))
          fi
        else
          # 回收站里没有（可能已过 30 天被清理，或当初是老版本 rm 掉的）
          DELETED=$((DELETED+1))
        fi
      fi

      printf '{"id":"%s","action":"none","event":"","topic":"","cat":"","by":"undo","ts":%s}\n' \
        "$ID" "$NOW" >> "$DATA/decisions.jsonl"
      OKN=$((OKN+1))

      # 回执也追加一条，台账可追溯"谁撤的"
      if [ -f $NASBAK_HOME/bin/lib-ledger.sh ]; then
        . $NASBAK_HOME/bin/lib-ledger.sh 2>/dev/null
        ledger_add "$ID" "" "0" "undo" "decisions.jsonl" "decisions.jsonl" "撤销判定(原动作:$CURACT)" 2>/dev/null
      fi
      IFS=','
    done
    IFS=$_old

    if [ "$OKN" -eq 0 ]; then
      echo "{\"ok\":false,\"err\":\"没有可撤销的记录\",\"skipped\":$SKIPN}"
      exit 0
    fi
    echo "{\"ok\":true,\"undone\":$OKN,\"skipped\":$SKIPN,\"last_act\":\"$FIRSTACT\",\"restored\":$RESTORED,\"restore_failed\":$RESTFAIL,\"deleted_gone\":$DELETED}"
    ;;

  *)
    echo '{"ok":false,"err":"未知动作"}'
    ;;
esac

exit 0
