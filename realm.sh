#!/bin/bash

# ========================================
# 全局配置
# ========================================
CURRENT_VERSION="1.2.0"
UPDATE_URL="https://raw.githubusercontent.com/jiehu0/EZrealm/main/realm.sh"
VERSION_CHECK_URL="https://raw.githubusercontent.com/jiehu0/EZrealm/main/version.txt"
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm_manager.log"

# ========================================
# 颜色定义
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ========================================
# 初始化检查
# ========================================
init_check() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 必须使用root权限运行本脚本${NC}"
        exit 1
    fi

    # curl 用于更新，lsof 用于确认规则端口确实由 Realm 进程持有。
    local dependency missing_dependencies=()
    for dependency in curl lsof; do
        command -v "$dependency" >/dev/null 2>&1 || missing_dependencies+=("$dependency")
    done
    if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "${missing_dependencies[@]}" || exit 1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_dependencies[@]}" || exit 1
        else
            echo "请先安装依赖：${missing_dependencies[*]}"
            exit 1
        fi
    fi

    # 创建必要目录
    mkdir -p "$REALM_DIR"
    if [[ ! -w $(dirname "$LOG_FILE") ]]; then
        echo -e "${RED}✖ 日志目录不可写，请检查权限${NC}"
        exit 1
    fi
    touch "$LOG_FILE" || {
        echo -e "${RED}✖ 无法创建日志文件${NC}"
        exit 1
    }

    log "脚本启动 v$CURRENT_VERSION"
}

# ========================================
# 日志系统
# ========================================
log() {
    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$log_msg" >> "$LOG_FILE"
}

# ========================================
# 版本比较函数
# ========================================
version_compare() {
    if [[ "$1" == "$2" ]]; then
        return 0  # 版本相同
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1  # 当前版本更高
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2  # 远程版本更高
        fi
    done
    return 0
}

# ========================================
# 自动更新模块
# ========================================
check_update() {
    echo -e "\n${BLUE}▶ 正在检查更新...${NC}"
    
    # 获取远程版本（更严格的过滤）
    remote_version=$(curl -sL $VERSION_CHECK_URL 2>> "$LOG_FILE" | head -n1 | sed 's/[^0-9.]//g')
    if [[ -z "$remote_version" ]]; then
        log "版本检查失败：无法获取远程版本"
        echo -e "${RED}✖ 无法获取远程版本信息，请检查网络连接${NC}"
        return 1
    fi
    
    # 验证版本号格式
    if ! [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检查失败：无效的远程版本号 '$remote_version'"
        echo -e "${RED}✖ 远程版本号格式错误${NC}"
        return 1
    fi

    # 版本比较
    version_compare "$CURRENT_VERSION" "$remote_version"
    case $? in
        0)
            echo -e "${GREEN}✓ 当前已是最新版本 v${CURRENT_VERSION}${NC}"
            return 1
            ;;
        1)
            echo -e "${YELLOW}⚠ 本地版本 v${CURRENT_VERSION} 比远程版本 v${remote_version} 更高${NC}"
            return 1
            ;;
        2)
            echo -e "${YELLOW}▶ 发现新版本 v${remote_version}${NC}"
            return 0
            ;;
    esac
}

perform_update() {
    echo -e "${BLUE}▶ 开始更新...${NC}"
    log "尝试从 $UPDATE_URL 下载更新"
    
    # 下载临时文件
    if ! curl -sL $UPDATE_URL -o "$0.tmp"; then
        log "更新失败：下载脚本失败"
        echo -e "${RED}✖ 下载更新失败，请检查网络${NC}"
        return 1
    fi
    
    # 验证下载内容
    if ! grep -q "CURRENT_VERSION" "$0.tmp"; then
        log "更新失败：下载文件无效"
        echo -e "${RED}✖ 下载文件校验失败${NC}"
        rm -f "$0.tmp"
        return 1
    fi
    
    # 替换脚本
    chmod +x "$0.tmp"
    mv -f "$0.tmp" "$0"
    log "更新完成，重启脚本"
    
    echo -e "${GREEN}✓ 更新成功，重新启动脚本...${NC}"
    # 传递参数跳过更新检查
    exec "$0" "--no-update" "$@"
}

# ========================================
# 核心功能模块
# ========================================
deploy_realm() {
    log "开始安装Realm"
    echo -e "${BLUE}▶ 正在安装Realm...${NC}"
    
    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || exit 1

    # 获取最新版本号
    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -sL https://github.com/zhboner/realm/releases | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')
    
    # 版本号验证
    if [[ -z "$LATEST_VERSION" || ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检测失败，使用备用版本2.7.0"
        LATEST_VERSION="2.7.0"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${LATEST_VERSION}${NC}"
    fi

    # 下载最新版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"
    echo -e "${BLUE}▶ 正在下载 Realm v${LATEST_VERSION}...${NC}"
    if ! wget --show-progress -qO realm.tar.gz "$DOWNLOAD_URL"; then
        log "安装失败：下载错误"
        echo -e "${RED}✖ 文件下载失败，请检查：${NC}"
        echo -e "1. 网络连接状态"
        echo -e "2. GitHub访问权限"
        echo -e "3. 手动验证下载地址: $DOWNLOAD_URL"
        return 1
    fi

    # 解压安装
    tar -xzf realm.tar.gz
    chmod +x realm
    rm realm.tar.gz

    # 初始化配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "[network]\nno_tcp = false\nuse_udp = true" > "$CONFIG_FILE"
    fi

    # 创建服务文件
    echo -e "${BLUE}▶ 创建系统服务...${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$REALM_DIR/realm -c $CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "安装成功"
    echo -e "${GREEN}✔ 安装完成！${NC}"
}

# 按 TOML 表边界读取规则，不依赖字段顺序或固定行号。
load_rules() {
    RULE_STARTS=() RULE_ENDS=() RULE_LISTENS=() RULE_REMOTES=() RULE_REMARKS=()
    [[ -f "$CONFIG_FILE" ]] || return 0
    local start end listen remote remark
    while IFS= read -r start && IFS= read -r end &&
          IFS= read -r listen && IFS= read -r remote && IFS= read -r remark; do
        RULE_STARTS+=("$start") RULE_ENDS+=("$end")
        RULE_LISTENS+=("$listen") RULE_REMOTES+=("$remote") RULE_REMARKS+=("$remark")
    done < <(awk '
        function scalar(line, value) {
            sub(/^[^=]*=[ \t]*/, "", line)
            if (match(line, /^"[^"\\]*"/)) value = substr(line, 2, RLENGTH - 2)
            else if (match(line, /^\047[^\047]*\047/)) value = substr(line, 2, RLENGTH - 2)
            else return "!无法识别的地址格式"
            line = substr(line, RLENGTH + 1)
            if (line !~ /^[ \t]*(#.*)?$/) return "!无法识别的地址格式"
            return value
        }
        function emit(last) {
            if (!start) return
            if (lc != 1) listen = "!listen 字段缺失或重复"
            if (rc != 1) remote = "!remote 字段缺失或重复"
            printf "%d\n%d\n%s\n%s\n%s\n", start, last, listen, remote, remark
        }
        /^[ \t]*\[/ {
            if (start && $0 ~ /^[ \t]*\[\[?endpoints\./) { nested = 1; next }
            emit(NR - 1)
            start = 0
            if ($0 ~ /^[ \t]*\[\[endpoints\]\][ \t]*(#.*)?$/) {
                start = NR; listen = remote = remark = ""; lc = rc = nested = 0
            }
        }
        start && !nested && /^[ \t]*listen[ \t]*=/ { listen = scalar($0); lc++ }
        start && !nested && /^[ \t]*remote[ \t]*=/ { remote = scalar($0); rc++ }
        start && !nested && /^[ \t]*#[ \t]*备注:/ {
            remark = $0
            sub(/^[ \t]*#[ \t]*备注:[ \t]?/, "", remark)
        }
        END { emit(NR) }
    ' "$CONFIG_FILE")
}

show_rules() {
    load_rules
    echo "当前 Realm 转发规则"
    if [[ ${#RULE_STARTS[@]} -eq 0 ]]; then
        echo "没有发现任何转发规则。"
        return
    fi
    printf '%-5s | %-28s | %-36s | %s\n' "序号" "本地地址:端口" "目标地址:端口" "备注"
    local i
    for ((i=0; i<${#RULE_STARTS[@]}; i++)); do
        printf '%-5s | %-28s | %-36s | %s\n' "$((i+1))" "${RULE_LISTENS[i]}" "${RULE_REMOTES[i]}" "${RULE_REMARKS[i]}"
    done
}

select_rule() {
    show_rules
    [[ ${#RULE_STARTS[@]} -gt 0 ]] || return 1
    local choice
    read -rp "请输入要${1}的规则序号（回车或 q 返回）: " choice || return 1
    [[ -n "$choice" && "$choice" != q ]] || return 1
    if [[ ! "$choice" =~ ^[0-9]+$ || ${#choice} -gt 6 ]] ||
       ((10#$choice < 1 || 10#$choice > ${#RULE_STARTS[@]})); then
        echo "无效规则序号。"
        return 1
    fi
    RULE_INDEX=$((10#$choice - 1))
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ && ${#1} -le 5 ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_ipv4() {
    local ip="$1" part
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local IFS=.
    local parts=($ip)
    for part in "${parts[@]}"; do
        [[ ${#part} -le 3 && ( "$part" == 0 || "$part" != 0* ) ]] && ((10#$part <= 255)) || return 1
    done
}

valid_ipv6() {
    local ip="$1" tail
    if [[ "$ip" == *.* ]]; then
        tail=${ip##*:}
        valid_ipv4 "$tail" || return 1
        ip="${ip%:*}:0:0"
    fi
    [[ "$ip" == *:* && "$ip" != *:::* && "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "$ip" != :* || "$ip" == ::* ]] || return 1
    [[ "$ip" != *: || "$ip" == *:: ]] || return 1
    printf '%s\n' "$ip" | awk '
        {
            compressed = index($0, "::") > 0
            rest = $0; sub(/::/, "", rest)
            if (index(rest, "::")) exit 1
            if (!compressed && ($0 ~ /^:/ || $0 ~ /:$/)) exit 1
            n = split($0, groups, ":"); count = 0
            for (i = 1; i <= n; i++) {
                if (groups[i] == "") continue
                if (length(groups[i]) > 4) exit 1
                count++
            }
            if (compressed) exit !(count < 8)
            exit !(count == 8)
        }
    '
}

valid_host() {
    local host="$1" label
    [[ "$host" == *:* ]] && { valid_ipv6 "$host"; return; }
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        valid_ipv4 "$host"
        return
    fi
    host=${host%.}
    [[ -n "$host" && ${#host} -le 253 && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    local IFS=.
    local labels=($host)
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

split_address() {
    if [[ "$1" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        ADDRESS_HOST=${BASH_REMATCH[1]} ADDRESS_PORT=${BASH_REMATCH[2]}
        valid_ipv6 "$ADDRESS_HOST" || return 1
    elif [[ "$1" =~ ^([^:]+):([0-9]+)$ ]]; then
        ADDRESS_HOST=${BASH_REMATCH[1]} ADDRESS_PORT=${BASH_REMATCH[2]}
        valid_host "$ADDRESS_HOST" || return 1
    else
        return 1
    fi
    valid_port "$ADDRESS_PORT"
}

make_address() {
    if [[ "$1" == *:* ]]; then printf '[%s]:%s' "$1" "$2"
    else printf '%s:%s' "$1" "$2"; fi
}

validate_rule() {
    local listen="$1" remote="$2" skip="$3" host port i other_host
    split_address "$listen" || { echo "监听地址或端口无效。"; return 1; }
    host=$(printf '%s' "$ADDRESS_HOST" | tr 'A-F' 'a-f')
    port=$((10#$ADDRESS_PORT))
    if [[ "$host" != *:* ]]; then
        valid_ipv4 "$host" || { echo "监听地址必须是 IPv4 或 IPv6 地址。"; return 1; }
    fi
    split_address "$remote" || { echo "目标地址或端口无效。"; return 1; }
    for ((i=0; i<${#RULE_STARTS[@]}; i++)); do
        [[ "$i" == "$skip" ]] && continue
        split_address "${RULE_LISTENS[i]}" || continue
        [[ "$port" -eq $((10#$ADDRESS_PORT)) ]] || continue
        other_host=$(printf '%s' "$ADDRESS_HOST" | tr 'A-F' 'a-f')
        if [[ "$host" == "$other_host" || "$host" == :: || "$other_host" == :: ]] ||
           { [[ "$host" != *:* && "$other_host" != *:* ]] && [[ "$host" == 0.0.0.0 || "$other_host" == 0.0.0.0 ]]; }; then
            echo "监听地址与第 $((i+1)) 条规则冲突。"
            return 1
        fi
    done
}

new_rule_file() {
    local candidate
    candidate=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    if ! cp -p "$CONFIG_FILE" "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    printf '%s\n' "$candidate"
}

# 输出指定规则的有效 no_tcp / use_udp，端点配置覆盖全局配置。
rule_protocols() {
    awk -v target="$1" '
        BEGIN { tcp = udp = 0 }
        /^[ \t]*\[/ {
            section = $0; sub(/[ \t]*#.*/, "", section); gsub(/[ \t]/, "", section)
            if (section == "[[endpoints]]") index_++
        }
        /^[ \t]*(no_tcp|use_udp)[ \t]*=[ \t]*(true|false)[ \t]*(#.*)?$/ {
            key = $0; sub(/^[ \t]*/, "", key); sub(/[ \t]*=.*/, "", key)
            value = ($0 ~ /=[ \t]*true/)
            if (section == "[network]") {
                if (key == "no_tcp") tcp = value; else udp = value
            }
            if (section == "[endpoints.network]" && index_ == target) {
                if (key == "no_tcp") { endpoint_tcp = value; has_tcp = 1 }
                else { endpoint_udp = value; has_udp = 1 }
            }
        }
        END { print (has_tcp ? endpoint_tcp : tcp), (has_udp ? endpoint_udp : udp) }
    ' "$CONFIG_FILE"
}

restart_realm() {
    load_rules
    # 删除最后一条规则后，空配置没有转发任务，停止服务即可。
    if [[ ${#RULE_STARTS[@]} -eq 0 ]]; then
        systemctl stop realm.service
        return
    fi
    local pid i address tcp_selector udp_selector no_tcp use_udp
    systemctl restart realm.service || return 1
    # Type=simple 的启动命令可能先于配置解析、端口绑定完成。
    sleep 1
    systemctl is-active --quiet realm.service || return 1
    pid=$(systemctl show --property=MainPID --value realm.service) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i=0; i<${#RULE_STARTS[@]}; i++)); do
        address=${RULE_LISTENS[i]}
        split_address "$address" || return 1
        if [[ "$ADDRESS_HOST" == *:* && -z "${ADDRESS_HOST//[:0]/}" ]]; then
            tcp_selector="TCP:$ADDRESS_PORT" udp_selector="UDP:$ADDRESS_PORT"
        else
            tcp_selector="TCP@$address" udp_selector="UDP@$address"
        fi
        read -r no_tcp use_udp < <(rule_protocols "$((i+1))")
        if [[ "$no_tcp" == 0 ]] && ! lsof -nP -a -p "$pid" -i "$tcp_selector" -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo "第 $((i+1)) 条规则的 TCP 端口未由 Realm 监听。"
            return 1
        fi
        if [[ "$use_udp" == 1 ]] && ! lsof -nP -a -p "$pid" -i "$udp_selector" -t >/dev/null 2>&1; then
            echo "第 $((i+1)) 条规则的 UDP 端口未由 Realm 监听。"
            return 1
        fi
    done
}

# 候选配置必须位于原文件所在目录，以便用 rename 原子替换。
save_rules() {
    local candidate="$1" backup restore
    # 交互期间被其他进程修改时，不覆盖外部修改。
    if ! cmp -s "$CONFIG_FILE" "$RULE_SNAPSHOT"; then
        echo "配置在操作期间已变化，请重新选择规则。"
        rm -f "$candidate"
        return 1
    fi
    backup=$(mktemp "${CONFIG_FILE}.bak.XXXXXX") || { rm -f "$candidate"; return 1; }
    if ! cp -p "$CONFIG_FILE" "$backup" || ! mv -f "$candidate" "$CONFIG_FILE"; then
        echo "保存配置失败。备份：$backup"
        rm -f "$candidate"
        return 1
    fi
    if restart_realm; then
        log "规则配置已保存，备份: $backup"
        echo "保存成功，服务状态已更新。备份：$backup"
        return 0
    fi
    echo "服务重启失败，正在恢复原配置。"
    restore=$(mktemp "${CONFIG_FILE}.restore.XXXXXX") || return 1
    if cp -p "$backup" "$restore" && mv -f "$restore" "$CONFIG_FILE"; then
        if restart_realm; then
            echo "已恢复原配置和服务。"
        else
            echo "原配置已恢复，但服务恢复失败，请检查服务日志。备份：$backup"
        fi
    else
        rm -f "$restore"
        echo "恢复配置失败，请使用备份：$backup"
    fi
    log "规则配置生效失败，备份: $backup"
    return 1
}

edit_rule() {
    local RULE_SNAPSHOT candidate result index listen remote remark
    local listen_host listen_port remote_host remote_port answer value
    [[ -f "$CONFIG_FILE" ]] || { echo "没有发现任何转发规则。"; return; }
    RULE_SNAPSHOT=$(mktemp "${CONFIG_FILE}.snapshot.XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$RULE_SNAPSHOT" || { rm -f "$RULE_SNAPSHOT"; return 1; }
    edit_rule_inputs
    result=$?
    rm -f "$RULE_SNAPSHOT"
    return "$result"
}

edit_rule_inputs() {
    select_rule "编辑" || return 0
    index=$RULE_INDEX
    listen=${RULE_LISTENS[index]} remote=${RULE_REMOTES[index]} remark=${RULE_REMARKS[index]}
    split_address "$listen" || { echo "无法识别该规则的监听字段，未修改配置。"; return 1; }
    listen_host=$ADDRESS_HOST listen_port=$ADDRESS_PORT
    split_address "$remote" || { echo "无法识别该规则的目标字段，未修改配置。"; return 1; }
    remote_host=$ADDRESS_HOST remote_port=$ADDRESS_PORT
    echo "回车保留原值，q 取消；备注输入 - 清空。IPv6 地址无需方括号。"
    for value in listen_host listen_port remote_host remote_port remark; do
        case "$value" in
            listen_host) answer="监听地址" ;;
            listen_port) answer="监听端口" ;;
            remote_host) answer="目标地址" ;;
            remote_port) answer="目标端口" ;;
            remark) answer="备注" ;;
        esac
        read -rp "$answer [${!value}]: " answer || return 0
        [[ "$answer" != q ]] || return 0
        [[ -z "$answer" ]] || printf -v "$value" '%s' "$answer"
    done
    [[ "$remark" != - ]] || remark=""
    listen_host=${listen_host#[}; listen_host=${listen_host%]}
    remote_host=${remote_host#[}; remote_host=${remote_host%]}
    listen=$(make_address "$listen_host" "$listen_port")
    remote=$(make_address "$remote_host" "$remote_port")
    validate_rule "$listen" "$remote" "$index" || return 1
    if [[ "$listen" == "${RULE_LISTENS[index]}" && "$remote" == "${RULE_REMOTES[index]}" && "$remark" == "${RULE_REMARKS[index]}" ]]; then
        echo "规则没有变化。"
        return 0
    fi
    printf '监听：%s → %s\n目标：%s → %s\n备注：%s → %s\n' "${RULE_LISTENS[index]}" "$listen" "${RULE_REMOTES[index]}" "$remote" "${RULE_REMARKS[index]}" "$remark"
    read -rp "确认保存并重启服务？(y/N): " answer || return 0
    [[ "$answer" == y || "$answer" == Y ]] || return 0
    candidate=$(new_rule_file) || return 1
    # 环境变量传值，避免 awk -v 将备注里的反斜杠解释成转义字符。
    if ! RULE_LISTEN="$listen" RULE_REMOTE="$remote" RULE_REMARK="$remark" awk \
        -v start="${RULE_STARTS[index]}" -v end="${RULE_ENDS[index]}" '
        function address_line(line, value, prefix, rest) {
            match(line, /=[ \t]*/)
            prefix = substr(line, 1, RSTART + RLENGTH - 1)
            rest = substr(line, RSTART + RLENGTH)
            match(rest, /^("[^"\\]*"|\047[^\047]*\047)/)
            return prefix "\"" value "\"" substr(rest, RLENGTH + 1)
        }
        NR == start {
            print
            if (ENVIRON["RULE_REMARK"] != "") print "# 备注: " ENVIRON["RULE_REMARK"]
            next
        }
        NR > start && /^[ \t]*\[/ { nested = 1 }
        NR > start && NR <= end && !nested {
            if ($0 ~ /^[ \t]*#[ \t]*备注:/) next
            if ($0 ~ /^[ \t]*listen[ \t]*=/) { print address_line($0, ENVIRON["RULE_LISTEN"]); next }
            if ($0 ~ /^[ \t]*remote[ \t]*=/) { print address_line($0, ENVIRON["RULE_REMOTE"]); next }
        }
        { print }
    ' "$CONFIG_FILE" > "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    save_rules "$candidate"
}

delete_rule() {
    local RULE_SNAPSHOT candidate result index
    [[ -f "$CONFIG_FILE" ]] || { echo "没有发现任何转发规则。"; return; }
    RULE_SNAPSHOT=$(mktemp "${CONFIG_FILE}.snapshot.XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$RULE_SNAPSHOT" || { rm -f "$RULE_SNAPSHOT"; return 1; }
    if select_rule "删除"; then
        index=$RULE_INDEX
        candidate=$(new_rule_file) || { rm -f "$RULE_SNAPSHOT"; return 1; }
        if awk -v start="${RULE_STARTS[index]}" -v end="${RULE_ENDS[index]}" \
            'NR < start || NR > end' "$CONFIG_FILE" > "$candidate"; then
            save_rules "$candidate"
            result=$?
        else
            rm -f "$candidate"
            result=1
        fi
    else
        result=0
    fi
    rm -f "$RULE_SNAPSHOT"
    return "$result"
}

# 添加转发规则，与编辑共用地址验证和配置保存逻辑。
add_rule() {
    local local_port remote_ip remote_port remark ip_choice listen_addr remote_addr cont
    local RULE_SNAPSHOT candidate result
    [[ -f "$CONFIG_FILE" ]] || { echo "请先安装 Realm。"; return 1; }
    while :; do
        echo "添加新规则（输入 q 退出）"
        read -rp "本地监听端口: " local_port || return 0
        [[ "$local_port" != q ]] || return 0
        read -rp "目标服务器 IP 或域名: " remote_ip || return 0
        [[ "$remote_ip" != q ]] || return 0
        read -rp "目标端口: " remote_port || return 0
        [[ "$remote_port" != q ]] || return 0
        read -rp "规则备注: " remark || return 0
        [[ "$remark" != q ]] || return 0
        valid_port "$local_port" && valid_port "$remote_port" || { echo "端口必须在 1–65535 之间。"; continue; }
        echo "1) 双栈监听 [::]:${local_port}（默认）"
        echo "2) 仅 IPv4 监听 0.0.0.0:$local_port"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3]: " ip_choice || return 0
        case "${ip_choice:-1}" in
            1) listen_addr="[::]:$local_port" ;;
            2) listen_addr="0.0.0.0:$local_port" ;;
            3) read -rp "完整监听地址（如 127.0.0.1:80 或 [::1]:443）: " listen_addr || return 0 ;;
            q) return 0 ;;
            *) echo "无效监听模式。"; continue ;;
        esac
        [[ "$listen_addr" != q ]] || return 0
        remote_ip=${remote_ip#[}; remote_ip=${remote_ip%]}
        remote_addr=$(make_address "$remote_ip" "$remote_port")
        RULE_SNAPSHOT=$(mktemp "${CONFIG_FILE}.snapshot.XXXXXX") || return 1
        cp -p "$CONFIG_FILE" "$RULE_SNAPSHOT" || { rm -f "$RULE_SNAPSHOT"; return 1; }
        load_rules
        if ! validate_rule "$listen_addr" "$remote_addr" -1; then
            rm -f "$RULE_SNAPSHOT"
            continue
        fi
        candidate=$(new_rule_file) || { rm -f "$RULE_SNAPSHOT"; return 1; }
        if printf '\n[[endpoints]]\n# 备注: %s\nlisten = "%s"\nremote = "%s"\n' \
            "$remark" "$listen_addr" "$remote_addr" >> "$candidate"; then
            save_rules "$candidate"
            result=$?
        else
            rm -f "$candidate"
            result=1
        fi
        rm -f "$RULE_SNAPSHOT"
        [[ "$result" -eq 0 ]] || return "$result"
        read -rp "继续添加？(y/n): " cont || return 0
        [[ "$cont" == y ]] || return 0
    done
}

service_control() {
    case $1 in
        start)
            sudo systemctl unmask realm.service
            sudo systemctl daemon-reload
            sudo systemctl restart realm.service
            sudo systemctl enable realm.service
            log "启动服务"
            echo -e "${GREEN}✔ 服务已启动${NC}"
            ;;
        stop)
            sudo systemctl stop realm
            log "停止服务"
            echo -e "${YELLOW}⚠ 服务已停止${NC}"
            ;;
        restart)
            sudo systemctl unmask realm.service
            sudo systemctl daemon-reload
            sudo systemctl restart realm.service
            sudo systemctl enable realm.service
            log "重启服务"
            echo -e "${GREEN}✔ 服务已重启${NC}"
            ;;
        status)
            if systemctl is-active --quiet realm; then
                echo -e "${GREEN}● 服务运行中${NC}"
            else
                echo -e "${RED}● 服务未运行${NC}"
            fi
            ;;
    esac
}

manage_cron() {
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有任务"
    echo "3. 查看当前任务"
    read -rp "请选择: " choice

    case $choice in
        1)
            read -rp "输入每日重启时间 (0-23): " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
                echo "0 $hour * * * root /usr/bin/systemctl restart realm" >>/etc/crontab
                log "添加定时任务：每日 $hour 时重启"
                echo -e "${GREEN}✔ 定时任务已添加！${NC}"
            else
                echo -e "${RED}✖ 无效时间！${NC}"
            fi
            ;;
        2)
            sed -i "/realm/d" /etc/crontab
            log "清除定时任务"
            echo -e "${YELLOW}✔ 定时任务已清除！${NC}"
            ;;
        3)
            echo -e "\n${BLUE}当前定时任务：${NC}"
            cat /etc/crontab | grep --color=auto "realm"
            ;;
        *)
            echo -e "${RED}✖ 无效选择！${NC}"
            ;;
    esac
}

uninstall() {
    log "开始卸载"
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    systemctl stop realm
    systemctl disable realm
    rm -rf "$REALM_DIR"
    rm -f "$SERVICE_FILE"
    rm -rf /root/realm
    rm -rf "$(pwd)"/realm.sh
    sed -i "/realm/d" /etc/crontab
    systemctl daemon-reload
    
    log "卸载完成"
    echo -e "${GREEN}✔ 已完全卸载！${NC}"
}

# ========================================
# 安装状态检测
# ========================================
check_installed() {
    if [[ -f "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        echo -e "${GREEN}已安装${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主界面
# ========================================
main_menu() {
    clear
    init_check

    # 处理跳过更新检查参数
    local skip_update=false
    if [[ "$1" == "--no-update" ]]; then
        skip_update=true
        shift
    fi

    # 首次运行检查更新
    if ! $skip_update; then
        check_update && perform_update "$@"
    fi

    while true; do
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "                ${BLUE}Realm 高级管理脚本 v$CURRENT_VERSION"
        echo -e "        修改by：Ami    修改日期：2025/4/1"
        echo -e "        修改内容:1.基本重做了脚本"
        echo -e "                 2.新增了自动更新脚本"
        echo -e "                 3.realm支持检测最新版本"
        echo -e "    (1)安装前请先更新系统软件包，缺少命令可能无法安装"
        echo -e "    (2)如果启动失败请检查 /root/realm/config.toml下有无多余配置或者卸载后重新配置"
        echo -e "    (3)该脚本只在debian系统下测试，未做其他系统适配，安装命令有别，可能无法启动。如若遇到问题，请自行解决"
        echo -e "    仓库：https://github.com/jiehu0/EZrealm"
        echo -e "    2025/4/1 更新：有人反馈该新版本添加规则过多后无法启动，如果遇到问题，可以尝试回退老版本（大概率是备注问题）"
        echo -e "        删除该脚本 rm realm.sh"
        echo -e "        运行 wget -N https://raw.githubusercontent.com/jiehu0/EZrealm/main/realm-2024.sh && chmod +x realm.sh && ./realm.sh"
        echo -e "        或者 wget -N https://raw.githubusercontent.com/jiehu0/EZrealm/main/realm-2025.sh && chmod +x realm.sh && ./realm.sh${NC}"
        echo -e "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
        echo -e "  "
        echo -e "${YELLOW}服务状态：$(service_control status)${NC}"
        echo -e "${YELLOW}安装状态：$(check_installed)${NC}"
        echo -e "  "
        echo -e "${YELLOW}------------------${NC}"
        echo "1. 安装/更新 Realm"
        echo -e "${YELLOW}------------------${NC}"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo "11. 编辑转发规则"
        echo -e "${YELLOW}------------------${NC}"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo -e "${YELLOW}------------------${NC}"
        echo "8. 定时任务管理"
        echo "9. 查看日志"
        echo -e "${YELLOW}------------------${NC}"
        echo "10. 完全卸载"
        echo -e "${YELLOW}------------------${NC}"
        echo "0. 退出脚本"
        echo -e "${YELLOW}------------------${NC}"

        read -rp "请输入选项: " choice
        case $choice in
            1) deploy_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            11) edit_rule ;;
            5) service_control start ;;
            6) service_control stop ;;
            7) service_control restart ;;
            8) manage_cron ;;
            9) 
                echo -e "\n${BLUE}最近日志：${NC}"
                tail -n 10 "$LOG_FILE" 
                ;;
            10) 
                read -rp "确认完全卸载？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    uninstall
                    read -rp "按回车键继续..."
                    clear
                    exit 0
                fi
                ;;
            0) exit 0 
            ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac
        read -rp "按回车键继续..."
        clear
    done
}

# ========================================
# 脚本入口
# ========================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu "$@"
fi
