#!/usr/bin/env bash
# =====================================================================
# 启航 OMS 管理脚本（对齐 3x-ui x-ui.sh：子命令 + 交互菜单）
# 安装位置: /usr/local/qihang-oms/qihang-oms.sh，软链 /usr/bin/qihang-oms
# 用法: qihang-oms [start|stop|restart|status|log|update|uninstall|settings|version|enable|disable]
#       无参数时进入交互菜单
# =====================================================================

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

qihang_folder="${QIHANG_MAIN_FOLDER:=/usr/local/qihang-oms}"
qihang_conf="${QIHANG_CONF_FOLDER:=/etc/qihang-oms}"
service_name="qihang-oms"

LOGE() { echo -e "${red}${1}${plain}"; }
LOGI() { echo -e "${green}${1}${plain}"; }

conf_get() { # conf_get <KEY> —— 从 install-result.env 读取
    local key="$1" val=""
    if [ -f "${qihang_conf}/install-result.env" ]; then
        # shellcheck disable=SC1090
        val=$(source "${qihang_conf}/install-result.env" && echo "${!key:-}")
    fi
    echo "$val"
}

check_install() { # 0=静默 1=报错提示
    if ! systemctl list-unit-files | grep -q "^${service_name}.service"; then
        [ "${1:-1}" != "0" ] && LOGE "${service_name} 未安装，请先运行 install.sh"
        return 1
    fi
    return 0
}

start() { systemctl start "$service_name" && LOGI "${service_name} started" || LOGE "start failed"; }
stop() { systemctl stop "$service_name" && LOGI "${service_name} stopped" || LOGE "stop failed"; }
restart() { systemctl restart "$service_name" && LOGI "${service_name} restarted" || LOGE "restart failed"; }
enable() { systemctl enable "$service_name" && LOGI "${service_name} enabled (开机自启)"; }
disable() { systemctl disable "$service_name" && LOGI "${service_name} disabled"; }

show_log() {
    journalctl -u "$service_name" --no-pager -n 100 "${1:--f}"
}

version() {
    local ver
    ver=$(conf_get VERSION)
    echo -e "Qihang OMS ${ver:-unknown}"
}

status() {
    systemctl status "$service_name" --no-pager -l
    echo ""
    echo -e "———— 系统资源概览 ————"
    free -m | awk 'NR==1||/^Mem:|^Swap:/'
    echo ""
    df -h / | awk 'NR==1||/^\/dev/'
    local port
    port=$(conf_get APP_PORT); port=${port:-8086}
    if curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:${port}/captchaImage"; then
        LOGI "后端健康检查: OK (127.0.0.1:${port}/captchaImage)"
    else
        LOGE "后端健康检查: FAILED —— journalctl -u ${service_name} -n 100 查看日志"
    fi
}

settings() {
    local ver domain port webport
    ver=$(conf_get VERSION); domain=$(conf_get DOMAIN); port=$(conf_get APP_PORT); webport=$(conf_get WEB_PORT)
    echo -e "———— ${service_name} 配置信息 ————"
    echo -e " 主目录      : ${qihang_folder}"
    echo -e " 配置目录    : ${qihang_conf}"
    echo -e " 日志目录    : ${qihang_folder}/logs （journalctl -u ${service_name}）"
    echo -e " 访问域名    : ${domain:-未设置}"
    echo -e " 后端端口    : ${port:-8086}"
    echo -e " 对外端口    : ${webport:-30545}"
    echo -e " 当前版本    : ${ver:-unknown}"
    echo -e " JVM 参数    : /etc/default/${service_name} (JAVA_OPTS)"
    echo -e " 应用配置    : ${qihang_conf}/application.yml（外置，更新不覆盖）"
    echo -e " MySQL/Redis : 密码见 ${qihang_conf}/install-result.env（root 可读）"
    echo -e " Nginx 站点  : /etc/nginx/sites-available/${service_name}"
    echo -e " 旧版回滚    : ${qihang_folder}/backup/ （保留最近 5 份）"
}

update() {
    check_install || return 1
    bash "${qihang_folder}/update.sh" "$@"
}

uninstall() {
    check_install || exit 1
    echo -e "${yellow}即将卸载 ${service_name}（服务/脚本/Nginx 站点）${plain}"
    read -rp "确认卸载? [y/n]: " confirm
    [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "已取消"; exit 0; }

    systemctl stop "$service_name" 2> /dev/null || true
    systemctl disable "$service_name" 2> /dev/null || true
    rm -f /etc/systemd/system/"$service_name".service
    rm -f /etc/default/"$service_name"
    rm -f /etc/systemd/journald.conf.d/qihang-oms.conf
    systemctl daemon-reload

    rm -f /etc/nginx/sites-enabled/"$service_name"
    rm -f /etc/nginx/sites-available/"$service_name"
    nginx -t 2> /dev/null && systemctl reload nginx 2> /dev/null || true

    rm -f /usr/bin/qihang-oms
    rm -rf "${qihang_folder}"

    echo -e "${yellow}以下内容已保留，如需彻底清理请手动处理：${plain}"
    echo -e "  - 应用配置与密码: ${qihang_conf}"
    echo -e "  - MySQL 数据库 qihang-oms 与账号 qihang"
    echo -e "  - Redis 密码配置 /etc/redis/redis.conf"
    LOGI "卸载完成"
}

show_menu() {
    echo -e "${green}====== 启航 OMS 管理脚本 ======${plain}"
    echo -e " ${blue}1.${plain} 启动 OMS           ${blue}6.${plain} 查看日志"
    echo -e " ${blue}2.${plain} 停止 OMS           ${blue}7.${plain} 更新 OMS（GitHub Release）"
    echo -e " ${blue}3.${plain} 重启 OMS           ${blue}8.${plain} 卸载 OMS"
    echo -e " ${blue}4.${plain} 查看运行状态       ${blue}9.${plain} 查看配置信息"
    echo -e " ${blue}5.${plain} 查看版本           ${blue}0.${plain} 退出"
    echo ""
    read -rp "请输入选项 [0-9]: " num
    case "$num" in
        1) check_install && start ;;
        2) check_install && stop ;;
        3) check_install && restart ;;
        4) check_install && status ;;
        5) check_install && version ;;
        6) check_install && show_log ;;
        7) check_install && update ;;
        8) uninstall ;;
        9) check_install && settings ;;
        0) exit 0 ;;
        *) LOGE "请输入正确编号 [0-9]" ;;
    esac
}

show_usage() {
    echo "用法: qihang-oms [start|stop|restart|status|log|update|uninstall|settings|version|enable|disable]"
    echo "      qihang-oms update [tag]   更新到指定/最新版本"
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        "start")     check_install && start ;;
        "stop")      check_install && stop ;;
        "restart")   check_install && restart ;;
        "status")    check_install && status ;;
        "log")       check_install && show_log "${2:--f}" ;;
        "update")    check_install && update "${2:-}" ;;
        "settings")  check_install && settings ;;
        "version")   check_install && version ;;
        "enable")    check_install && enable ;;
        "disable")   check_install && disable ;;
        "uninstall") uninstall ;;
        "menu")      show_menu ;;
        *)           show_usage ;;
    esac
else
    show_menu
fi
