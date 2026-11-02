# 从私有版生成公开版（脱敏复制）
#
# 用法：
#   .\deploy\scrub-copy.ps1 -Src "E:\DSH\repo\private" -Dst "E:\DSH\repo\public"
#
# 做三件事：
#   1) 按 $ExcludePaths 跳过不能公开的文件
#   2) 按 $ScrubRules 替换敏感字符串
#   3) 统一转 LF 换行（Android sh 遇 CRLF 会炸）

[CmdletBinding()]
param(
    [string]$Src = "E:\DSH\repo\private",
    [string]$Dst = "E:\DSH\repo\public"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scrub-rules.ps1"

$Src = (Resolve-Path $Src).Path
# 输出目录不能是同一个，避免自己覆盖自己
if ((Resolve-Path $Dst -ErrorAction SilentlyContinue).Path -eq $Src) {
    throw "目标目录不能等于源目录"
}

# 保留 deploy 目录里已写好的脚本本身
$selfDir = $PSScriptRoot

function IsExcluded($rel) {
    foreach ($p in $ExcludePaths) { if ($rel -eq $p -or $rel -like "$p/*") { return $true } }
    if ($rel -like '.git/*') { return $true }
    if ($rel -like 'deploy/scrub-*') { return $true }
    return $false
}

$copied = 0; $skipped = 0; $changed = 0
$stats = @{}

Get-ChildItem $Src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($Src.Length + 1) -replace '\\','/'

    if (IsExcluded $rel) {
        Write-Host "  跳过(排除) $rel" Yellow
        $skipped++
        return
    }

    $dest = Join-Path $Dst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null

    $ext = $_.Extension
    $isText = $TextExtensions -contains $ext -or $_.Name -in 'root','.gitignore','.gitattributes'

    if (-not $isText) {
        Copy-Item $_.FullName $dest -Force
        $copied++
        return
    }

    $txt = [System.IO.File]::ReadAllText($_.FullName)
    $orig = $txt

    foreach ($r in $ScrubRules) {
        if ($txt.Contains($r.From)) {
            $n = ([regex]::Matches($txt, [regex]::Escape($r.From))).Count
            $txt = $txt.Replace($r.From, $r.To)
            $key = "$($r.From) -> $($r.To)"
            if (-not $stats.ContainsKey($key)) { $stats[$key] = 0 }
            $stats[$key] += $n
        }
    }

    if ($txt -ne $orig) { $changed++ }

    # 统一 LF
    $txt = $txt -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($dest, $txt, (New-Object System.Text.UTF8Encoding($false)))
    $copied++
}

Write-Host ""
Write-Host "==> 复制 $copied 个文件，跳过 $skipped 个，改动 $changed 个" Cyan
if ($stats.Count) {
    Write-Host "==> 替换统计" Cyan
    $stats.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        Write-Host ("   {0,-42} x{1}" -f $_.Key, $_.Value)
    }
}
