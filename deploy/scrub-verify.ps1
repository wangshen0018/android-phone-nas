# 公开版残留审计
#
# 上传到公开仓库前必须先跑这个，任何命中都是泄露。
# 退出码 1 = 有残留，不能发布。

[CmdletBinding()]
param([string]$Dir = "E:\DSH\repo\public")

$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path

# 绝对不允许出现在公开版里的东西
$Forbidden = @(
    @{ Name = '私有 IP';        Re = '192\.168\.\d+\.\d+';                 Sev = 'HIGH' },
    @{ Name = 'Tailscale IP';   Re = '100\.64\.\d+\.\d+';                  Sev = 'HIGH' },
    @{ Name = 'RPC 密钥';       Re = 'k40srv';                             Sev = 'HIGH' },
    @{ Name = '设备型号';       Re = 'M2012K11AC|24122RKC7C';              Sev = 'MID'  },
    @{ Name = '个人称谓';       Re = '儿子|女儿|老婆|老公';                  Sev = 'HIGH' },
    @{ Name = '证件名';         Re = '身份证|结婚证|毕业证|户口本';          Sev = 'HIGH' },
    @{ Name = '真实事件主题';   Re = '省水利厅|汇河|临沂水总';                Sev = 'MID'  },
    @{ Name = '真实账号';       Re = 'wangshen';                            Sev = 'HIGH' },
    @{ Name = '真实邮箱';       Re = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'; Sev = 'MID' },
    @{ Name = '手机号';         Re = '\b1[3-9]\d{9}\b';                     Sev = 'HIGH' },
    @{ Name = 'Windows 用户目录'; Re = 'C:\\Users\\[^\\\s]+';               Sev = 'HIGH' },
    @{ Name = 'API Key 特征';   Re = 'sk-[A-Za-z0-9]{20,}|gith[A-Za-z0-9_]{20,}'; Sev = 'HIGH' },
    @{ Name = 'Tailscale 域名'; Re = '\.ts\.net|\.tailscale\.net';          Sev = 'MID'  },
    @{ Name = 'rclone 配置路径'; Re = '/data/local/tmp/gyp/rclone\.conf';     Sev = 'MID'  }
)

$TextExt = @('.sh','.cgi','.html','.md','.conf','.ps1','.json','.txt','.yml')
$files = Get-ChildItem $Dir -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($Dir.Length + 1) -replace '\\','/'
    $rel -notlike '.git/*' -and $rel -notlike 'deploy/scrub-*'
}

Write-Host "==> 审计 $($files.Count) 个文件" Cyan
$hits = 0

foreach ($rule in $Forbidden) {
    $found = @()
    foreach ($f in $files) {
        if ($TextExt -notcontains $f.Extension -and $f.Name -notin 'root','.gitignore','.gitattributes') { continue }
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        $ms = [regex]::Matches($txt, $rule.Re)
        if ($ms.Count -gt 0) {
            $rel = $f.FullName.Substring($Dir.Length + 1)
            $vals = ($ms | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
            if ($vals.Length -gt 70) { $vals = $vals.Substring(0,70) + '...' }
            $found += "      $rel  x$($ms.Count)  [$vals]"
        }
    }
    if ($found.Count -gt 0) {
        $hits += $found.Count
        Write-Host "[$($rule.Sev)] $($rule.Name)" Red
        $found | ForEach-Object { Write-Host $_ DarkYellow }
    }
}

Write-Host ""
if ($hits -eq 0) {
    Write-Host "==> 通过：零残留，可以发布" Green
    exit 0
} else {
    Write-Host "==> 失败：$hits 处残留，禁止发布" Red
    exit 1
}
