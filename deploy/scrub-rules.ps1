# 脱敏规则
#
# 把私有版复制到公开版时，按顺序替换。
# 替换后必须跑一次 scrub-verify.ps1 确认零残留。

$ScrubRules = @(
    # ---- 凭据 ----
    @{ From = 'k40srv';                To = 'CHANGE_ME'; Note = 'aria2 rpc-secret' },

    # ---- 内网 IP ----
    @{ From = '192.168.50.241';        To = '<K40_LAN_IP>';   Note = 'NAS 局域网地址' },
    @{ From = '192.168.50.1';          To = '<ROUTER_DNS>';   Note = '路由器 DNS' },
    @{ From = '100.64.180.121';        To = '<K40_TAILSCALE_IP>'; Note = 'Tailscale 地址' },

    # ---- 设备标识 ----
    @{ From = 'M2012K11AC';            To = '<DEVICE_MODEL>'; Note = 'K40 型号' },
    @{ From = '24122RKC7C';            To = '<K80_MODEL>';    Note = 'K80 型号' },

    # ---- 个人目录名 ----
    @{ From = '儿子';                  To = 'family-kid';    Note = '家人相册目录' },
    @{ From = '身份证';                To = 'id-card';       Note = '证件目录' },
    @{ From = '毕业证';                To = 'diploma';       Note = '毕业证' },
    @{ From = '结婚证';                To = 'marriage-cert'; Note = '结婚证' },

    # ---- 真实事件主题（示例数据才有的） ----
    @{ From = '省水利厅视察';          To = 'site-inspection' },
    @{ From = '汇河工程例会';          To = 'project-meeting' },
    @{ From = '汇河苏庄工单处理';      To = 'ticket-handling' },
    @{ From = '去临沂水总谈判';        To = 'negotiation' },

    # ---- 账号 ----
    @{ From = 'wangshen0018';          To = '<your-account>' }
)

# 文件类型：只处理这些
$TextExtensions = @('.sh','.cgi','.html','.md','.conf','.ps1','.json','.yml','.yaml','.txt')

# 永远不复制到公开版的路径（正则）
$ExcludePaths = @(
    'gyp/gyp-backup.sh',      # 含真实云盘目录名与 rclone 语义
    'docs/交接文档.md',        # 含全部真实操作记录与个人数据
    'docs/SECRETS.md',        # 密钥说明，只留在私有版
    'www/network.html',       # 全是真实 IP 和端口
    'www/ariang-setup.html'   # 含真实 secret 的 base64
)
