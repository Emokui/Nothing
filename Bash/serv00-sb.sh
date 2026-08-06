#!/bin/sh

# FreeBSD/Serv00 user-space installer for sing-box.
# No root, pkg, systemd or rc.d service is required.

umask 077

RELEASE_API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
SOURCE_BASE_URL="https://github.com/SagerNet/sing-box/archive/refs/tags"
ACME_SOURCE_URL="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
WS_PATH="/"

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || {
    echo "[错误] HOME 目录不可用"
    exit 1
}
HOME_DIR="$HOME"

WORK_DIR="${WORK_DIR:-$HOME_DIR/sing-box}"
BIN_PATH="${BIN_PATH:-$WORK_DIR/sing-box}"
CONFIG_PATH="${CONFIG_PATH:-$WORK_DIR/config.json}"
RESTART_LOG="${RESTART_LOG:-$WORK_DIR/blog.log}"
ACME_HOME="${ACME_HOME:-$WORK_DIR/.acme.sh}"
ACME_BIN="${ACME_BIN:-$ACME_HOME/acme.sh}"
ACME_RELOAD_HOOK="${ACME_RELOAD_HOOK:-$WORK_DIR/acme-reload.sh}"
BUILD_DIR=""

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

is_interactive() {
    [ -t 1 ]
}

log_msg() {
    is_interactive && echo "$1"
}

log_restart_event() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RESTART_LOG"
}

require_commands() {
    local missing=""
    local cmd

    for cmd in awk cat chmod date head kill mkdir mktemp mv nohup openssl ps rm sed sleep stty tr uname; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    if [ -n "$missing" ]; then
        echo "[错误] 缺少依赖命令:$missing"
        return 1
    fi
}

check_platform() {
    local os arch

    os="$(uname -s 2>/dev/null)"
    arch="$(uname -m 2>/dev/null)"
    [ "$os" = "FreeBSD" ] || {
        echo "[错误] 本脚本仅支持 FreeBSD，当前系统: ${os:-unknown}"
        return 1
    }

    [ "$arch" = "amd64" ] || {
        echo "[错误] 本脚本仅支持 FreeBSD amd64，当前架构: ${arch:-unknown}"
        return 1
    }
}

require_build_commands() {
    local missing=""
    local cmd

    if ! command -v curl >/dev/null 2>&1 && ! command -v fetch >/dev/null 2>&1; then
        echo "[错误] 需要 curl 或 FreeBSD fetch 命令"
        return 1
    fi

    for cmd in go tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    if [ -n "$missing" ]; then
        echo "[错误] 源码编译缺少命令:$missing"
        echo "[提示] FreeBSD 官方 Release 没有预编译包，需要可用的 Go 工具链"
        return 1
    fi
}

fetch_text() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url"
    else
        fetch -qo - "$url"
    fi
}

download_file() {
    local url="$1"
    local target="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --max-time 300 "$url" -o "$target"
    else
        fetch -o "$target" "$url"
    fi
}

get_latest_version() {
    local response version

    response="$(fetch_text "$RELEASE_API_URL")" || return 1
    version="$(printf '%s\n' "$response" | awk -F '"' '
        /"tag_name"[[:space:]]*:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
                    print $i
                    exit
                }
            }
        }
    ')"
    [ -n "$version" ] || return 1
    printf '%s\n' "$version"
}

get_installed_version() {
    [ -x "$BIN_PATH" ] || return 1
    "$BIN_PATH" version 2>/dev/null | awk '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {
                    print "v" $i
                    exit
                }
            }
        }
    '
}

cleanup_build() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
    BUILD_DIR=""
}

build_release() {
    local version="$1"
    local archive source_dir build_tags ldflags version_number built_version

    require_build_commands || return 1
    cleanup_build

    BUILD_DIR="$(mktemp -d "$WORK_DIR/.build.XXXXXX")" || return 1
    archive="$BUILD_DIR/source.tar.gz"
    source_dir="$BUILD_DIR/source"
    mkdir -p "$source_dir" || { cleanup_build; return 1; }

    echo "[信息] 正在下载 Sing-box ${version} 源码..."
    download_file "${SOURCE_BASE_URL}/${version}.tar.gz" "$archive" || {
        echo "[错误] Sing-box 源码下载失败"
        cleanup_build
        return 1
    }

    tar -xzf "$archive" -C "$source_dir" --strip-components 1 || {
        echo "[错误] Sing-box 源码解压失败"
        cleanup_build
        return 1
    }

    [ -r "$source_dir/release/LDFLAGS" ] || {
        echo "[错误] 源码中缺少官方链接参数"
        cleanup_build
        return 1
    }

    # Trojan+WebSocket 无需额外标签；Hysteria2 只需要 QUIC。
    # Tailscale/WireGuard/ACME/API 等组件不属于本脚本功能，且会增加体积与编译负担。
    build_tags="with_quic,badlinkname,tfogo_checklinkname0"
    ldflags="$(tr -d '\r\n' < "$source_dir/release/LDFLAGS")"
    [ -n "$ldflags" ] || {
        echo "[错误] 无法读取官方构建参数"
        cleanup_build
        return 1
    }
    version_number="${version#v}"
    ldflags="-X github.com/sagernet/sing-box/constant.Version=$version_number $ldflags -s -w -buildid="

    echo "[信息] 正在编译 Sing-box ${version}，首次编译需要下载 Go 依赖..."
    if ! (
        cd "$source_dir" || exit 1
        GOCACHE="$WORK_DIR/.cache/go-build" \
        GOMODCACHE="$WORK_DIR/.cache/go-mod" \
        CGO_ENABLED=0 go build -trimpath \
            -tags "$build_tags" \
            -ldflags "$ldflags" \
            -o "$BUILD_DIR/sing-box" \
            ./cmd/sing-box
    ); then
        echo "[错误] Sing-box 编译失败"
        cleanup_build
        return 1
    fi

    chmod 700 "$BUILD_DIR/sing-box" || { cleanup_build; return 1; }
    built_version="$("$BUILD_DIR/sing-box" version --name 2>/dev/null)"
    if [ "$built_version" != "$version_number" ]; then
        echo "[错误] 编译版本校验失败: ${built_version:-unknown} != $version_number"
        cleanup_build
        return 1
    fi
}

install_built_binary() {
    local new_path="${BIN_PATH}.new"

    [ -x "$BUILD_DIR/sing-box" ] || return 1
    mv "$BUILD_DIR/sing-box" "$new_path" || return 1
    chmod 700 "$new_path" || { rm -f "$new_path"; return 1; }
    mv "$new_path" "$BIN_PATH" || { rm -f "$new_path"; return 1; }
    cleanup_build
}

random_pass() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local secret="${3:-0}"
    local value=""

    if [ "$secret" = "1" ]; then
        if [ -n "$default" ]; then
            printf '%s（默认值已隐藏）: ' "$prompt" >&2
        else
            printf '%s: ' "$prompt" >&2
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
    local choice

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

normalize_ws_path() {
    case "${1:-}" in
        '') printf '/\n' ;;
        /*) printf '%s\n' "$1" ;;
        *) printf '/%s\n' "$1" ;;
    esac
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
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
    local install_dir archive source_dir install_status

    [ -x "$ACME_BIN" ] && return 0
    command -v curl >/dev/null 2>&1 || {
        echo "[错误] Cloudflare API 申请证书需要 curl"
        return 1
    }
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
    download_file "$ACME_SOURCE_URL" "$archive" || {
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
    local cert_name cf_token issue_status

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

    CERT_PATH="$WORK_DIR/${cert_name}.pem"
    KEY_PATH="$WORK_DIR/${cert_name}.key"
    CERT_NAME="$cert_name"

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
        --key-file "$KEY_PATH" \
        --fullchain-file "$CERT_PATH" \
        --reloadcmd "/bin/sh $ACME_RELOAD_HOOK" || {
        echo "[错误] 证书安装到 Sing-box 路径失败"
        return 1
    }

    [ -s "$CERT_PATH" ] && [ -s "$KEY_PATH" ] || {
        echo "[错误] 证书或私钥文件为空"
        return 1
    }
    openssl x509 -in "$CERT_PATH" -noout >/dev/null 2>&1 || {
        echo "[错误] 证书文件格式校验失败"
        return 1
    }
    openssl pkey -in "$KEY_PATH" -noout >/dev/null 2>&1 || {
        echo "[错误] 私钥文件格式校验失败"
        return 1
    }
    chmod 600 "$CERT_PATH" "$KEY_PATH" || return 1
    echo "[成功] 单域名证书申请完成"
}

generate_config() {
    local cert_path key_path trojan_password hy2_password ws_path

    cert_path="$(json_escape "$CERT_PATH")"
    key_path="$(json_escape "$KEY_PATH")"
    trojan_password="$(json_escape "$TROJAN_PASSWORD")"
    hy2_password="$(json_escape "$HY2_PASSWORD")"
    ws_path="$(json_escape "$WS_PATH")"

    {
        cat <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "cloudflare",
        "server": "1.1.1.1"
      }
    ],
    "final": "cloudflare",
    "strategy": "ipv4_only",
    "cache_capacity": 4096
  },
  "inbounds": [
EOF
        if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
            cat <<EOF
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "0.0.0.0",
      "listen_port": $TROJAN_PORT,
      "users": [
        {
          "name": "user1",
          "password": "$trojan_password"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      },
      "transport": {
        "type": "ws",
        "path": "$ws_path"
      }
    }
EOF
            [ "$PROTOCOL_MODE" = "3" ] && printf ',\n'
        fi
        if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
            cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "name": "user1",
          "password": "$hy2_password"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
EOF
        fi
        cat <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": "cloudflare"
  }
}
EOF
    } > "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

get_pid() {
    ps axww -o pid= -o command= 2>/dev/null | awk \
        -v bin="$BIN_PATH" \
        -v config="$CONFIG_PATH" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if (index($0, config) > 0 && index($0, bin " ") == 1) {
                print pid
            }
        }
    '
}

is_running() {
    [ -n "$(get_pid 2>/dev/null)" ]
}

validate_process() {
    [ -x "$BIN_PATH" ] || { echo "[错误] 未找到 Sing-box: $BIN_PATH"; return 1; }
    [ -f "$CONFIG_PATH" ] || { echo "[错误] 未找到配置: $CONFIG_PATH"; return 1; }
    "$BIN_PATH" check -c "$CONFIG_PATH" || {
        echo "[错误] Sing-box 配置校验失败"
        return 1
    }
}

start_process() {
    local pid

    if is_running; then
        log_msg "[提示] Sing-box 已经在运行"
        return 0
    fi
    validate_process || { is_interactive || log_restart_event "配置校验失败"; return 1; }

    nohup "$BIN_PATH" run -c "$CONFIG_PATH" >/dev/null 2>&1 &
    pid=$!
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "[成功] Sing-box 已启动（PID: ${pid}）"
        is_interactive || log_restart_event "自动启动成功，PID: $pid"
        return 0
    fi

    echo "[错误] Sing-box 启动失败"
    is_interactive || log_restart_event "启动失败"
    return 1
}

stop_process() {
    local pids pid i running

    pids="$(get_pid)"
    if [ -z "$pids" ]; then
        log_msg "[提示] Sing-box 当前未运行"
        return 0
    fi

    log_msg "[信息] 正在停止 PID: $(printf '%s' "$pids" | tr '\n' ' ')"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done

    i=0
    while [ "$i" -lt 10 ]; do
        running=""
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && running=1
        done
        [ -z "$running" ] && break
        i=$((i + 1))
        sleep 1
    done

    for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1

    is_running && { echo "[错误] Sing-box 停止失败"; return 1; }
    log_msg "[成功] Sing-box 已停止"
}

show_status() {
    local pids version
    pids="$(get_pid)"
    version="$(get_installed_version 2>/dev/null)"
    echo "Sing-box: ${version:-未安装}"
    echo "目录: $WORK_DIR"
    if [ -n "$pids" ]; then
        echo "状态: 运行中（PID: $(printf '%s' "$pids" | tr '\n' ' ')）"
    else
        echo "状态: 未运行"
    fi
}

delete_service() {
    case "${WORK_DIR%/}" in
        ''|'/'|"$HOME_DIR")
            echo "[错误] 拒绝删除不安全的目录: $WORK_DIR"
            return 1
            ;;
    esac

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
    if [ -d "$WORK_DIR/.cache" ]; then
        chmod -R u+w "$WORK_DIR/.cache" || {
            echo "[错误] 无法恢复 Go 缓存目录的删除权限"
            return 1
        }
    fi
    rm -rf "$WORK_DIR" || {
        echo "[错误] 删除 Sing-box 服务失败: $WORK_DIR"
        return 1
    }

    echo "[成功] Sing-box 服务、证书及编译文件已删除"
}

update_if_needed() {
    local latest current was_running=0

    latest="$(get_latest_version)" || {
        echo "[警告] 获取 Sing-box 最新版本失败，跳过更新"
        return 0
    }
    current="$(get_installed_version 2>/dev/null)"

    if [ "$current" = "$latest" ]; then
        echo "[信息] Sing-box 已是最新版本: $latest"
        return 0
    fi

    echo "[信息] 检测到新版本: ${current:-未安装} -> $latest"
    build_release "$latest" || {
        echo "[警告] Sing-box 更新编译失败，继续使用当前版本"
        return 0
    }
    is_running && was_running=1
    [ "$was_running" -eq 0 ] || stop_process || { cleanup_build; return 1; }
    install_built_binary || {
        echo "[错误] Sing-box 新版本安装失败"
        cleanup_build
        [ "$was_running" -eq 0 ] || start_process
        return 1
    }
    echo "[成功] Sing-box 已更新到 $latest"
    [ "$was_running" -eq 0 ] || start_process
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
    local target escaped tmp_path value_path

    case "$service" in
        trojan) target="trojan-in" ;;
        hysteria) target="hy2-in" ;;
        *) show_usage; return 1 ;;
    esac

    awk -v target="$target" '
        index($0, "\"tag\": \"" target "\"") { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$CONFIG_PATH" || {
        echo "[错误] 当前配置未启用 $service"
        return 1
    }

    case "$item" in
        PT)
            case "$value" in *[!0-9]*|'') echo "[错误] 端口必须是数字"; return 1 ;; esac
            [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || {
                echo "[错误] 端口范围必须是 1024-65535"
                return 1
            }
            escaped="$value"
            ;;
        PW) escaped="$(json_escape "$value")" ;;
        *) show_usage; return 1 ;;
    esac

    tmp_path="${CONFIG_PATH}.tmp.$$"
    value_path="${CONFIG_PATH}.value.$$"
    printf '%s\n' "$escaped" > "$value_path" || return 1
    chmod 600 "$value_path"
    awk -v target="$target" -v item="$item" -v value_path="$value_path" '
        BEGIN {
            getline value < value_path
            close(value_path)
        }
        /"tag": "/ {
            in_target = (index($0, "\"tag\": \"" target "\"") > 0)
        }
        in_target && item == "PT" && /"listen_port":/ {
            print "      \"listen_port\": " value ","
            next
        }
        in_target && item == "PW" && /"password":/ {
            print "          \"password\": \"" value "\""
            next
        }
        { print }
    ' "$CONFIG_PATH" > "$tmp_path" || {
        rm -f "$tmp_path" "$value_path"
        return 1
    }
    rm -f "$value_path"

    "$BIN_PATH" check -c "$tmp_path" >/dev/null 2>&1 || {
        rm -f "$tmp_path"
        echo "[错误] 修改后的配置校验失败"
        return 1
    }
    chmod 600 "$tmp_path" && mv "$tmp_path" "$CONFIG_PATH"
}

apply_config_change() {
    [ "$#" -eq 3 ] || { show_usage; return 1; }
    ensure_installed || { echo "[错误] 尚未安装"; return 1; }
    update_config_item "$1" "$2" "$3" || return 1
    stop_process || return 1
    start_process
}

ensure_installed() {
    [ -x "$BIN_PATH" ] && [ -f "$CONFIG_PATH" ]
}

setup_install() {
    local latest

    [ -t 0 ] || {
        echo "[错误] 首次安装需要交互式终端"
        return 1
    }
    check_platform || return 1
    mkdir -p "$WORK_DIR" || return 1
    PROTOCOL_MODE="$(prompt_protocol_mode)" || return 1

    latest="$(get_latest_version)" || {
        echo "[错误] 获取 Sing-box 最新稳定版失败"
        return 1
    }
    build_release "$latest" || return 1
    install_built_binary || return 1

    prepare_certificate || return 1
    if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        TROJAN_PORT="$(prompt_port "请输入已分配的 Trojan TCP 端口" "24838")"
        WS_PATH="$(normalize_ws_path "$(prompt_input "请输入 WebSocket 路径" "$WS_PATH")")"
        TROJAN_PASSWORD="$(prompt_input "请输入 Trojan 密码" "$(random_pass)" 1)"
    fi
    if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        HY2_PORT="$(prompt_port "请输入已分配的 Hysteria2 UDP 端口" "24839")"
        HY2_PASSWORD="$(prompt_input "请输入 Hysteria2 密码" "$(random_pass)" 1)"
    fi

    generate_config || return 1
    start_process || return 1

    echo "[成功] 安装完成"
    echo "[信息] 配置文件: $CONFIG_PATH"
    if [ "$PROTOCOL_MODE" = "1" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        echo "[信息] Trojan: TCP ${TROJAN_PORT}，WS 路径 ${WS_PATH}，SNI $CERT_NAME"
    fi
    if [ "$PROTOCOL_MODE" = "2" ] || [ "$PROTOCOL_MODE" = "3" ]; then
        echo "[信息] Hysteria2: UDP ${HY2_PORT}，SNI $CERT_NAME"
    fi
}

main() {
    require_commands || exit 1

    case "${1:-}" in
        delete)
            delete_service
            ;;
        stop)
            stop_process
            ;;
        restart)
            ensure_installed || { setup_install; exit $?; }
            stop_process && start_process
            ;;
        trojan|hysteria)
            apply_config_change "$@"
            ;;
        '')
            if ! ensure_installed; then
                setup_install
            else
                check_platform || exit 1
                update_if_needed || exit 1
                is_running && show_status || start_process
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
