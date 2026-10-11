# Teldrive -> Windows 盘符（rclone Teldrive 分支 + WinFsp + SSH 隧道）
# 用法（PowerShell 里逐行执行，先下载到本地再运行）：
#   cd $env:USERPROFILE\Downloads
#   iwr https://raw.githubusercontent.com/charleswei118/Telegram-Drive/main/deploy/win-mount.ps1 -OutFile win-mount.ps1
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\win-mount.ps1
# 不会改动你已安装的 rclone 和它的配置；所有文件放在 %LOCALAPPDATA%\teldrive-mount

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dir = Join-Path $env:LOCALAPPDATA 'teldrive-mount'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

function Ask($q, $def) {
  $a = Read-Host "$q$(if ($def) { " [默认 $def]" })"
  if ([string]::IsNullOrWhiteSpace($a)) { $def } else { $a.Trim().Trim('"') }
}

Write-Host "`n== Teldrive 挂载到 Windows ==" -ForegroundColor Cyan

# 1. ssh 客户端
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Write-Host "没找到 ssh。请在 设置 -> 应用 -> 可选功能 里添加 'OpenSSH 客户端' 后重跑。" -ForegroundColor Red; return
}

# 2. WinFsp
$winfsp = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -or (Test-Path "${env:ProgramFiles(x86)}\WinFsp\bin")
if (-not $winfsp) {
  Write-Host "安装 WinFsp（会弹出管理员确认）..."
  $rel = Invoke-RestMethod 'https://api.github.com/repos/winfsp/winfsp/releases/latest'
  $msiUrl = ($rel.assets | Where-Object { $_.name -like '*.msi' } | Select-Object -First 1).browser_download_url
  $msi = Join-Path $env:TEMP 'winfsp.msi'
  Invoke-WebRequest $msiUrl -OutFile $msi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qb" -Verb RunAs -Wait
}

# 3. 先停掉之前残留的隧道和 rclone
Get-Process rclone* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -like '*18080:127.0.0.1:8080*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 4. 收集信息
$Ip    = Ask "VPS 公网 IP" ""
$User  = Ask "SSH 用户名（Lightsail Debian 是 admin）" "admin"
$Pem   = Ask "私钥 .pem 的完整路径（可把文件拖进窗口）" ""
$Pem   = [Environment]::ExpandEnvironmentVariables($Pem)
$Drive = Ask "挂载到哪个盘符" "T:"
if ($Drive -notmatch ':$') { $Drive = "${Drive}:" }
$Enc   = Ask "服务端配了 encryption-key，rclone 上传也加密吗？(y/n)" "y"
if (-not $Ip -or -not (Test-Path $Pem)) { Write-Host "IP 或私钥路径有误，已退出" -ForegroundColor Red; return }

# Windows 的 ssh 要求私钥只有自己能读
icacls $Pem /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null

# 先测 SSH，并识别服务端 Teldrive 版本（1.x 用 access_token Cookie，2.x 用 API Key，rclone 版本必须匹配）
Write-Host "测试 SSH 并检测 Teldrive 版本..."
$ErrorActionPreference = 'Continue'
$probe = ssh -i "$Pem" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$User@$Ip" "curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8080/api/health/live; curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8080/api/v1/me"
if ($LASTEXITCODE -ne 0 -and -not $probe) { Write-Host "SSH 连不上：检查 IP、用户名 admin、私钥是否对应这台实例，以及 Lightsail 防火墙是否放行 22 端口" -ForegroundColor Red; return }
$ErrorActionPreference = 'Stop'
$V2 = ("$probe".Trim() -eq '200401')
if ($V2) {
  $RcloneTag = 'latest'; $AuthKey = 'api_key'
  Write-Host "服务端是 Teldrive 2.x"
  Write-Host "网页登录 Teldrive -> Settings -> API keys -> 新建一个，复制生成的 Key"
  $sec = Read-Host "粘贴 API Key（输入不会显示）" -AsSecureString
} else {
  $RcloneTag = 'v1.73.1'; $AuthKey = 'access_token'
  Write-Host "服务端是 Teldrive 1.x"
  Write-Host "浏览器打开 Teldrive -> Ctrl+Shift+I -> Application -> Cookies -> 复制 access_token 的 Value"
  $sec = Read-Host "粘贴 access_token（输入不会显示）" -AsSecureString
}
$Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
if (-not $Token) { Write-Host "没有粘贴内容，已退出" -ForegroundColor Red; return }

# rclone 的 Teldrive 分支（版本与服务端匹配；单独放，不覆盖你原来的 rclone）
$Rclone = Join-Path $Dir "rclone-$RcloneTag.exe"
if (-not (Test-Path $Rclone)) {
  Write-Host "下载 rclone Teldrive 分支 ($RcloneTag)..."
  $api = if ($RcloneTag -eq 'latest') { 'https://api.github.com/repos/tgdrive/rclone/releases/latest' } else { "https://api.github.com/repos/tgdrive/rclone/releases/tags/$RcloneTag" }
  $rel = Invoke-RestMethod $api
  $zipUrl = ($rel.assets | Where-Object { $_.name -like '*windows-amd64.zip' } | Select-Object -First 1).browser_download_url
  $zip = Join-Path $env:TEMP 'rclone-teldrive.zip'
  Invoke-WebRequest $zipUrl -OutFile $zip -UseBasicParsing
  $tmp = Join-Path $env:TEMP 'rclone-teldrive'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive $zip -DestinationPath $tmp
  Copy-Item (Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1).FullName $Rclone
}

# 5. 专用 rclone 配置
$Conf = Join-Path $Dir 'rclone.conf'
$encFlag = if ($Enc -match '^[yY]') { 'true' } else { 'false' }
@"
[teldrive]
type = teldrive
api_host = http://127.0.0.1:18080
$AuthKey = $Token
chunk_size = 500M
upload_concurrency = 4
encrypt_files = $encFlag
"@ | Set-Content -Path $Conf -Encoding ASCII
icacls $Conf /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null

Write-Host "验证登录..."
$ErrorActionPreference = 'Continue'
$t = Start-Process ssh -WindowStyle Hidden -PassThru -ArgumentList "-i `"$Pem`" -N -o ExitOnForwardFailure=yes -L 18080:127.0.0.1:8080 $User@$Ip"
Start-Sleep 4
& $Rclone lsd teldrive: --config $Conf --max-depth 1 2>&1 | Select-Object -Last 5
$okAuth = ($LASTEXITCODE -eq 0)
Stop-Process -Id $t.Id -Force -ErrorAction SilentlyContinue
if (-not $okAuth) { Write-Host "认证失败：Token/Key 不对或已过期，重新复制后再运行本脚本" -ForegroundColor Red; return }
Write-Host "认证成功" -ForegroundColor Green
$ErrorActionPreference = 'Stop'

# 6. 启动 / 停止脚本
$Start = Join-Path $Dir 'start.ps1'
@"
`$ErrorActionPreference = 'Stop'
Get-Process rclone* -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$Rclone' } | Stop-Process -Force
Start-Process ssh -WindowStyle Hidden -ArgumentList '-i "$Pem" -N -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L 18080:127.0.0.1:8080 $User@$Ip'
`$ok = `$false
for (`$i=0; `$i -lt 20; `$i++) { if ((Test-NetConnection 127.0.0.1 -Port 18080 -WarningAction SilentlyContinue).TcpTestSucceeded) { `$ok = `$true; break }; Start-Sleep 1 }
if (-not `$ok) { Write-Host 'SSH 隧道没建立，检查网络/私钥/22 端口' -ForegroundColor Red; return }
Start-Process '$Rclone' -WindowStyle Hidden -ArgumentList 'mount teldrive: $Drive --config "$Conf" --vfs-cache-mode full --cache-dir "$Dir\cache" --vfs-cache-max-size 20G --vfs-read-chunk-size 32M --vfs-read-chunk-streams 4 --volname Teldrive --log-file "$Dir\rclone.log" --log-level INFO'
for (`$i=0; `$i -lt 15; `$i++) { if (Test-Path '$Drive\') { break }; Start-Sleep 1 }
if (Test-Path '$Drive\') { Write-Host 'Teldrive 已挂载到 $Drive' -ForegroundColor Green } else { Write-Host '挂载失败，查看日志: $Dir\rclone.log' -ForegroundColor Red }
"@ | Set-Content -Path $Start -Encoding UTF8

$Stop = Join-Path $Dir 'stop.ps1'
@"
Get-Process rclone* -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$Rclone' } | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { `$_.CommandLine -like '*18080:127.0.0.1:8080*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }
Write-Host 'Teldrive 已卸载'
"@ | Set-Content -Path $Stop -Encoding UTF8

# 7. 桌面快捷方式
$ws = New-Object -ComObject WScript.Shell
foreach ($p in @(@('Teldrive 挂载', $Start), @('Teldrive 卸载', $Stop))) {
  $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "$($p[0]).lnk"))
  $lnk.TargetPath = 'powershell.exe'
  $lnk.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($p[1])`""
  $lnk.Save()
}

Write-Host "`n首次挂载中..." -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File $Start
Write-Host "以后双击桌面上的 'Teldrive 挂载' / 'Teldrive 卸载' 即可。" -ForegroundColor Cyan
