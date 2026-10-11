# Teldrive -> Windows 盘符（rclone Teldrive 分支 + WinFsp + SSH 隧道）
# 用法（PowerShell 里粘贴）：
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/charleswei118/Telegram-Drive/main/deploy/win-mount.ps1 | iex"
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

# 3. rclone 的 Teldrive 分支（单独放，不覆盖你原来的 rclone）
$Rclone = Join-Path $Dir 'rclone.exe'
if (-not (Test-Path $Rclone)) {
  Write-Host "下载 rclone Teldrive 分支..."
  $rel = Invoke-RestMethod 'https://api.github.com/repos/tgdrive/rclone/releases/latest'
  $zipUrl = ($rel.assets | Where-Object { $_.name -like '*windows-amd64.zip' } | Select-Object -First 1).browser_download_url
  $zip = Join-Path $env:TEMP 'rclone-teldrive.zip'
  Invoke-WebRequest $zipUrl -OutFile $zip -UseBasicParsing
  $tmp = Join-Path $env:TEMP 'rclone-teldrive'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive $zip -DestinationPath $tmp
  Copy-Item (Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1).FullName $Rclone
}

# 4. 收集信息
$Ip    = Ask "VPS 公网 IP" ""
$User  = Ask "SSH 用户名" "ubuntu"
$Pem   = Ask "私钥 .pem 的完整路径（可把文件拖进窗口）" ""
$Drive = Ask "挂载到哪个盘符" "T:"
if ($Drive -notmatch ':$') { $Drive = "${Drive}:" }
$Enc   = Ask "服务端配了 encryption-key，rclone 上传也加密吗？(y/n)" "y"
Write-Host "Token：浏览器登录 Teldrive 后，F12 -> Application -> Cookies -> 复制 access_token 的值"
$sec   = Read-Host "粘贴 access_token（输入不会显示）" -AsSecureString
$Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
if (-not $Ip -or -not (Test-Path $Pem) -or -not $Token) { Write-Host "IP / 私钥路径 / Token 有误，已退出" -ForegroundColor Red; return }

# Windows 的 ssh 要求私钥只有自己能读
icacls $Pem /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null

# 5. 专用 rclone 配置
$Conf = Join-Path $Dir 'rclone.conf'
$encFlag = if ($Enc -match '^[yY]') { 'true' } else { 'false' }
@"
[teldrive]
type = teldrive
api_host = http://127.0.0.1:18080
access_token = $Token
chunk_size = 500M
upload_concurrency = 4
encrypt_files = $encFlag
random_chunk_name = true
"@ | Set-Content -Path $Conf -Encoding ASCII
icacls $Conf /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null

# 6. 启动 / 停止脚本
$Start = Join-Path $Dir 'start.ps1'
@"
`$ErrorActionPreference = 'Stop'
Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$Rclone' } | Stop-Process -Force
Start-Process ssh -WindowStyle Hidden -ArgumentList '-i "$Pem" -N -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L 18080:127.0.0.1:8080 $User@$Ip'
for (`$i=0; `$i -lt 20; `$i++) { if ((Test-NetConnection 127.0.0.1 -Port 18080 -WarningAction SilentlyContinue).TcpTestSucceeded) { break }; Start-Sleep 1 }
Start-Process '$Rclone' -WindowStyle Hidden -ArgumentList 'mount teldrive: $Drive --config "$Conf" --vfs-cache-mode full --cache-dir "$Dir\cache" --vfs-cache-max-size 20G --vfs-read-chunk-size 32M --vfs-read-chunk-streams 4 --volname Teldrive --log-file "$Dir\rclone.log" --log-level INFO'
Start-Sleep 4
if (Test-Path '$Drive\') { Write-Host 'Teldrive 已挂载到 $Drive' -ForegroundColor Green } else { Write-Host '挂载失败，查看日志: $Dir\rclone.log' -ForegroundColor Red }
"@ | Set-Content -Path $Start -Encoding UTF8

$Stop = Join-Path $Dir 'stop.ps1'
@"
Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$Rclone' } | Stop-Process -Force
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
