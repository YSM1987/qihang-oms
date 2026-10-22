# deploy/ —— 启航 OMS 部署体系（对齐 3x-ui 项目实现方案）

| 文件 | 职责（对应 3x-ui 组件） |
|------|------------------------|
| `install.sh` | 一键安装：依赖/swap/MySQL/Redis 初始化 + Release 下载校验 + systemd/Nginx（对应 3x-ui `install.sh`） |
| `update.sh` | 从 GitHub Release 更新（下载 + sha256 校验 + 备份回滚）（对应 `update.sh`） |
| `qihang-oms.sh` | 管理脚本：子命令 + 交互菜单（对应 `x-ui.sh` + `/usr/bin/x-ui`） |
| `qihang-oms.service` | systemd 服务单元（EnvFile / 资源约束 / 沙箱加固）（对应 `x-ui.service.debian`） |
| `nginx-qihang-oms.conf` | Nginx 站点模板（`__DOMAIN__/__PORT__/__ROOT__` 占位符） |
| `cloud-init/cloud-init.yaml` | 甲骨文云实例创建时自动初始化（对应 `deploy/cloud-init/`） |
| `test/smoke-noninteractive.sh` | 非交互安装冒烟测试（对应 `deploy/test/`） |
| `one-key-deploy.ps1` | **本地 Windows 一键部署**：自动上传全部部署文件并在服务器执行安装（全自动/交互两种模式） |
| `env.example` | 非交互安装环境变量示例 |
| `github/build-release.yml` | 放入仓库 `.github/workflows/`：构建 + 发布 Release（含 `.sha256`） |

## 目录布局（服务器上）

```
/usr/local/qihang-oms/        主目录（jar、web/dist、管理脚本、logs/、backup/、sql/）
/etc/qihang-oms/              配置（application.yml 外置配置、install-result.env 安装结果）
/etc/default/qihang-oms       systemd 环境文件（JAVA_OPTS）
/etc/systemd/system/qihang-oms.service
/usr/bin/qihang-oms           管理命令
```

## 最小安装

```bash
sudo bash install.sh
# 非交互：
QIHANG_NONINTERACTIVE=1 GITHUB_REPO=you/qihang-oms DOMAIN=oms.example.com sudo -E bash install.sh
```

安装后：`qihang-oms`（菜单）或 `qihang-oms status|log|update|uninstall`。

## 非交互模式

`QIHANG_NONINTERACTIVE=1` 显式启用，stdin 非 TTY（`curl | bash`、cloud-init）时自动启用——
与 3x-ui `XUI_NONINTERACTIVE` 机制一致。所有提示符均有环境变量对应项（见 `env.example`）。
