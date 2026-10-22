#!/usr/bin/env bash
# =====================================================================
# 启航 OMS —— 一键安装脚本（部署体系对齐 3x-ui 项目实现方案）
#
# 用法（root 执行）：
#   交互安装：
#     bash install.sh
#   非交互安装（云初始化 / curl | bash / cloud-init）：
#     QIHANG_NONINTERACTIVE=1 GITHUB_REPO=you/qihang-oms DOMAIN=oms.example.com bash install.sh
#     （stdin 非 TTY 时自动进入非交互模式，与 3x-ui XUI_NONINTERACTIVE 机制一致）
#
# 私有仓库需先放置只读 PAT（classic，勾选 repo）：
#   echo "ghp_xxxxxxxx" > /root/.qihang_deploy_token
#
# 目录布局（对齐 3x-ui /usr/local/x-ui + /etc/x-ui 模式）：
#   /usr/local/qihang-oms            主目录（jar、web/dist、脚本、日志、备份）
#   /etc/qihang-oms                  配置目录（application.yml、install-result.env）
#   /etc/default/qihang-oms          systemd 环境文件（JAVA_OPTS）
#   /etc/systemd/system/qihang-oms.service
#   /usr/bin/qihang-oms              管理命令软链
# 该脚本可重复执行：重复执行即视为"升级 + 重装依赖检查"，数据不受影响。
# =====================================================================
set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

qihang_folder="${QIHANG_MAIN_FOLDER:=/usr/local/qihang-oms}"
qihang_conf="${QIHANG_CONF_FOLDER:=/etc/qihang-oms}"
qihang_service_dir="${QIHANG_SERVICE:=/etc/systemd/system}"

# ---------------- 检查 root（对齐 3x-ui） ----------------
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege\n" && exit 1

# ---------------- 检查 OS（对齐 3x-ui） ----------------
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: ${release} ${VERSION_ID:-}"

# ---------------- 检查架构（Java 产物跨架构，仅提示） ----------------
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        *) echo 'unknown' ;;
    esac
}
echo "Arch: $(arch) (Java/静态资源跨架构通用)"

# ---------------- 非交互模式（对齐 3x-ui NONINTERACTIVE 机制） ----------------
if [[ "${QIHANG_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    NONINTERACTIVE=1
else
    NONINTERACTIVE=0
fi
export NONINTERACTIVE

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    command -v netstat > /dev/null 2>&1 && netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
    return 1
}

# ---------------- GitHub 仓库与下载（对齐 3x-ui resolve_latest_tag / checksum 机制） ----------------
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$GITHUB_TOKEN" ] && [ -f /root/.qihang_deploy_token ]; then
    GITHUB_TOKEN=$(tr -d '[:space:]' < /root/.qihang_deploy_token)
fi

gh_curl() { # gh_curl <url> [输出文件]
    local url="$1" out="${2:-}"
    local args=(-fL --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 600
                --speed-limit 1 --speed-time 300
                -H "Accept: application/vnd.github+json")
    [ -n "$GITHUB_TOKEN" ] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    [ -n "$out" ] && args+=(-o "$out")
    curl "${args[@]}" "$url"
}

# releases/latest 重定向优先（免 API 60次/小时限流），失败回退 API —— 与 3x-ui 相同
resolve_latest_tag() {
    local url tag
    url=$(curl -sSLI -o /dev/null -w '%{url_effective}' --retry 5 --retry-delay 3 \
          --connect-timeout 15 --max-time 60 \
          "https://github.com/${GITHUB_REPO}/releases/latest" 2> /dev/null || true)
    tag=${url##*/tag/}
    if [[ "$tag" != "$url" && -n "$tag" && "$tag" != "latest" ]]; then
        echo "$tag"
        return 0
    fi
    curl -Ls --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 60 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true
}

# 每个产物旁发布 <asset>.sha256 sidecar；校验失败即中止，404（旧版 Release）容忍并告警 —— 与 3x-ui 相同
verify_release_checksum() {
    local url="$1" file="$2" sums="$2.sha256" code expected actual
    rm -f "${sums}"
    code=$(curl -sL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 \
           -o "${sums}" -w '%{http_code}' -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}.sha256")
    if [[ "${code}" == "404" ]]; then
        rm -f "${sums}"
        echo -e "${yellow}No checksum published for this release, skipping verification${plain}"
        return 0
    fi
    if [[ "${code}" != "200" ]]; then
        rm -f "${sums}" "${file}"
        echo -e "${red}Failed to download the checksum for $(basename "${file}") (HTTP ${code})${plain}"
        exit 1
    fi
    expected=$(awk 'NR == 1 {print $1}' "${sums}")
    actual=$(sha256sum "${file}" | awk '{print $1}')
    rm -f "${sums}"
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ || "${expected}" != "${actual}" ]]; then
        rm -f "${file}"
        echo -e "${red}Checksum mismatch for $(basename "${file}"): expected ${expected:-<none>}, got ${actual}${plain}"
        exit 1
    fi
    echo -e "${green}Checksum verified: ${actual}${plain}"
}

# 部署配套文件（管理脚本 / service / nginx 模板）：优先取本脚本同目录，缺失时回退 GitHub raw
fetch_support_file() { # fetch_support_file <name> <dest>
    local name="$1" dest="$2" status
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2> /dev/null && pwd || true)"
    if [[ -n "$script_dir" && -s "${script_dir}/${name}" ]]; then
        cp -f "${script_dir}/${name}" "${dest}"
        return 0
    fi
    status=$(curl -sIL --retry 3 --connect-timeout 15 -o /dev/null -w '%{http_code}' \
             -H "Authorization: Bearer ${GITHUB_TOKEN}" \
             "https://raw.githubusercontent.com/${GITHUB_REPO}/master/deploy/${name}")
    if [[ "${status}" == "200" ]]; then
        gh_curl "https://raw.githubusercontent.com/${GITHUB_REPO}/master/deploy/${name}" "${dest}"
        return 0
    fi
    return 1
}

# ---------------- 安装基础软件 ----------------
install_base() {
    echo -e "${green}Installing base packages...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y -q openjdk-17-jre-headless mysql-server redis-server nginx \
                cron curl jq tar openssl ca-certificates
            ;;
        *)
            echo -e "${red}Unsupported OS: ${release}. 本脚本支持 Ubuntu / Debian（推荐 Ubuntu 24.04）。${plain}"
            exit 1
            ;;
    esac
}

# ---------------- 小内存 swap（甲骨文 AMD 免费机 1GB 内存必须） ----------------
ensure_swap() {
    local mem_mb swap_mb
    mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    swap_mb=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${mem_mb}" -lt 2048 ] && [ "${swap_mb}" -lt 512 ]; then
        echo -e "${yellow}Low memory (${mem_mb}MB), creating 2G swap...${plain}"
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "vm.swappiness=20" > /etc/sysctl.d/99-qihang-swap.conf
        sysctl --system > /dev/null
    fi
}

# ---------------- MySQL 初始化 + 低内存调优 ----------------
DB_PASSWORD="${DB_PASSWORD:-$(gen_random_string 20)}"
init_mysql() {
    echo -e "${green}Initializing MySQL...${plain}"
    mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`qihang-oms\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'qihang'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'qihang'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`qihang-oms\`.* TO 'qihang'@'localhost';
FLUSH PRIVILEGES;
SQL
    # 1GB 内存机 MySQL 低内存调优（不改任何业务数据结构）
    cat > /etc/mysql/mysql.conf.d/zz-qihang-lowmem.cnf <<'CNF'
[mysqld]
# ---- 低内存精简（甲骨文 1GB 免费机）----
innodb_buffer_pool_size = 128M
performance_schema = OFF
max_connections = 60
table_open_cache = 200
thread_cache_size = 16
tmp_table_size = 16M
max_heap_table_size = 16M
innodb_log_buffer_size = 8M
key_buffer_size = 8M
skip-name-resolve = 1
CNF
    systemctl restart mysql
}

# ---------------- Redis 配置（仅本机 + 密码） ----------------
REDIS_PASSWORD="${REDIS_PASSWORD:-$(gen_random_string 20)}"
init_redis() {
    echo -e "${green}Configuring Redis...${plain}"
    sed -i "s|^# *requirepass .*|requirepass ${REDIS_PASSWORD}|" /etc/redis/redis.conf
    sed -i "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" /etc/redis/redis.conf
    sed -i "s|^bind .*|bind 127.0.0.1 -::1|" /etc/redis/redis.conf
    systemctl restart redis
}

# ---------------- 应用目录 / 配置 ----------------
APP_PORT="${APP_PORT:-8086}"
WEB_PORT="${WEB_PORT:-30545}"   # 对外访问端口（Nginx 监听），甲骨文安全列表需放行该端口
write_config() {
    id -u qihang > /dev/null 2>&1 || useradd -r -m -s /usr/sbin/nologin qihang
    install -d -m 755 "${qihang_folder}" "${qihang_folder}/web" "${qihang_folder}/sql" "${qihang_folder}/backup"
    install -d -m 700 -o qihang -g qihang "${qihang_conf}"
    install -d -m 755 -o qihang -g qihang "${qihang_folder}/logs" "${qihang_folder}/web/dist"

    # 外置 application.yml（Spring Boot additional-location 加载，更新 jar 不受影响）
    # 连接池 / Undertow 线程 / banner 均按 1GB 内存机轻量化，业务逻辑零改动
    cat > "${qihang_conf}/application.yml" <<YML
server:
  port: ${APP_PORT}
  undertow:
    threads:
      io: 2
      worker: 8
spring:
  main:
    banner-mode: off
  messages:
    basename: i18n/messages
  application:
    name: qihang-oms
  data:
    redis:
      host: 127.0.0.1
      port: 6379
      database: 0
      password: ${REDIS_PASSWORD}
      timeout: 10s
      lettuce:
        pool:
          min-idle: 0
          max-idle: 4
          max-active: 8
          max-wait: -1ms
  datasource:
    driverClassName: com.mysql.cj.jdbc.Driver
    url: jdbc:mysql://localhost:3306/qihang-oms?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=false&serverTimezone=GMT%2B8
    username: qihang
    password: ${DB_PASSWORD}
    hikari:
      maximum-pool-size: 5
      min-idle: 2
      connection-timeout: 30000
      idle-timeout: 600000
      max-lifetime: 1800000
qihangerp:
  captchaType: math
user:
  password:
    maxRetryCount: 5
    lockTime: 10
mybatis-plus:
  mapper-locations: classpath*:mapper/**/*Mapper.xml
  type-aliases-package: cn.qihangerp.module.sys.domain;cn.qihangerp.domain;
YML
    chown qihang:qihang "${qihang_conf}/application.yml"
    chmod 600 "${qihang_conf}/application.yml"
}

# write_install_result <tag> —— 持久化可解析的安装结果（对齐 3x-ui write_install_result）
write_install_result() {
    local tag="$1"
    local result_file="${qihang_conf}/install-result.env"
    local install_time
    install_time=$(date '+%Y-%m-%d %H:%M:%S')
    {
        printf 'GITHUB_REPO=%q\n' "${GITHUB_REPO}"
        printf 'DOMAIN=%q\n' "${DOMAIN}"
        printf 'APP_PORT=%q\n' "${APP_PORT}"
        printf 'WEB_PORT=%q\n' "${WEB_PORT}"
        printf 'DB_PASSWORD=%q\n' "${DB_PASSWORD}"
        printf 'REDIS_PASSWORD=%q\n' "${REDIS_PASSWORD}"
        printf 'VERSION=%q\n' "${tag}"
        printf 'INSTALL_TIME=%q\n' "${install_time}"
    } > "${result_file}"
    chmod 600 "${result_file}"
    chown root:root "${result_file}"
}

# ---------------- 安装 systemd 服务 ----------------
install_service() {
    echo -e "${green}Installing systemd service...${plain}"
    # 环境文件：JVM 参数可在此直接调整（1GB 内存机轻量化参数）
    cat > /etc/default/qihang-oms <<'ENVF'
# 启航 OMS JVM 参数（轻量化：小堆 + SerialGC + 限制元空间；机器内存更大可调高 -Xmx）
JAVA_OPTS="-Xms128m -Xmx512m -Xss512k -XX:MaxMetaspaceSize=160m -XX:+UseSerialGC -XX:MaxGCPauseMillis=200 -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/usr/local/qihang-oms/logs -Xlog:gc:file=/usr/local/qihang-oms/logs/gc.log:time,uptime:filecount=2,filesize=5m -Djava.security.egd=file:/dev/./urandom -Dfile.encoding=UTF-8"
ENVF
    chmod 644 /etc/default/qihang-oms

    fetch_support_file "qihang-oms.service" "${qihang_service_dir}/qihang-oms.service.tmp" || {
        echo -e "${red}获取 qihang-oms.service 失败（本地目录与 GitHub raw 均不可达）${plain}"
        exit 1
    }
    sed "s#__GITHUB_REPO__#${GITHUB_REPO}#g" "${qihang_service_dir}/qihang-oms.service.tmp" \
        > "${qihang_service_dir}/qihang-oms.service"
    rm -f "${qihang_service_dir}/qihang-oms.service.tmp"
    systemctl daemon-reload
    systemctl enable qihang-oms

    # journald 日志限额，防小盘被日志吃满
    install -d -m 755 /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/qihang-oms.conf <<'JCONF'
[Journal]
SystemMaxUse=100M
JCONF
    systemctl try-restart systemd-journald 2> /dev/null || true
}

# ---------------- 安装管理脚本（对齐 3x-ui x-ui.sh + /usr/bin/x-ui） ----------------
install_manage_script() {
    echo -e "${green}Installing management script...${plain}"
    fetch_support_file "qihang-oms.sh" "${qihang_folder}/qihang-oms.sh" || {
        echo -e "${red}获取 qihang-oms.sh 失败${plain}"
        exit 1
    }
    fetch_support_file "update.sh" "${qihang_folder}/update.sh" || {
        echo -e "${red}获取 update.sh 失败${plain}"
        exit 1
    }
    chmod +x "${qihang_folder}/qihang-oms.sh" "${qihang_folder}/update.sh"
    ln -sf "${qihang_folder}/qihang-oms.sh" /usr/bin/qihang-oms
}

# ---------------- 下载并部署 Release 产物 ----------------
deploy_artifacts() {
    local tag="$1" tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf ${tmp}" EXIT

    echo -e "${green}Downloading release artifacts (${tag})...${plain}"
    local base_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}"
    gh_curl "${base_url}/qihang-oms-backend.tar.gz" "${tmp}/backend.tar.gz" || {
        echo -e "${red}下载后端产物失败，请确认仓库已发布 Release${plain}"; exit 1
    }
    verify_release_checksum "${base_url}/qihang-oms-backend.tar.gz" "${tmp}/backend.tar.gz"
    gh_curl "${base_url}/qihang-oms-frontend.tar.gz" "${tmp}/frontend.tar.gz" || {
        echo -e "${red}下载前端产物失败，请确认仓库已发布 Release${plain}"; exit 1
    }
    verify_release_checksum "${base_url}/qihang-oms-frontend.tar.gz" "${tmp}/frontend.tar.gz"

    # 后端 jar：保留最近 5 个旧版本用于回滚
    tar -xzf "${tmp}/backend.tar.gz" -C "${tmp}"
    if [ -f "${qihang_folder}/qihang-oms.jar" ]; then
        cp "${qihang_folder}/qihang-oms.jar" "${qihang_folder}/backup/qihang-oms.jar.$(date +%Y%m%d%H%M%S)"
        ls -t "${qihang_folder}/backup" 2> /dev/null | tail -n +6 | xargs -I{} rm -f "${qihang_folder}/backup/{}" || true
    fi
    install -m 644 "${tmp}/qihang-oms.jar" "${qihang_folder}/qihang-oms.jar"
    install -m 644 "${tmp}/qihang-oms.sql" "${qihang_folder}/sql/qihang-oms.sql"

    # 前端：dist.new -> dist 原子替换
    rm -rf "${qihang_folder}/web/dist.new"
    install -d -m 755 -o qihang -g qihang "${qihang_folder}/web/dist.new"
    tar -xzf "${tmp}/frontend.tar.gz" -C "${qihang_folder}/web/dist.new"
    rm -rf "${qihang_folder}/web/dist.old"
    [ -d "${qihang_folder}/web/dist" ] && mv "${qihang_folder}/web/dist" "${qihang_folder}/web/dist.old"
    mv "${qihang_folder}/web/dist.new" "${qihang_folder}/web/dist"
    chown -R qihang:qihang "${qihang_folder}"
}

# ---------------- 首次导入数据库 ----------------
init_sql() {
    local table_cnt
    table_cnt=$(mysql --protocol=socket -uroot -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='qihang-oms';" 2> /dev/null || echo 0)
    if [ "${table_cnt}" = "0" ]; then
        echo -e "${green}Empty database, importing schema...${plain}"
        mysql --protocol=socket -uroot "qihang-oms" < "${qihang_folder}/sql/qihang-oms.sql"
    fi
}

# ---------------- Nginx 站点 ----------------
setup_nginx() {
    echo -e "${green}Configuring Nginx (${DOMAIN})...${plain}"
    local tmp_conf
    tmp_conf=$(mktemp)
    fetch_support_file "nginx-qihang-oms.conf" "${tmp_conf}" || {
        echo -e "${red}获取 nginx-qihang-oms.conf 失败${plain}"; exit 1
    }
    sed "s/__DOMAIN__/${DOMAIN}/g; s/__PORT__/${APP_PORT}/g; s/__WEB_PORT__/${WEB_PORT}/g; s#__ROOT__#${qihang_folder}#g" \
        "${tmp_conf}" > /etc/nginx/sites-available/qihang-oms
    rm -f "${tmp_conf}"
    ln -sf /etc/nginx/sites-available/qihang-oms /etc/nginx/sites-enabled/qihang-oms
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
}

# ---------------- 甲骨文系统防火墙放行对外端口（默认 WEB_PORT=80，可设 30545 等） ----------------
setup_firewall() {
    if [ -f /etc/iptables/rules.v4 ]; then
        if ! grep -q "dport ${WEB_PORT}" /etc/iptables/rules.v4; then
            iptables -I INPUT 5 -p tcp --dport "${WEB_PORT}" -j ACCEPT
            if command -v netfilter-persistent > /dev/null 2>&1; then
                netfilter-persistent save
            else
                iptables-save > /etc/iptables/rules.v4
            fi
        fi
        # 80 模式额外放行 443，为 certbot HTTPS 预留
        if [ "${WEB_PORT}" = "80" ] && ! grep -q 'dport 443' /etc/iptables/rules.v4; then
            iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
            if command -v netfilter-persistent > /dev/null 2>&1; then
                netfilter-persistent save
            else
                iptables-save > /etc/iptables/rules.v4
            fi
        fi
    else
        iptables -I INPUT -p tcp --dport "${WEB_PORT}" -j ACCEPT 2> /dev/null || true
        [ "${WEB_PORT}" = "80" ] && iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2> /dev/null || true
        echo -e "${yellow}/etc/iptables/rules.v4 不存在，规则仅运行时生效，建议安装 iptables-persistent 持久化${plain}"
    fi
    echo -e "${yellow}注意：还需在甲骨文云控制台『虚拟云网络 -> 安全列表』放行入站 TCP ${WEB_PORT}${plain}"
}

# ---------------- 健康检查 ----------------
wait_healthy() {
    echo -e "${green}Waiting for backend...${plain}"
    local i
    for i in $(seq 1 30); do
        if curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/captchaImage"; then
            echo -e "${green}Backend is ready.${plain}"
            return 0
        fi
        sleep 2
    done
    echo -e "${red}Backend did not respond in 60s. Check: journalctl -u qihang-oms -n 100${plain}"
    return 1
}

# ---------------- 交互信息收集 ----------------
is_repo_format() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

is_domain_format() {
    [[ "$1" == "_" ]] || [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

show_welcome() {
    echo -e "${blue}======================================================${plain}"
    echo -e "${blue}        启航 OMS 一键安装向导（Ubuntu 24.04）${plain}"
    echo -e "${blue}======================================================${plain}"
    echo "本向导将自动完成以下内容（约 3-8 分钟）："
    echo "  1. 安装基础软件：OpenJDK 17 / MySQL 8 / Redis / Nginx"
    echo "  2. 小内存服务器自动创建 2G swap（1GB 免费机必须）"
    echo "  3. 初始化 MySQL 数据库与 Redis，自动生成随机强密码"
    echo "  4. 从 GitHub Release 下载最新产物并做 sha256 完整性校验"
    echo "  5. 安装 systemd 服务（开机自启 / 崩溃自恢复 / 内存限额）"
    echo "  6. 配置 Nginx 站点并放行系统防火墙 80/443"
    echo ""
    echo "您只需准备两项信息："
    echo "  * GitHub 仓库：格式 用户名/仓库名，且仓库已发布 Release（含产物）"
    echo "  * 访问域名  ：已解析到本服务器公网 IP；暂无域名可输入 _ （用 IP 访问）"
    echo ""
    echo -e "数据库 / Redis 密码自动生成，安装后见 ${green}${qihang_conf}/application.yml${plain}"
    echo -e "私有仓库请提前放置只读 PAT：${green}echo ghp_xxx > /root/.qihang_deploy_token${plain}"
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        echo ""
        echo -e "${yellow}当前为非交互模式：以下选项全部取自环境变量（参考 deploy/env.example）${plain}"
    fi
    echo ""
}

ask_inputs() {
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        # 非交互：环境变量直读，校验失败立即退出（便于 cloud-init / CI 快速失败）
        [[ -n "${GITHUB_REPO}" ]] || { echo -e "${red}非交互模式缺少环境变量 GITHUB_REPO（格式: 用户名/仓库名）${plain}"; exit 1; }
        is_repo_format "${GITHUB_REPO}" || { echo -e "${red}GITHUB_REPO 格式不正确: ${GITHUB_REPO}（应形如 yourname/qihang-oms）${plain}"; exit 1; }
        DOMAIN="${DOMAIN:-_}"
        is_domain_format "${DOMAIN}" || { echo -e "${red}DOMAIN 格式不正确: ${DOMAIN}（应为域名，或输入 _ 用 IP 访问）${plain}"; exit 1; }
        is_number "${APP_PORT}" || { echo -e "${red}APP_PORT 必须为数字: ${APP_PORT}${plain}"; exit 1; }
        is_number "${WEB_PORT}" || { echo -e "${red}WEB_PORT 必须为数字: ${WEB_PORT}${plain}"; exit 1; }
        return 0
    fi

    # ---- [1/4] GitHub 仓库 ----
    while true; do
        echo -e "${green}[1/4] GitHub 仓库${plain} —— 将从该仓库的 Release 下载安装产物"
        read -rp "      请输入（例: yourname/qihang-oms）: " GITHUB_REPO
        if is_repo_format "${GITHUB_REPO}"; then break; fi
        echo -e "${red}      格式不正确，应形如 yourname/qihang-oms，请重新输入${plain}"
    done

    # ---- [2/4] 访问域名 ----
    while true; do
        echo -e "${green}[2/4] 访问域名${plain} —— 用于 Nginx 站点 server_name"
        read -rp "      请输入（例: oms.example.com；无域名直接回车，用 _ 表示 IP 访问）: " DOMAIN
        DOMAIN="${DOMAIN:-_}"
        if is_domain_format "${DOMAIN}"; then break; fi
        echo -e "${red}      域名格式不正确（如 oms.example.com；无域名请直接回车），请重新输入${plain}"
    done

    # ---- [3/4] 后端端口 ----
    while true; do
        echo -e "${green}[3/4] 后端端口${plain} —— Spring Boot 监听端口，仅本机 Nginx 访问，一般保持默认"
        read -rp "      请输入（回车默认 8086）: " APP_PORT
        APP_PORT="${APP_PORT:-8086}"
        if is_number "${APP_PORT}" && [[ "${APP_PORT}" -ge 1024 && "${APP_PORT}" -le 65535 ]]; then break; fi
        echo -e "${red}      请输入 1024-65535 之间的数字，请重新输入${plain}"
    done

    # ---- [4/4] 对外访问端口 ----
    while true; do
        echo -e "${green}[4/4] 对外访问端口${plain} —— Nginx 监听端口，需与甲骨文安全列表放行端口一致"
        read -rp "      请输入（回车默认 30545）: " WEB_PORT
        WEB_PORT="${WEB_PORT:-30545}"
        if is_number "${WEB_PORT}" && [[ "${WEB_PORT}" -ge 1 && "${WEB_PORT}" -le 65535 ]]; then break; fi
        echo -e "${red}      请输入 1-65535 之间的数字，请重新输入${plain}"
    done
    echo ""
}

# ---------------- 主流程 ----------------
show_welcome
ask_inputs

if is_port_in_use "${APP_PORT}"; then
    echo -e "${red}端口 ${APP_PORT} 已被占用，请更换后重试${plain}"
    exit 1
fi

if [ "${WEB_PORT}" = "80" ]; then
    SITE_URL="http://${DOMAIN}"
else
    SITE_URL="http://${DOMAIN}:${WEB_PORT}"
fi
echo -e "安装确认 -> 仓库: ${green}${GITHUB_REPO}${plain}  域名: ${green}${DOMAIN}${plain}  对外端口: ${green}${WEB_PORT}${plain}  后端端口: ${green}${APP_PORT}${plain}"
if [[ "$NONINTERACTIVE" != "1" ]]; then
    read -rp "确认无误并开始安装? [y/n，回车为 y]: " confirm
    confirm="${confirm:-y}"
    [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "已取消安装"; exit 0; }
fi
echo ""

install_base
ensure_swap
init_mysql
init_redis
write_config

TAG=$(resolve_latest_tag)
[[ -n "$TAG" ]] || { echo -e "${red}无法获取最新版本（GitHub 不可达或仓库无 Release）${plain}"; exit 1; }
echo -e "Latest release: ${TAG}"

systemctl stop qihang-oms 2> /dev/null || true
deploy_artifacts "${TAG}"
install_service
install_manage_script
init_sql
setup_nginx
setup_firewall
write_install_result "${TAG}"

systemctl restart qihang-oms
wait_healthy || exit 1

echo ""
echo -e "${green}======================================================================${plain}"
echo -e "${green} 安装完成！${plain}"
echo -e " 访问地址   : ${SITE_URL}"
echo -e " 默认账号   : admin / Andy@2025（登录后请立即修改密码）"
echo -e " MySQL 密码 : 已写入 ${qihang_conf}/application.yml 与 install-result.env"
echo -e " Redis 密码 : 已写入 ${qihang_conf}/application.yml"
echo -e " 安装版本   : ${TAG}"
echo -e " 管理命令   : qihang-oms（start/stop/restart/status/log/update/uninstall/settings）"
echo -e " 后续更新   : qihang-oms update"
if [ "${WEB_PORT}" = "80" ]; then
    echo -e " HTTPS      : 参考《启航OMS甲骨文云服务器部署教程.md》第 5 步 certbot 命令"
else
    echo -e " HTTPS      : 对外端口非 80，HTTP-01 验证不可用，需 DNS 验证（详见教程第 5 步说明）"
fi
echo -e "${green}======================================================================${plain}"
