# =====================================================================
# 启航 OMS —— 推送到你的 GitHub 仓库并触发 Actions 构建
# 用法：右键"使用 PowerShell 运行"，或在 PowerShell 中执行：
#   powershell -ExecutionPolicy Bypass -File .\push-and-build.ps1
# 前提：已配置 git 全局 user.name / user.email；首次推送会弹出 GitHub 登录框
# =====================================================================

$ErrorActionPreference = "Stop"

$GH_USER    = "YSM1987"
$REPO_NAME  = "qihang-oms"
$REPO_URL   = "https://github.com/$GH_USER/$REPO_NAME.git"
$PROJECT_DIR= "d:\TraeWorkspace\01_qihangERP\qihang-oms"

Set-Location $PROJECT_DIR
Write-Host "==> 项目目录: $PROJECT_DIR" -ForegroundColor Cyan

# ---------- [1] 检查提交身份 ----------
if (-not (git config user.name)) {
    git config --global user.name  $GH_USER
    Write-Host "    已设置 git user.name = $GH_USER"
}
if (-not (git config user.email)) {
    Write-Host "    [提示] git user.email 未设置，请手动执行:" -ForegroundColor Yellow
    Write-Host "           git config --global user.email ""你的邮箱"""
}

# ---------- [2] 检查远程仓库是否存在，不存在则引导 Fork ----------
git ls-remote $REPO_URL HEAD *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n仓库 $REPO_URL 不存在。" -ForegroundColor Yellow
    Write-Host "请任选其一（推荐 Fork，保留上游关联）:" -ForegroundColor Yellow
    Write-Host "  A. 打开 https://github.com/zeasin/qihang-oms/fork 点击 Create fork"
    Write-Host "  B. https://github.com/new 创建空仓库 $REPO_NAME（不要勾选 README/.gitignore/License）"
    Start-Process "https://github.com/zeasin/qihang-oms/fork"
    Read-Host "`n完成创建后按回车继续..." | Out-Null

    # 再次校验（最多重试 3 次）
    $ok = $false
    for ($i = 0; $i -lt 3; $i++) {
        git ls-remote $REPO_URL HEAD *> $null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Write-Host "    仓库仍不可见，10 秒后重试..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    if (-not $ok) { Write-Host "仓库不存在，脚本退出。" -ForegroundColor Red; exit 1 }
}
Write-Host "==> [1/5] 远程仓库存在: $REPO_URL" -ForegroundColor Green

# ---------- [3] 指向你的仓库并推送代码 ----------
git remote set-url origin $REPO_URL
Write-Host "==> [2/5] 推送 master 分支（首次会弹出 GitHub 登录，按提示授权）" -ForegroundColor Cyan
git push -u origin master
if ($LASTEXITCODE -ne 0) {
    Write-Host "推送失败。若是新建空仓库时勾选了 README，请先执行: git pull origin master --rebase 再重跑本脚本" -ForegroundColor Red
    exit 1
}

# ---------- [4] 工作流已随仓库提供（.github/workflows/build-release.yml），无需额外添加 ----------
Write-Host "==> [3/5] GitHub Actions 工作流已包含在仓库中" -ForegroundColor Green

# ---------- [5] 提醒开启 Actions 写权限 ----------
Write-Host "`n==> [4/5] 请确认已开启工作流写权限（发布 Release 必需）:" -ForegroundColor Cyan
$PERM_URL = "https://github.com/$GH_USER/$REPO_NAME/settings/actions"
Write-Host "    $PERM_URL"
Write-Host "    Workflow permissions -> 选择 'Read and write permissions' -> Save"
Start-Process $PERM_URL
Read-Host "    设置完成后按回车继续..." | Out-Null

# ---------- [6] 打 tag 触发构建 ----------
Write-Host "==> [5/5] 打 tag 触发构建" -ForegroundColor Cyan
$minor = 1
while ($true) {
    $TAG = "v3.0.$minor"
    git rev-parse -q --verify "refs/tags/$TAG" *> $null
    if ($LASTEXITCODE -ne 0) { break }
    $minor++
}
git tag $TAG
git push origin $TAG

# ---------- 完成 ----------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " 已推送并触发构建！tag: $TAG"
Write-Host " 构建进度: https://github.com/$GH_USER/$REPO_NAME/actions"
Write-Host " 产物页面: https://github.com/$GH_USER/$REPO_NAME/releases"
Write-Host " 构建约 5-10 分钟，全绿后 Releases 将出现:"
 Write-Host "   - qihang-oms-backend.tar.gz（+ .sha256）"
 Write-Host "   - qihang-oms-frontend.tar.gz（+ .sha256）"
 Write-Host " 之后在甲骨文服务器执行 install.sh 即可完成部署"
Write-Host "==========================================================" -ForegroundColor Green
