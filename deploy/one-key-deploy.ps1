# =====================================================================
# 启航 OMS —— 一键部署脚本（本地 Windows 直达服务器部署完成）
# 前置条件：
#   1. 已按教程完成：Fork 仓库 + push-and-build.ps1 触发构建，Release 已发布
#   2. 甲骨文安全列表已放行 TCP 80/443
#   3. Windows 自带 OpenSSH（ssh/scp，Win10+ 默认可用）
# 用法（交互式，部署中按 install.sh 提示输入仓库/域名）：
#   powershell -ExecutionPolicy Bypass -File .\one-key-deploy.ps1 -ServerIP 129.x.x.x
# 用法（全自动，推荐）：
#   powershell -ExecutionPolicy Bypass -File .\one-key-deploy.ps1 `
#     -ServerIP 129.x.x.x -GithubRepo yourname/qihang-oms -Domain oms.example.com `
#     [-SshKey C:\path\key] [-GithubToken ghp_xxx] [-AppPort 8086]
# 重复执行即"一键更新"（调用服务器上的 install.sh，安全幂等）。
# =====================================================================
param(
    [Parameter(Mandatory = $true, HelpMessage = "服务器公网 IP")]
    [string]$ServerIP,
    [string]$SshUser = "ubuntu",
    [string]$SshKey = "",                # 留空则用默认密钥（%USERPROFILE%\.ssh\）
    [string]$GithubRepo = "",            # 例: yourname/qihang-oms
    [string]$Domain = "",                # 例: oms.example.com；仅 IP 访问填 "_"
    [string]$GithubToken = "",           # 私有仓库只读 PAT（公共仓库留空）
    [int]$AppPort = 8086,
    [int]$WebPort = 30545,               # 对外访问端口（Nginx 监听，须与甲骨文安全列表放行一致）
    [switch]$NonInteractive              # 强制非交互（参数齐全时自动启用）
)

$ErrorActionPreference = "Stop"
$DeployDirLocal  = Split-Path -Parent $MyInvocation.MyCommand.Path   # deploy/ 目录
$DeployDirRemote = "/root/oms-deploy"
$UploadDirRemote = "/home/$SshUser/qihang-deploy"

$Files = @("install.sh", "update.sh", "qihang-oms.sh", "qihang-oms.service",
           "nginx-qihang-oms.conf", "env.example")

function Fail($msg) { Write-Host "[错误] $msg" -ForegroundColor Red; exit 1 }
function OK($msg)   { Write-Host $msg -ForegroundColor Green }

# ---------- SSH 参数 ----------
$sshBase = @("-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15")
if ($SshKey) {
    if (-not (Test-Path $SshKey)) { Fail "SSH 私钥不存在: $SshKey" }
    $sshBase += @("-i", $SshKey)
}
$SshTarget = "$SshUser@$ServerIP"

# ---------- [1/4] 环境检查 ----------
Write-Host "==> [1/4] 检查本地环境与服务器连通性" -ForegroundColor Cyan
foreach ($cmd in @("ssh", "scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Fail "未找到 $cmd。请在『设置 -> 应用 -> 可选功能』安装 OpenSSH 客户端"
    }
}
foreach ($f in $Files) {
    if (-not (Test-Path (Join-Path $DeployDirLocal $f))) { Fail "缺少部署文件: deploy\$f" }
}
ssh @sshBase $SshTarget "echo SSH-OK" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "SSH 连接失败: $SshTarget（检查 IP/密钥/安全列表是否放行 22）" }
OK "    服务器连接正常: $SshTarget"

# ---------- [2/4] 上传部署文件 ----------
Write-Host "==> [2/4] 上传部署文件（$($Files.Count) 个）" -ForegroundColor Cyan
ssh @sshBase $SshTarget "mkdir -p $UploadDirRemote" | Out-Null
foreach ($f in $Files) {
    scp -q @sshBase (Join-Path $DeployDirLocal $f) "${SshTarget}:${UploadDirRemote}/"
    if ($LASTEXITCODE -ne 0) { Fail "上传失败: $f" }
}
OK "    上传完成"

# ---------- [3/4] 安装（交互 / 非交互） ----------
$Auto = $NonInteractive -or ($GithubRepo -and $Domain)
Write-Host "==> [3/4] 执行服务器端安装（$(if ($Auto) { '非交互全自动' } else { '交互式，请在终端按提示输入' })）" -ForegroundColor Cyan

if ($Auto) {
    # 远程准备：root 目录、去 Windows 换行符、写 token/env，然后非交互执行 install.sh
    $envLines = @(
        "QIHANG_NONINTERACTIVE=1",
        "GITHUB_REPO=$GithubRepo",
        "DOMAIN=$Domain",
        "APP_PORT=$AppPort",
        "WEB_PORT=$WebPort"
    )
    if ($GithubToken) { $envLines += "GITHUB_TOKEN=$GithubToken" }
    $envBody = $envLines -join "`n"
    $envBody | ssh @sshBase $SshTarget "cat > $UploadDirRemote/deploy.env"

    $remote = @"
set -e
sudo mkdir -p $DeployDirRemote
sudo mv $UploadDirRemote/* $DeployDirRemote/
sudo sed -i 's/`r`$//' $DeployDirRemote/*.sh $DeployDirRemote/*.conf $DeployDirRemote/*.service
sudo chmod +x $DeployDirRemote/*.sh
if [ -n "$GithubToken" ]; then
  echo "$GithubToken" | sudo tee /root/.qihang_deploy_token > /dev/null
  sudo chmod 600 /root/.qihang_deploy_token
fi
sudo bash -c 'set -a; . $DeployDirRemote/deploy.env; set +a; bash $DeployDirRemote/install.sh'
sudo rm -f $DeployDirRemote/deploy.env
"@
    $remote | ssh @sshBase $SshTarget "bash -s"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "安装未成功。排查: ssh $SshTarget 后执行 journalctl -u qihang-oms -n 100" -ForegroundColor Yellow
        exit 1
    }
}
else {
    # 交互式：分配 TTY，install.sh 会依次提示输入仓库/域名
    ssh -tt @sshBase $SshTarget "sudo bash -c 'mkdir -p $DeployDirRemote && mv $UploadDirRemote/* $DeployDirRemote/ && sed -i s/`r`$// $DeployDirRemote/*.sh && chmod +x $DeployDirRemote/*.sh && bash $DeployDirRemote/install.sh'"
    if ($LASTEXITCODE -ne 0) { Fail "安装未成功，请查看上方输出" }
}

# ---------- [4/4] 验证 ----------
Write-Host "==> [4/4] 远程健康检查" -ForegroundColor Cyan
$health = ssh @sshBase $SshTarget "curl -fs -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$AppPort/captchaImage 2>/dev/null || echo FAIL"
if ($health -eq "200") {
    OK "    后端健康检查: 200 OK"
} else {
    Write-Host "    健康检查未通过($health)，首次启动可能仍在进行，稍后手动复查:" -ForegroundColor Yellow
    Write-Host "    ssh $SshTarget `"sudo systemctl status qihang-oms`"" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " 一键部署流程结束！" -ForegroundColor Green
$siteHost = if ($Domain -and $Domain -ne "_") { $Domain } else { $ServerIP }
if ($WebPort -eq 80) { Write-Host " 访问地址 : http://$siteHost" }
else { Write-Host " 访问地址 : http://${siteHost}:$WebPort" }
Write-Host " 默认账号 : admin / Andy@2025（登录后立即修改密码）"
Write-Host " 服务器端 : qihang-oms（status/log/update/restart/uninstall）"
if ($WebPort -eq 80) {
    Write-Host " HTTPS    : certbot --nginx -d $Domain --redirect（见教程 4.3 节）"
} else {
    Write-Host " HTTPS    : 对外端口非 80，需 DNS 验证方式（见教程 HTTPS 章节）"
}
Write-Host "==========================================================" -ForegroundColor Green
