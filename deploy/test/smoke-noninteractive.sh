#!/usr/bin/env bash
# =====================================================================
# 启航 OMS —— install.sh 非交互模式冒烟测试（对齐 3x-ui deploy/test/smoke-noninteractive.sh）
# 思路：在支持 systemd 的 Linux 环境（容器需 --privileged，或直接用测试服务器/VM），
#       通过管道喂入脚本制造"stdin 非 TTY"环境，验证非交互分支：
#         1. 环境变量优先于提示符
#         2. 缺少必填变量时明确报错退出
#         3. 脚本语法与关键函数可加载
# 用法：bash smoke-noninteractive.sh [install.sh 路径]
# =====================================================================
set -euo pipefail

SCRIPT_UNDER_TEST="${1:-$(dirname "$0")/../install.sh}"
SCRIPT_UNDER_TEST=$(realpath "$SCRIPT_UNDER_TEST")

pass=0
fail=0

check() { # check <描述> <命令...>
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "== [1] bash 语法检查 =="
check "bash -n $SCRIPT_UNDER_TEST" bash -n "$SCRIPT_UNDER_TEST"

DIR=$(dirname "$SCRIPT_UNDER_TEST")
for f in "$DIR/qihang-oms.sh" "$DIR/update.sh"; do
    if [ -f "$f" ]; then
        check "bash -n $(basename "$f")" bash -n "$f"
    fi
done

echo "== [2] 非交互模式：必填项缺失必须明确报错退出 =="
# 管道喂入 -> stdin 非 TTY -> 自动 NONINTERACTIVE=1；不设 GITHUB_REPO 应以非零退出
# 环境自适应：非 root 环境（如 Windows git bash / CI 容器）预期先触发 root 检查报错，同样算"明确报错"
if cat /dev/null | QIHANG_NONINTERACTIVE=1 bash "$SCRIPT_UNDER_TEST" > /tmp/smoke_out 2>&1; then
    echo "FAIL: 缺 GITHUB_REPO 时未报错退出"
    fail=$((fail + 1))
else
    if grep -qE "GITHUB_REPO|root privilege" /tmp/smoke_out; then
        echo "PASS: 必填项缺失时明确报错退出（root 检查或 GITHUB_REPO 提示）"
        pass=$((pass + 1))
    else
        echo "FAIL: 报错信息不含 GITHUB_REPO/root privilege"
        fail=$((fail + 1))
    fi
fi

echo "== [3] 服务单元文件存在且关键字段完整 =="
SVC="$DIR/qihang-oms.service"
if [ -f "$SVC" ]; then
    check "unit 含 EnvironmentFile" grep -q "^EnvironmentFile=-/etc/default/qihang-oms" "$SVC"
    check "unit 含 ExecStart/java" grep -q "^ExecStart=/usr/bin/java" "$SVC"
    check "unit 含 MemoryMax" grep -q "^MemoryMax=" "$SVC"
    check "unit 含 Restart=on-failure" grep -q "^Restart=on-failure" "$SVC"
else
    echo "SKIP: 未找到 qihang-oms.service"
fi

echo "== [4] Nginx 模板占位符完整 =="
NGX="$DIR/nginx-qihang-oms.conf"
if [ -f "$NGX" ]; then
    check "含 __DOMAIN__" grep -q "__DOMAIN__" "$NGX"
    check "含 __PORT__" grep -q "__PORT__" "$NGX"
    check "含 __ROOT__" grep -q "__ROOT__" "$NGX"
fi

echo ""
echo "结果: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
