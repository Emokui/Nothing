#!/bin/sh

CURRENT_USER="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null)}"
RELEASE_REPO="sukurain/shoes"
RELEASE_ASSET="shoes-bbr-freebsd.tar.gz"
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
BIN_NAME="${BIN_NAME:-shoes}"
BIN_PATH="${BIN_PATH:-$WORK_DIR/$BIN_NAME}"
CONFIG_PATH="${CONFIG_PATH:-$WORK_DIR/config.yaml}"
PID_FILE="${PID_FILE:-$WORK_DIR/blog.pid}"
RESTART_LOG="${RESTART_LOG:-$WORK_DIR/blog.log}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_DIR/$RELEASE_ASSET}"

require_commands() {
    local missing=""
    local cmd
    for cmd in tar awk ps kill nohup; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    if [ -n "$missing" ]; then
        echo "[错误] 缺少依赖命令:$missing"
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

get_download_url() {
    printf '%s\n' "https://github.com/${RELEASE_REPO}/releases/latest/download/${RELEASE_ASSET}"
}

download_release() {
    local url=""

    url="$(get_download_url)"
    echo "[信息] 正在下载 ${RELEASE_ASSET} ..."

    if command -v fetch >/dev/null 2>&1; then
        fetch -o "$ARCHIVE_PATH" "$url" || return 1
    else
        curl -fL "$url" -o "$ARCHIVE_PATH" || return 1
    fi
}

extract_binary() {
    tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR" || return 1
    chmod +x "$BIN_PATH" || return 1
    rm -f "$ARCHIVE_PATH" || return 1
}

generate_config() {
    cat > "$CONFIG_PATH" <<EOF
- address: "0.0.0.0:${PORT}"
  protocol:
    type: tls
    tls_targets:
      "${SNI}":
        cert: "${WORK_DIR}/${PEM_NAME}"
        key: "${WORK_DIR}/${KEY_NAME}"
        protocol:
          type: websocket
          targets:
            - matching_path: "${WS_PATH}"
              protocol:
                type: trojan
                password: "${PASSWORD}"
EOF
    chmod 600 "$CONFIG_PATH"
}

get_pid() {
    local pid=""

    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
            return 0
        fi
        rm -f "$PID_FILE"
    fi

    return 1
}

is_running() {
    [ -n "$(get_pid 2>/dev/null)" ]
}

validate_process() {
    [ -x "$BIN_PATH" ] || { echo "[错误] 未找到可执行文件: $BIN_PATH"; return 1; }
    [ -f "$CONFIG_PATH" ] || { echo "[错误] 未找到配置文件: $CONFIG_PATH"; return 1; }
    "$BIN_PATH" --dry-run "$CONFIG_PATH" >/dev/null 2>&1 || {
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

    nohup "$BIN_PATH" "$CONFIG_PATH" >/dev/null 2>&1 &
    pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo "[成功] 启动成功（PID: $pid）"
        is_interactive || log_restart_event "定时任务自动启动成功"
        return 0
    fi

    rm -f "$PID_FILE"
    echo "[错误] 启动失败"
    is_interactive || log_restart_event "启动失败"
    return 1
}

stop_process() {
    local pid=""
    local i=0

    pid="$(get_pid)"
    if [ -z "$pid" ]; then
        log_msg "[提示] 当前未运行"
        return 0
    fi

    log_msg "[信息] 正在停止 PID: $pid ..."
    kill "$pid" 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge 10 ] && break
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        echo "[错误] 停止进程失败"
        return 1
    fi

    rm -f "$PID_FILE"
    log_msg "[成功] 已停止"
    return 0
}

show_status() {
    local pid=""

    pid="$(get_pid)"
    if [ -n "$pid" ]; then
        echo "[成功] 正在运行（PID: $pid）"
    else
        echo "[提示] 当前未运行"
    fi
}

setup_install() {
    require_commands
    mkdir -p "$WORK_DIR" || {
        echo "[错误] 创建目录失败: $WORK_DIR"
        exit 1
    }
    cd "$WORK_DIR" || exit 1

    echo "[信息] 检测到首次运行，开始安装 shoes 到: $WORK_DIR"
    download_release || {
        echo "[错误] 下载失败"
        exit 1
    }
    extract_binary || {
        echo "[错误] 解压失败"
        exit 1
    }

    PEM_NAME="$(prompt_input "请输入 .pem 文件名" "server.pem")"
    KEY_NAME="$(prompt_input "请输入 .key 文件名" "server.key")"
    write_multiline_file "$WORK_DIR/$PEM_NAME" "$PEM_NAME"
    write_multiline_file "$WORK_DIR/$KEY_NAME" "$KEY_NAME"
    chmod 600 "$WORK_DIR/$PEM_NAME" "$WORK_DIR/$KEY_NAME" 2>/dev/null || true

    PORT="$(prompt_input "请输入监听端口" "24838")"
    PASSWORD="$(prompt_input "请输入 Trojan 密码" "$(random_pass)" 1)"
    SNI="$(prompt_input "请输入 SNI/域名" "example.com")"

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
        status)
            show_status
            ;;
        *)
            if ! ensure_installed; then
                setup_install
            elif is_running; then
                show_status
            else
                log_msg "[提示] 当前未运行，正在尝试启动..."
                start_process
            fi
            ;;
    esac
}

main "$@"
