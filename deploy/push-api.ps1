# 用 GitHub Git Data API 批量上传整个目录
#
# 为什么不用 git push：
#   本机 github.com:443 被网络干扰，Watt 反代对 git 的 POST 通道不通（push 会卡死）。
#   但 api.github.com 稳定可用，所以走 REST API。
#
# 为什么用 Git Data API 而不是 Contents API：
#   Contents API 是「一个文件一次提交」，48 个文件 = 48 次提交，很脏。
#   Git Data API 可以先建 blob、建 tree、建 commit，一次推上去。
#
# 用法：
#   $env:GH_PAT = "..."
#   .\deploy\push-api.ps1 -Repo "<your-account>/k40-family-nas" -Dir "E:\DSH\repo\private"

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Dir,
    [string]$Branch = "main",
    [string]$Message = "sync from local",
    [string]$Pat = $env:GH_PAT
)

$ErrorActionPreference = 'Stop'
if (-not $Pat) { throw "缺少 PAT：设置 `$env:GH_PAT 或传 -Pat" }

$Api = "https://api.github.com/repos/$Repo"
$H = @{
    Authorization = "Bearer $Pat"
    Accept        = "application/vnd.github+json"
    "User-Agent"  = "k40-deploy"
}

function Call($Method, $Uri, $Body) {
    $p = @{ Uri = $Uri; Headers = $H; Method = $Method; TimeoutSec = 45 }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $p.ContentType = "application/json" }
    for ($i = 0; $i -lt 3; $i++) {
        try { return Invoke-RestMethod @p }
        catch {
            if ($i -eq 2) { throw }
            Start-Sleep -Seconds (2 * ($i + 1))
        }
    }
}

# ---------- 1. 现有分支头 ----------
Write-Host "==> 读取 $Branch 当前 HEAD" Cyan
$ref = $null
try { $ref = Call GET "$Api/git/ref/heads/$Branch" "" } catch { Write-Host "    分支尚不存在，将初始化" Yellow }

$parentSha = $null
$baseTreeSha = $null
if ($ref) {
    $parentSha = $ref.object.sha
    $pc = Call GET "$Api/git/commits/$parentSha" ""
    $baseTreeSha = $pc.tree.sha
    Write-Host "    父提交 $($parentSha.Substring(0,7))"
}

# ---------- 2. 收集文件 ----------
$Dir = (Resolve-Path $Dir).Path
$gitDir = Join-Path $Dir ".git"
$files = Get-ChildItem $Dir -Recurse -File | Where-Object { $_.FullName -notlike "*$gitDir*" }
Write-Host "==> 待上传 $($files.Count) 个文件" Cyan

# ---------- 3. 建 blob ----------
$tree = @()
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Dir.Length + 1) -replace '\\','/'
    # 文本文件统一转 LF（Android sh 遇 CRLF 会炸）
    $isText = $f.Extension -in '.sh','.cgi','.html','.md','.conf','.ps1','.gitignore','.gitattributes' -or $f.Name -in 'root','.gitignore','.gitattributes'
    if ($isText) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        $txt = $txt -replace "`r`n", "`n"
        $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($txt))
        $enc = "utf-8"
    } else {
        $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
        $enc = "base64"
    }

    $blob = Call POST "$Api/git/blobs" @{ content = $content; encoding = $enc }
    $tree += @{ path = $rel; mode = "100644"; type = "blob"; sha = $blob.sha }
}

# CGI 需要可执行位（100755），否则 httpd 可能拒绝执行
$cgis = $files | Where-Object { $_.Extension -eq '.cgi' -or $_.Extension -eq '.sh' }
foreach ($t in $tree) {
    if ($t.path -match '\.(cgi|sh)$' -or $t.path -eq 'cron/root') { $t.mode = "100755" }
}

# ---------- 4. 建 tree ----------
Write-Host "==> 建 tree" Cyan
$treeBody = @{ tree = $tree }
if ($baseTreeSha) { $treeBody.base_tree = $baseTreeSha }
$newTree = Call POST "$Api/git/trees" $treeBody

# ---------- 5. 建 commit ----------
Write-Host "==> 建 commit" Cyan
$commitBody = @{ message = $Message; tree = $newTree.sha }
if ($parentSha) { $commitBody.parents = @($parentSha) }
$newCommit = Call POST "$Api/git/commits" $commitBody

# ---------- 6. 更新分支 ----------
Write-Host "==> 更新 $Branch" Cyan
$refBody = @{ sha = $newCommit.sha; force = $false }
if ($ref) {
    Call PATCH "$Api/git/refs/heads/$Branch" $refBody | Out-Null
} else {
    Call POST "$Api/git/refs" @{ ref = "refs/heads/$Branch"; sha = $newCommit.sha } | Out-Null
}

Write-Host ""
Write-Host "完成：$Repo @ $Branch" Green
Write-Host "  提交 $($newCommit.sha.Substring(0,7))  文件 $($files.Count) 个"
Write-Host "  https://github.com/$Repo"
