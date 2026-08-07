#!/bin/sh

umask 077

CURRENT_USER="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null)}"
RELEASE_REPO="MetaCubeX/mihomo"
RELEASE_API_URL="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
RELEASE_ASSET="mihomo-freebsd.gz"
MIHOMO_ASSET_PATTERN='mihomo-freebsd-amd64-compatible-[^"]*\.gz'
ACME_SOURCE_URL="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
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
ACME_HOME="${ACME_HOME:-$WORK_DIR/.acme.sh}"
ACME_BIN="${ACME_BIN:-$ACME_HOME/acme.sh}"
ACME_RELOAD_HOOK="${ACME_RELOAD_HOOK:-$WORK_DIR/acme-reload.sh}"

case "$0" in
    /*) SCRIPT_PATH="$0" ;;
    */*) SCRIPT_PATH="$(cd "${0%/*}" 2>/dev/null && pwd -P)/${0##*/}" ;;
    *)
        SCRIPT_PATH="$(command -v "$0" 2>/dev/null || true)"
        case "$SCRIPT_PATH" in
            /*) ;;
            *) SCRIPT_PATH="$(pwd -P)/$0" ;;
        esac
        ;;
esac

require_commands() {
    local missing=""
    local cmd
    for cmd in awk chmod date head kill mkdir mv nohup ps rm sed sleep stty tr; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    if [ -n "$missing" ]; then
        echo "[错误] 缺少依赖命令:$missing"
        exit 1
    fi
}

require_install_commands() {
    local missing=""
    local cmd

    for cmd in curl gzip mktemp openssl tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        echo "[错误] 安装缺少依赖命令:$missing"
        exit 1
    fi
}

random_pass() {
    openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16
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
        stty -echo 2>/dev/null || true
        IFS= read -r value
        stty echo 2>/dev/null || true
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

prompt_port() {
    local label="$1"
    local default="$2"
    local value=""

    while :; do
        value="$(prompt_input "$label" "$default")"
        case "$value" in
            *[!0-9]*|'') echo "[警告] 端口必须是数字" >&2 ;;
            *)
                if [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null; then
                    printf '%s\n' "$value"
                    return 0
                fi
                echo "[警告] 非 root 用户端口范围应为 1024-65535" >&2
                ;;
        esac
    done
}

prompt_protocol_mode() {
    local choice=""

    while :; do
        printf '\n请选择安装协议：\n' >&2
        printf '1.trojan\n' >&2
        printf '2.hysteria2\n' >&2
        printf '3.trojan+hysteria2\n' >&2
        choice="$(prompt_input "请输入选项 [1-3]" "3")"
        case "$choice" in
            1|2|3) printf '%s\n' "$choice"; return 0 ;;
            *) echo "[警告] 请输入 1、2 或 3" >&2 ;;
        esac
    done
}

validate_certificate_domain() {
    local domain="$1"

    case "$domain" in
        ''|*[!A-Za-z0-9.-]*|.*|*.|-*|*-|*..*|*-.*|*.-*) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

acme_exec() {
    "$ACME_BIN" --home "$ACME_HOME" --config-home "$ACME_HOME" "$@"
}

install_acme_client() {
    local install_dir=""
    local archive=""
    local source_dir=""
    local install_status=0

    [ -x "$ACME_BIN" ] && return 0
    case "$ACME_HOME" in
        *' '*)
            echo "[错误] acme.sh 安装路径不能包含空格: $ACME_HOME"
            return 1
            ;;
    esac

    install_dir="$(mktemp -d "$WORK_DIR/.acme-install.XXXXXX")" || return 1
    archive="$install_dir/acme.sh.tar.gz"
    source_dir="$install_dir/acme.sh-master"

    echo "[信息] 正在安装用户态 acme.sh..."
    curl -fsSL --connect-timeout 10 --max-time 300 \
        -o "$archive" "$ACME_SOURCE_URL" || {
        echo "[错误] acme.sh 下载失败"
        rm -rf "$install_dir"
        return 1
    }
    tar -xzf "$archive" -C "$install_dir" || {
        echo "[错误] acme.sh 解压失败"
        rm -rf "$install_dir"
        return 1
    }
    [ -x "$source_dir/acme.sh" ] || {
        echo "[错误] acme.sh 安装文件不完整"
        rm -rf "$install_dir"
        return 1
    }

    if command -v crontab >/dev/null 2>&1; then
        (cd "$source_dir" && ./acme.sh --install --home "$ACME_HOME" \
            --config-home "$ACME_HOME" --noprofile)
        install_status=$?
    else
        (cd "$source_dir" && ./acme.sh --install --home "$ACME_HOME" \
            --config-home "$ACME_HOME" --nocron --noprofile)
        install_status=$?
        echo "[警告] 未检测到 crontab，请在 Serv00 面板添加定时任务: $ACME_BIN --home $ACME_HOME --config-home $ACME_HOME --cron"
    fi
    rm -rf "$install_dir"

    [ "$install_status" -eq 0 ] && [ -x "$ACME_BIN" ] || {
        echo "[错误] acme.sh 安装失败"
        return 1
    }
}

write_acme_reload_hook() {
    case "$ACME_RELOAD_HOOK$SCRIPT_PATH" in
        *' '*)
            echo "[错误] 自动续期重启路径不能包含空格"
            return 1
            ;;
    esac

    cat > "$ACME_RELOAD_HOOK" <<EOF
#!/bin/sh
[ -x "$BIN_PATH" ] && [ -f "$CONFIG_PATH" ] || exit 0
exec /bin/sh "$SCRIPT_PATH" restart
EOF
    chmod 700 "$ACME_RELOAD_HOOK"
}

prepare_certificate() {
    local cert_name=""
    local cf_token=""
    local issue_status=0
    local cert_path=""
    local key_path=""

    cert_name="$(prompt_input "请输入已托管在 Cloudflare 的证书域名" "")"
    cert_name="$(printf '%s' "$cert_name" | tr '[:upper:]' '[:lower:]')"
    validate_certificate_domain "$cert_name" || {
        echo "[错误] 请输入有效的单域名，例如 node.example.com"
        return 1
    }

    cf_token="$(prompt_input "请输入 Cloudflare API Token" "" 1)"
    case "$cf_token" in
        ''|*[!A-Za-z0-9._~-]*)
            echo "[错误] Cloudflare API Token 为空或包含非法字符"
            return 1
            ;;
    esac

    install_acme_client || return 1

    PEM_NAME="${cert_name}.pem"
    KEY_NAME="${cert_name}.key"
    CERT_NAME="$cert_name"
    cert_path="$WORK_DIR/$PEM_NAME"
    key_path="$WORK_DIR/$KEY_NAME"

    echo "[信息] 正在通过 Cloudflare API 申请单域名证书: $cert_name"
    (
        unset CF_Key CF_Email CF_Account_ID CF_Zone_ID
        export CF_Token="$cf_token"
        acme_exec --issue --server letsencrypt --dns dns_cf \
            --keylength ec-256 -d "$cert_name"
    )
    issue_status=$?
    cf_token=""

    case "$issue_status" in
        0|2) ;;
        *)
            echo "[错误] Cloudflare API 证书申请失败"
            echo "[提示] Token 需要目标区域的 Zone Read 与 DNS Edit 权限"
            return 1
            ;;
    esac

    write_acme_reload_hook || return 1
    acme_exec --install-cert -d "$cert_name" --ecc \
        --key-file "$key_path" \
        --fullchain-file "$cert_path" \
        --reloadcmd "/bin/sh $ACME_RELOAD_HOOK" || {
        echo "[错误] 证书安装到 Mihomo 路径失败"
        return 1
    }

    [ -s "$cert_path" ] && [ -s "$key_path" ] || {
        echo "[错误] 证书或私钥文件为空"
        return 1
    }
    openssl x509 -in "$cert_path" -noout >/dev/null 2>&1 || {
        echo "[错误] 证书文件格式校验失败"
        return 1
    }
    openssl pkey -in "$key_path" -noout >/dev/null 2>&1 || {
        echo "[错误] 私钥文件格式校验失败"
        return 1
    }
    chmod 600 "$cert_path" "$key_path" || return 1
    echo "[成功] 单域名证书申请完成"
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
    curl -fsSL --connect-timeout 10 --max-time 60 "$RELEASE_API_URL"
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

    curl -fL --connect-timeout 10 --max-time 300 \
        "$url" -o "$ARCHIVE_PATH" || return 1
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

    if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
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
    fi

    if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
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
    fi

    cat >> "$CONFIG_PATH" <<EOF
rules:
  - MATCH,DIRECT
EOF
    chmod 600 "$CONFIG_PATH"
}

show_usage() {
    echo "用法: $0 [restart|stop|delete]"
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

    awk -v listener="$listener" '
        $0 == "  - name: " listener { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$CONFIG_PATH" || {
        echo "[错误] 当前配置未启用 $service"
        return 1
    }

    case "$item" in
        PT)
            case "$value" in
                *[!0-9]*|'') echo "[错误] 端口必须是数字"; return 1 ;;
            esac
            [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || {
                echo "[错误] 端口范围必须是 1024-65535"
                return 1
            }
            escaped_value="$value"
            ;;
        PW)
            [ -n "$value" ] || { echo "[错误] 密码不能为空"; return 1; }
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
    ' "$CONFIG_PATH" > "$tmp_path" || {
        rm -f "$tmp_path"
        return 1
    }
    chmod 600 "$tmp_path" || { rm -f "$tmp_path"; return 1; }
    "$BIN_PATH" -t -d "$WORK_DIR" -f "$tmp_path" >/dev/null 2>&1 || {
        rm -f "$tmp_path"
        echo "[错误] 修改后的配置校验失败"
        return 1
    }
    mv "$tmp_path" "$CONFIG_PATH"
}

apply_config_change() {
    if [ "$#" -ne 3 ]; then
        show_usage
        return 1
    fi

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

delete_service() {
    case "${WORK_DIR%/}" in
        ''|'/'|"$HOME_DIR")
            echo "[错误] 拒绝删除不安全的目录: $WORK_DIR"
            return 1
            ;;
    esac

    if ! ensure_installed && [ ! -x "$ACME_BIN" ]; then
        echo "[错误] 未检测到 Mihomo 安装，拒绝删除目录: $WORK_DIR"
        return 1
    fi

    stop_process || return 1
    if [ -x "$ACME_BIN" ]; then
        echo "[信息] 正在移除证书自动续期任务..."
        acme_exec --uninstall >/dev/null 2>&1 || {
            echo "[警告] 自动续期任务移除失败，请手动检查 crontab 或 Serv00 面板"
        }
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        echo "[提示] 如果曾在 Serv00 面板添加续期任务，请同时手动删除"
    fi
    rm -rf "$WORK_DIR" || {
        echo "[错误] 删除 Mihomo 服务失败: $WORK_DIR"
        return 1
    }

    echo "[成功] Mihomo 服务、配置及证书已删除"
}

setup_install() {
    [ -t 0 ] || {
        echo "[错误] 首次安装需要交互式终端"
        exit 1
    }
    require_install_commands
    mkdir -p "$WORK_DIR" || {
        echo "[错误] 创建目录失败: $WORK_DIR"
        exit 1
    }
    cd "$WORK_DIR" || exit 1
    PROTOCOL_MODE="$(prompt_protocol_mode)" || exit 1

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

    if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        TROJAN_PORT="$(prompt_port "请输入 Trojan 监听端口" "24838")"
        WS_PATH="$(normalize_ws_path "$(prompt_input "请输入 WebSocket 路径" "$WS_PATH")")"
        TROJAN_PASSWORD="$(prompt_input "请输入 Trojan 密码" "$(random_pass)" 1)"
    fi
    if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        HY2_PORT="$(prompt_port "请输入 Hysteria2 监听端口" "24839")"
        HY2_PASSWORD="$(prompt_input "请输入 Hysteria2 密码" "$(random_pass)" 1)"
    fi

    generate_config || exit 1
    start_process || exit 1

    echo "[成功] 安装完成"
    echo "[信息] 配置文件: $CONFIG_PATH"
    if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        echo "[信息] Trojan: TCP ${TROJAN_PORT}，WS 路径 ${WS_PATH}，SNI $CERT_NAME"
    fi
    if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        echo "[信息] Hysteria2: UDP ${HY2_PORT}，SNI $CERT_NAME"
    fi
}

ensure_installed() {
    [ -x "$BIN_PATH" ] && [ -f "$CONFIG_PATH" ]
}

main() {
    require_commands

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
        delete)
            delete_service
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
