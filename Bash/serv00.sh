#!/bin/sh

CURRENT_USER="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null)}"
RELEASE_REPO="MetaCubeX/mihomo"
RELEASE_API_URL="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
RELEASE_ASSET="mihomo-freebsd.gz"
MIHOMO_ASSET_PATTERN='mihomo-freebsd-amd64-compatible-[^"]*\.gz'
WS_PATH="/"

detect_home_dir() {
    local dir=""

    if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
        printf '%s\n' "$HOME"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        dir="$(getent passwd "$CURRENT_USER" 2>/dev/null | awk -F: 'NR==1 { print $6 }')"
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    fi

    if command -v pw >/dev/null 2>&1; then
        dir="$(pw usershow "$CURRENT_USER" 2>/dev/null | awk -F: 'NR==1 { print $9 }')"
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    fi

    dir="$(eval printf '%s' "~$CURRENT_USER" 2>/dev/null)"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
    fi

    return 1
}

HOME_DIR="$(detect_home_dir)" || {
    echo "[错误] 无法识别当前用户主目录: ${CURRENT_USER:-unknown}"
    exit 1
}

WORK_DIR="${WORK_DIR:-$HOME_DIR/blog}"
BIN_NAME="${BIN_NAME:-mihomo}"
BIN_PATH="${BIN_PATH:-$WORK_DIR/$BIN_NAME}"
CONFIG_PATH="${CONFIG_PATH:-$WORK_DIR/config.yaml}"
RESTART_LOG="${RESTART_LOG:-$WORK_DIR/blog.log}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_DIR/$RELEASE_ASSET}"

require_commands() {
    local missing=""
    local cmd
    for cmd in awk kill nohup ps sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    if [ -n "$missing" ]; then
        echo "[错误] 缺少依赖命令:$missing"
        exit 1
    fi
}

require_install_commands() {
    require_commands

    if ! command -v gzip >/dev/null 2>&1; then
        echo "[错误] 缺少依赖命令: gzip"
        exit 1
    fi

    if ! command -v fetch >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo "[错误] 需要 fetch 或 curl 命令"
        exit 1
    fi
}

random_pass() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16
        return 0
    fi
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
        return 0
    fi
    printf '%s\n' "ChangeMe12345678"
}

is_interactive() {
    [ -t 1 ]
}

log_msg() {
    is_interactive && echo "$1"
}

log_restart_event() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$RESTART_LOG"
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local secret="${3:-0}"
    local value=""

    if [ "$secret" = "1" ]; then
        printf '%s' "$prompt" >&2
        if [ -n "$default" ]; then
            printf '（默认值已隐藏）: ' >&2
        else
            printf ': ' >&2
        fi
        stty -echo
        IFS= read -r value
        stty echo
        printf '\n' >&2
    else
        if [ -n "$default" ]; then
            printf '%s（默认：%s）: ' "$prompt" "$default" >&2
        else
            printf '%s: ' "$prompt" >&2
        fi
        IFS= read -r value
    fi

    [ -n "$value" ] || value="$default"
    printf '%s\n' "$value"
}

write_multiline_file() {
    local target="$1"
    local label="$2"
    local line=""
    local next_line=""

    echo "[信息] 请粘贴 ${label} 内容。"
    echo "[信息] 可用单独一行 EOF 结束输入。"
    echo "[信息] 单个证书/密钥也可以在 END 那一行之后再按一次回车结束。"
    : > "$target"

    while IFS= read -r line; do
        [ "$line" = "EOF" ] && break
        printf '%s\n' "$line" >> "$target"

        case "$line" in
            "-----END CERTIFICATE-----"|"-----END PRIVATE KEY-----"|"-----END RSA PRIVATE KEY-----"|"-----END EC PRIVATE KEY-----"|"-----END OPENSSH PRIVATE KEY-----")
                if ! IFS= read -r next_line; then
                    break
                fi
                [ "$next_line" = "EOF" ] && break
                [ -z "$next_line" ] && break
                printf '%s\n' "$next_line" >> "$target"
                ;;
        esac
    done
}

prompt_cert_mode() {
    local mode=""

    while :; do
        mode="$(prompt_input "请选择证书来源：1.自动生成自签证书  2.手动粘贴证书和私钥" "1")"
        case "$mode" in
            1)
                printf '%s\n' "self"
                return 0
                ;;
            2)
                printf '%s\n' "manual"
                return 0
                ;;
            *)
                echo "[警告] 请输入 1 或 2" >&2
                ;;
        esac
    done
}

generate_self_signed_cert() {
    local cert_path="$1"
    local key_path="$2"
    local cert_name="$3"
    local conf_path="$WORK_DIR/.selfsigned-openssl.cnf"
    local status=0

    if ! command -v openssl >/dev/null 2>&1; then
        echo "[错误] 自动生成自签证书需要 openssl，请安装 openssl 后重试，或重新运行脚本选择手动输入证书"
        return 1
    fi

    cat > "$conf_path" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = $cert_name

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $cert_name
EOF

    echo "[信息] 正在生成自签证书..."
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
        -keyout "$key_path" -out "$cert_path" -config "$conf_path" >/dev/null 2>&1
    status=$?
    rm -f "$conf_path"

    if [ "$status" != "0" ]; then
        rm -f "$cert_path" "$key_path"
        echo "[错误] 自签证书生成失败"
        return 1
    fi

    echo "[成功] 自签证书已生成: $cert_path"
    echo "[成功] 私钥已生成: $key_path"
}

prepare_certificate() {
    local cert_mode=""
    local cert_name=""

    cert_mode="$(prompt_cert_mode)"

    case "$cert_mode" in
        self)
            cert_name="$(prompt_input "请输入自签证书域名" "icloud.com.cn")"
            PEM_NAME="${cert_name}.pem"
            KEY_NAME="${cert_name}.key"
            generate_self_signed_cert "$WORK_DIR/$PEM_NAME" "$WORK_DIR/$KEY_NAME" "$cert_name" || return 1
            ;;
        manual)
            cert_name="$(prompt_input "请输入证书域名" "")"
            PEM_NAME="${cert_name}.pem"
            KEY_NAME="${cert_name}.key"
            write_multiline_file "$WORK_DIR/$PEM_NAME" "$PEM_NAME"
            write_multiline_file "$WORK_DIR/$KEY_NAME" "$KEY_NAME"
            ;;
    esac

    chmod 600 "$WORK_DIR/$PEM_NAME" "$WORK_DIR/$KEY_NAME" 2>/dev/null || true
}

yaml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

normalize_ws_path() {
    case "${1:-}" in
        "")
            printf '%s\n' "/"
            ;;
        /*)
            printf '%s\n' "$1"
            ;;
        *)
            printf '/%s\n' "$1"
            ;;
    esac
}

fetch_release_api() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RELEASE_API_URL"
    else
        fetch -qo - "$RELEASE_API_URL"
    fi
}

get_latest_release_info() {
    local pattern=""

    pattern="$MIHOMO_ASSET_PATTERN"
    fetch_release_api | awk -v pattern="$pattern" '
        $0 ~ "\"tag_name\"" && tag == "" {
            tag = $0
            sub(/^.*"tag_name": "/, "", tag)
            sub(/".*$/, "", tag)
        }
        $0 ~ "\"browser_download_url\"" && $0 ~ pattern && url == "" {
            url = $0
            sub(/^.*"browser_download_url": "/, "", url)
            sub(/".*$/, "", url)
        }
        END {
            if (tag != "" && url != "") {
                print tag
                print url
                exit 0
            }
            exit 1
        }
    '
}

validate_release_info() {
    local latest_version="$1"
    local url="$2"

    case "$latest_version" in
        v[0-9]*)
            ;;
        *)
            echo "[错误] 版本解析异常: $latest_version" >&2
            return 1
            ;;
    esac

    case "$url" in
        https://github.com/*/mihomo-freebsd-amd64-compatible-"$latest_version".gz)
            ;;
        *)
            echo "[错误] 下载地址解析异常: $url"
            return 1
            ;;
    esac
}

download_url() {
    local url="$1"

    echo "[信息] 正在下载 mihomo FreeBSD ..."

    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$ARCHIVE_PATH" || return 1
    else
        fetch -o "$ARCHIVE_PATH" "$url" || return 1
    fi
}

download_release() {
    local release_info=""
    local latest_version=""
    local url=""

    release_info="$(get_latest_release_info)" || {
        echo "[错误] 未在 mihomo 最新 release 中找到匹配资产: $MIHOMO_ASSET_PATTERN" >&2
        return 1
    }
    latest_version="$(printf '%s\n' "$release_info" | sed -n '1p')"
    url="$(printf '%s\n' "$release_info" | sed -n '2p')"
    validate_release_info "$latest_version" "$url" || return 1

    download_url "$url"
}

extract_binary() {
    local tmp_path="${BIN_PATH}.new"

    gzip -dc "$ARCHIVE_PATH" > "$tmp_path" || {
        rm -f "$tmp_path"
        return 1
    }
    chmod +x "$tmp_path" || {
        rm -f "$tmp_path"
        return 1
    }
    mv "$tmp_path" "$BIN_PATH" || {
        rm -f "$tmp_path"
        return 1
    }
    rm -f "$ARCHIVE_PATH" || return 1
}

get_installed_version() {
    [ -x "$BIN_PATH" ] || return 1
    "$BIN_PATH" -v 2>/dev/null | awk '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^v[0-9]/) {
                    print $i
                    exit
                }
            }
        }
    '
}

update_if_needed() {
    local release_info=""
    local latest_version=""
    local url=""
    local current_version=""
    local was_running=0

    release_info="$(get_latest_release_info)" || {
        echo "[警告] 检查 mihomo 更新失败，跳过更新"
        return 0
    }
    latest_version="$(printf '%s\n' "$release_info" | sed -n '1p')"
    url="$(printf '%s\n' "$release_info" | sed -n '2p')"
    validate_release_info "$latest_version" "$url" || return 0
    current_version="$(get_installed_version 2>/dev/null)"

    if [ "$current_version" = "$latest_version" ]; then
        echo "[信息] mihomo 已是最新版本: $latest_version"
        return 0
    fi

    if [ -n "$current_version" ]; then
        echo "[信息] 检测到 mihomo 新版本: $current_version -> $latest_version"
    else
        echo "[信息] 检测到 mihomo 新版本: $latest_version"
    fi

    download_url "$url" || {
        echo "[警告] mihomo 更新下载失败，继续使用当前版本"
        return 0
    }

    if is_running; then
        was_running=1
        stop_process || return 1
    fi

    extract_binary || {
        echo "[错误] mihomo 更新失败"
        [ "$was_running" = "1" ] && start_process
        return 1
    }

    echo "[成功] mihomo 已更新到: $latest_version"

    if [ "$was_running" = "1" ]; then
        start_process || return 1
    fi

    return 0
}

generate_config() {
    local cert_path=""
    local key_path=""
    local trojan_password=""
    local hy2_password=""
    local ws_path=""

    cert_path="$(yaml_escape "$WORK_DIR/$PEM_NAME")"
    key_path="$(yaml_escape "$WORK_DIR/$KEY_NAME")"
    trojan_password="$(yaml_escape "$TROJAN_PASSWORD")"
    hy2_password="$(yaml_escape "$HY2_PASSWORD")"
    ws_path="$(yaml_escape "$WS_PATH")"

    cat > "$CONFIG_PATH" <<EOF
tcp-concurrent: true
find-process-mode: off
allow-lan: false
mode: rule
log-level: silent
ipv6: false
profile:
  store-selected: false
  store-fake-ip: false
dns:
  enable: true
  listen: :1053
  ipv6: false
  nameserver:
    - 1.1.1.1
  enhanced-mode: redir-host
listeners:
EOF

    cat >> "$CONFIG_PATH" <<EOF
  - name: trojan-ws-tls-in
    type: trojan
    port: ${TROJAN_PORT}
    listen: 0.0.0.0
    users:
      - username: user
        password: "${trojan_password}"
    ws-path: "${ws_path}"
    certificate: "${cert_path}"
    private-key: "${key_path}"

EOF

    cat >> "$CONFIG_PATH" <<EOF
  - name: hysteria2-in
    type: hysteria2
    port: ${HY2_PORT}
    listen: 0.0.0.0
    users:
      user1: "${hy2_password}"
    masquerade: ""
    alpn:
      - h3
    certificate: "${cert_path}"
    private-key: "${key_path}"

EOF

    cat >> "$CONFIG_PATH" <<EOF
rules:
  - MATCH,DIRECT
EOF
    chmod 600 "$CONFIG_PATH"
}

show_usage() {
    echo "用法: $0 [restart|stop]"
    echo "      $0 trojan PT 端口"
    echo "      $0 trojan PW 密码"
    echo "      $0 hysteria PT 端口"
    echo "      $0 hysteria PW 密码"
}

update_config_item() {
    local service="$1"
    local item="$2"
    local value="$3"
    local listener=""
    local escaped_value=""
    local tmp_path="${CONFIG_PATH}.tmp.$$"

    case "$service" in
        trojan)
            listener="trojan-ws-tls-in"
            ;;
        hysteria)
            listener="hysteria2-in"
            ;;
        *)
            show_usage
            return 1
            ;;
    esac

    case "$item" in
        PT)
            escaped_value="$value"
            ;;
        PW)
            escaped_value="$(yaml_escape "$value")"
            ;;
        *)
            show_usage
            return 1
            ;;
    esac

    awk -v listener="$listener" -v item="$item" -v value="$escaped_value" '
        /^  - name: / {
            in_target = ($0 == "  - name: " listener)
        }
        /^rules:/ {
            in_target = 0
        }
        in_target && item == "PT" && /^    port: / {
            print "    port: " value
            next
        }
        in_target && item == "PW" && listener == "trojan-ws-tls-in" && /^        password: / {
            print "        password: \"" value "\""
            next
        }
        in_target && item == "PW" && listener == "hysteria2-in" && /^      user1: / {
            print "      user1: \"" value "\""
            next
        }
        {
            print
        }
    ' "$CONFIG_PATH" > "$tmp_path" && mv "$tmp_path" "$CONFIG_PATH" || {
        rm -f "$tmp_path"
        return 1
    }
    chmod 600 "$CONFIG_PATH"
}

apply_config_change() {
    if [ "$#" -ne 3 ]; then
        show_usage
        return 1
    fi

    require_commands
    if ! ensure_installed; then
        echo "[错误] 尚未安装，请先运行 $0 完成安装"
        return 1
    fi

    update_config_item "$1" "$2" "$3" || return 1
    echo "[成功] 配置已更新，正在重启..."
    stop_process || return 1
    start_process
}

get_pid() {
    ps axww -o pid= -o command= 2>/dev/null | awk \
        -v bin="$BIN_PATH" \
        -v bin_name="$BIN_NAME" \
        -v config_path="$CONFIG_PATH" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if (index($0, config_path) > 0 &&
                ($0 == bin || index($0, bin " ") == 1 ||
                 $0 == bin_name || index($0, bin_name " ") == 1)) {
                print pid
            }
        }
    '
}

is_running() {
    [ -n "$(get_pid 2>/dev/null)" ]
}

validate_process() {
    [ -x "$BIN_PATH" ] || { echo "[错误] 未找到可执行文件: $BIN_PATH"; return 1; }
    [ -f "$CONFIG_PATH" ] || { echo "[错误] 未找到配置文件: $CONFIG_PATH"; return 1; }
    "$BIN_PATH" -t -d "$WORK_DIR" -f "$CONFIG_PATH" >/dev/null 2>&1 || {
        echo "[错误] 配置校验失败: $CONFIG_PATH"
        return 1
    }
    return 0
}

start_process() {
    local pid=""

    validate_process || {
        is_interactive || log_restart_event "配置校验失败，未启动进程"
        return 1
    }

    nohup "$BIN_PATH" -d "$WORK_DIR" -f "$CONFIG_PATH" >/dev/null 2>&1 &
    pid=$!
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo "[成功] 启动成功（PID: ${pid}）"
        is_interactive || log_restart_event "定时任务自动启动成功"
        return 0
    fi

    echo "[错误] 启动失败"
    is_interactive || log_restart_event "启动失败"
    return 1
}

stop_process() {
    local pid=""
    local pids=""
    local i=0
    local running=""

    pids="$(get_pid)"
    if [ -z "$pids" ]; then
        log_msg "[提示] 当前未运行"
        return 0
    fi

    log_msg "[信息] 正在停止 PID: $(printf '%s' "$pids" | tr '\n' ' ')..."
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done

    while :; do
        running=""
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                running=1
                break
            fi
        done
        [ -z "$running" ] && break
        i=$((i + 1))
        [ "$i" -ge 10 ] && break
        sleep 1
    done

    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    sleep 1

    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "[错误] 停止进程失败: $pid"
            return 1
        fi
    done

    log_msg "[成功] 已停止"
    return 0
}

show_status() {
    local pid=""

    pid="$(get_pid)"
    if [ -n "$pid" ]; then
        echo "[成功] 正在运行（PID: $(printf '%s' "$pid" | tr '\n' ' ')）"
    else
        echo "[提示] 当前未运行"
    fi
}

setup_install() {
    require_install_commands
    mkdir -p "$WORK_DIR" || {
        echo "[错误] 创建目录失败: $WORK_DIR"
        exit 1
    }
    cd "$WORK_DIR" || exit 1

    echo "[信息] 检测到首次运行，开始安装 mihomo 到: $WORK_DIR"
    download_release || {
        echo "[错误] 下载失败"
        exit 1
    }
    extract_binary || {
        echo "[错误] 解压失败"
        exit 1
    }

    prepare_certificate || exit 1

    TROJAN_PORT="$(prompt_input "请输入 Trojan 监听端口" "24838")"
    WS_PATH="$(normalize_ws_path "$(prompt_input "请输入 WebSocket 路径" "$WS_PATH")")"
    TROJAN_PASSWORD="$(prompt_input "请输入 Trojan 密码" "$(random_pass)" 1)"
    HY2_PORT="$(prompt_input "请输入 Hysteria2 监听端口" "24839")"
    HY2_PASSWORD="$(prompt_input "请输入 Hysteria2 密码" "$(random_pass)" 1)"

    generate_config
    start_process || exit 1
}

ensure_installed() {
    [ -x "$BIN_PATH" ] && [ -f "$CONFIG_PATH" ]
}

main() {
    case "${1:-}" in
        restart)
            if ! ensure_installed; then
                echo "[提示] 尚未安装，开始进入安装流程..."
                setup_install
                exit $?
            fi
            stop_process
            start_process
            ;;
        stop)
            stop_process
            ;;
        trojan|hysteria)
            apply_config_change "$@" || exit 1
            ;;
        "")
            if ! ensure_installed; then
                setup_install
            else
                require_install_commands
                update_if_needed || exit 1
                if is_running; then
                    show_status
                else
                    log_msg "[提示] 当前未运行，正在尝试启动..."
                    start_process
                fi
            fi
            ;;
        *)
            echo "[错误] 未知参数: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
