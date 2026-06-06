#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP="protocol-manager"
STATE_DIR="${STATE_DIR:-/etc/${APP}}"
ACCOUNT_DIR="${STATE_DIR}/accounts"
SFTP_STATE="${STATE_DIR}/sftp.env"
FTP_STATE="${STATE_DIR}/ftp.env"
SHARED_ROOT="${SHARED_ROOT:-/srv/shared}"
SHARED_GROUP="${SHARED_GROUP:-spmshare}"
AUTHORIZED_KEYS_DIR="${AUTHORIZED_KEYS_DIR:-/etc/ssh/authorized_keys}"
WEBDAV_USER_AUTH_DIR="${STATE_DIR}/webdav-users"
OWNERSHIP_DIR="${STATE_DIR}/ownership"
MANAGED_USER_DIR="${OWNERSHIP_DIR}/users"
MANAGED_GROUP_DIR="${OWNERSHIP_DIR}/groups"
ADOPTED_USER_DIR="${OWNERSHIP_DIR}/adopted-users"
ADOPTED_GROUP_DIR="${OWNERSHIP_DIR}/adopted-groups"
ORIGINAL_DIR="${OWNERSHIP_DIR}/originals"
TLS_DIR="${STATE_DIR}/tls"
WEBDAV_TLS="${WEBDAV_TLS:-0}"
SSH_BEGIN="# BEGIN managed by ${APP}"
SSH_END="# END managed by ${APP}"
EXPIRY_SERVICE="${APP}-expire.service"
EXPIRY_TIMER="${APP}-expire.timer"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}
title() { printf '\n%s\n' "$*" >&2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行，或通过 sudo 执行。"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_system() {
  [ -r /etc/os-release ] || die "无法读取 /etc/os-release。"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      FAMILY="debian"; SSH_SERVICE="ssh"; APACHE_SERVICE="apache2"; APACHE_USER="www-data"
      ;;
    rhel|centos|rocky|almalinux|fedora)
      FAMILY="rhel"; PKG="$(command_exists dnf && printf dnf || printf yum)"
      SSH_SERVICE="sshd"; APACHE_SERVICE="httpd"; APACHE_USER="apache"
      ;;
    *) die "暂不支持的发行版: ${ID:-unknown}" ;;
  esac
  FTP_SERVICE="vsftpd"
}

init_state() {
  mkdir -p "${ACCOUNT_DIR}/sftp" "${ACCOUNT_DIR}/ftp" "${ACCOUNT_DIR}/webdav" "${STATE_DIR}/expired" \
    "$WEBDAV_USER_AUTH_DIR" "$MANAGED_USER_DIR" "$MANAGED_GROUP_DIR" "$ADOPTED_USER_DIR" "$ADOPTED_GROUP_DIR" "$ORIGINAL_DIR" "$TLS_DIR"
  chown root:root "$STATE_DIR"
  chmod 755 "$STATE_DIR"
  chmod 700 "$ACCOUNT_DIR" "${ACCOUNT_DIR}/sftp" "${ACCOUNT_DIR}/ftp" "${ACCOUNT_DIR}/webdav" \
    "${STATE_DIR}/expired" "$WEBDAV_USER_AUTH_DIR" "$OWNERSHIP_DIR" "$MANAGED_USER_DIR" "$MANAGED_GROUP_DIR" \
    "$ADOPTED_USER_DIR" "$ADOPTED_GROUP_DIR" "$ORIGINAL_DIR" "$TLS_DIR"
  migrate_managed_ownership
}

usage() {
  cat <<EOF
用法:
  sudo $0             打开交互管理菜单
  sudo $0 status      查看服务状态
  sudo $0 expire      清理已过期的临时账户
  sudo $0 repair-webdav  按当前协议模式重建全部 WebDAV 配置
  sudo $0 purge-all   purge 全部协议和账户，保留数据目录
EOF
}

prompt() {
  local text="$1" default="$2" value=""
  printf '%s [%s]: ' "$text" "$default" >&2
  read -r value
  printf '%s' "${value:-$default}"
}

confirm() {
  local text="$1" answer=""
  printf '%s [y/N] ' "$text" >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

select_menu() {
  local heading="$1" answer i
  shift
  local options=("$@")

  [ -t 0 ] || die "交互菜单需要在终端中运行。"
  printf '\n%s\n\n' "$heading" >&2
  for i in "${!options[@]}"; do
    printf '%d.%s\n' "$((i + 1))" "${options[$i]}" >&2
  done
  while true; do
    printf '\n请输入序号 [1]: ' >&2
    read -r answer
    answer="${answer:-1}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
      printf '%s' "${options[$((answer - 1))]}"
      return
    fi
    warn "无效选择，请重新输入。"
  done
}

pause_screen() {
  printf '\n按 Enter 返回菜单...' >&2
  read -r
}

read_password() {
  local text="$1" first="" second=""
  while true; do
    printf '%s' "$text" >&2
    IFS= read -rs first
    printf '\n请再次输入确认: ' >&2
    IFS= read -rs second
    printf '\n' >&2
    [ -n "$first" ] || { warn "密码不能为空。"; continue; }
    [ "$first" = "$second" ] || { warn "两次输入不一致。"; continue; }
    [[ "$first" != *:* ]] || { warn "密码不能包含冒号。"; continue; }
    printf '%s' "$first"
    return
  done
}

validate_name() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "账户名无效: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "端口必须在 1-65535 之间。"
}

validate_path() {
  [[ "$1" = /* && "$1" != *"/../"* && "$1" != */.. && "$1" != *"/./"* && "$1" != */. && "$1" != *[[:space:]]* ]] ||
    die "路径必须是无空白、无 . 或 .. 的绝对路径: $1"
}

validate_shared_dir() {
  local path="$1" chroot="$2"
  validate_path "$path"
  [[ "$chroot" = "$SHARED_ROOT"/* && "$path" = "${chroot}/files" ]] ||
    die "共享文件目录必须是 ${SHARED_ROOT}/<共享实例>/files。"
}

account_chroot() {
  printf '%s/%s' "$SHARED_ROOT" "$1"
}

account_shared_dir() {
  printf '%s/%s/files' "$SHARED_ROOT" "$1"
}

shared_name_from_dir() {
  local relative="${1#"$SHARED_ROOT"/}"
  printf '%s' "${relative%%/*}"
}

account_file() {
  printf '%s/%s/%s.env' "$ACCOUNT_DIR" "$1" "$2"
}

atomic_install() {
  local source="$1" target="$2" mode="${3:-600}" owner="${4:-root}" group="${5:-root}" dir temp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  temp="$(mktemp "${dir}/.${APP}.XXXXXX")"
  cat "$source" > "$temp"
  chown "$owner:$group" "$temp"
  chmod "$mode" "$temp"
  mv -f "$temp" "$target"
}

atomic_write_stdin() {
  local target="$1" mode="${2:-600}" owner="${3:-root}" group="${4:-root}" temp
  temp="$(mktemp)"
  cat > "$temp"
  atomic_install "$temp" "$target" "$mode" "$owner" "$group"
  rm -f "$temp"
}

mark_owned() {
  local type="$1" name="$2"
  atomic_write_stdin "${OWNERSHIP_DIR}/${type}/${name}" 600 <<EOF
managed_by=${APP}
EOF
}

capture_original_file() {
  local target="$1" name="$2"
  [ -e "${ORIGINAL_DIR}/${name}.captured" ] && return
  [ ! -f "$target" ] || cp -a "$target" "${ORIGINAL_DIR}/${name}.original"
  atomic_write_stdin "${ORIGINAL_DIR}/${name}.captured" 600 <<EOF
target=$(printf %q "$target")
EOF
}

restore_original_file() {
  local target="$1" name="$2"
  [ -f "${ORIGINAL_DIR}/${name}.captured" ] || return 0
  if [ -f "${ORIGINAL_DIR}/${name}.original" ]; then
    cp -a "${ORIGINAL_DIR}/${name}.original" "$target"
  else
    rm -f "$target"
  fi
}

is_owned() {
  [ -f "${OWNERSHIP_DIR}/$1/$2" ]
}

mark_adopted() {
  local type="$1" name="$2"
  atomic_write_stdin "${OWNERSHIP_DIR}/adopted-${type}/${name}" 600 <<EOF
adopted_by=${APP}
EOF
}

is_managed() {
  is_owned "$1" "$2" || [ -f "${OWNERSHIP_DIR}/adopted-$1/$2" ]
}

migrate_managed_ownership() {
  local protocol file user group USER GROUP SHARE CHROOT DATA_DIR AUTH_MODE ROOT PORT TEMPORARY EXPIRES_AT
  for protocol in ftp sftp; do
    for file in "${ACCOUNT_DIR}/${protocol}"/*.env; do
      [ -f "$file" ] || continue
      user=""; group=""
      # shellcheck disable=SC1090
      . "$file"
      user="${USER:-}"; group="${GROUP:-}"
      [ -n "$user" ] || continue
      is_managed users "$user" && continue
      id "$user" >/dev/null 2>&1 && mark_adopted users "$user"
      [ -z "$group" ] || ! getent group "$group" >/dev/null 2>&1 || mark_adopted groups "$group"
    done
  done
}

begin_account_transaction() {
  TX_KIND=create; TX_PROTOCOL="$1"; TX_USER="$2"; TX_GROUP="${3:-}"; TX_SHARE="${4:-}"; TX_SECOND_SHARE=""; TX_ACTIVE=1
  TX_OWNER_PID="$BASHPID"
  trap 'transaction_exit_handler $?' EXIT
}

begin_account_update() {
  local account_state service_state=""
  TX_KIND=update; TX_PROTOCOL="$1"; TX_USER="$2"; TX_SHARE="${3:-}"; TX_SECOND_SHARE="${4:-}"; TX_ACTIVE=1
  TX_DIR="$(mktemp -d)"; chmod 700 "$TX_DIR"
  account_state="$(account_file "$TX_PROTOCOL" "$TX_USER")"
  cp -a "$account_state" "${TX_DIR}/account.env"
  case "$TX_PROTOCOL" in sftp) service_state="$SFTP_STATE" ;; ftp) service_state="$FTP_STATE" ;; esac
  if [ -n "$service_state" ]; then
    if [ -f "$service_state" ]; then cp -a "$service_state" "${TX_DIR}/service.env"; else touch "${TX_DIR}/service.absent"; fi
  fi
  if id "$TX_USER" >/dev/null 2>&1; then
    TX_OLD_GROUP="$(id -gn "$TX_USER")"
    TX_OLD_HOME="$(getent passwd "$TX_USER" | cut -d: -f6)"
    TX_OLD_SHELL="$(getent passwd "$TX_USER" | cut -d: -f7)"
    TX_OLD_HASH="$(getent shadow "$TX_USER" | cut -d: -f2)"
  else
    TX_OLD_GROUP=""; TX_OLD_HOME=""; TX_OLD_SHELL=""; TX_OLD_HASH=""
  fi
  [ ! -f "${AUTHORIZED_KEYS_DIR}/${TX_USER}" ] || cp -a "${AUTHORIZED_KEYS_DIR}/${TX_USER}" "${TX_DIR}/authorized_key"
  [ ! -f "$(webdav_user_auth_file "$TX_USER")" ] || cp -a "$(webdav_user_auth_file "$TX_USER")" "${TX_DIR}/webdav_auth"
  TX_OWNER_PID="$BASHPID"
  trap 'transaction_exit_handler $?' EXIT
}

commit_account_transaction() {
  TX_ACTIVE=0
  trap - EXIT
  [ -z "${TX_DIR:-}" ] || rm -rf "$TX_DIR"
  TX_DIR=""
}

transaction_exit_handler() {
  local status="$1"
  trap - EXIT
  [ "$status" -ne 0 ] || return 0
  [ "${TX_ACTIVE:-0}" -eq 1 ] || return "$status"
  [ "${TX_OWNER_PID:-}" = "$BASHPID" ] || return "$status"
  rollback_account_transaction "$status"
}

rollback_account_transaction() {
  local status="$1" account_state service_state=""
  trap - EXIT
  [ "${TX_ACTIVE:-0}" -eq 1 ] || exit "$status"
  TX_ROLLING_BACK=1
  set +e
  warn "账户操作未完成，正在回滚: ${TX_PROTOCOL}:${TX_USER}"
  account_state="$(account_file "$TX_PROTOCOL" "$TX_USER")"
  if [ "${TX_KIND:-create}" = update ]; then
    atomic_install "${TX_DIR}/account.env" "$account_state" 600
    case "$TX_PROTOCOL" in sftp) service_state="$SFTP_STATE" ;; ftp) service_state="$FTP_STATE" ;; esac
    if [ -n "$service_state" ]; then
      if [ -f "${TX_DIR}/service.env" ]; then atomic_install "${TX_DIR}/service.env" "$service_state" 600; else rm -f "$service_state"; fi
    fi
    if id "$TX_USER" >/dev/null 2>&1 && is_managed users "$TX_USER"; then
      usermod -g "$TX_OLD_GROUP" -d "$TX_OLD_HOME" -s "$TX_OLD_SHELL" "$TX_USER" >/dev/null 2>&1
      [ -z "$TX_OLD_HASH" ] || printf '%s:%s\n' "$TX_USER" "$TX_OLD_HASH" | chpasswd -e >/dev/null 2>&1
    fi
    if [ -f "${TX_DIR}/authorized_key" ]; then cp -a "${TX_DIR}/authorized_key" "${AUTHORIZED_KEYS_DIR}/${TX_USER}"; else rm -f "${AUTHORIZED_KEYS_DIR}/${TX_USER}"; fi
    if [ -f "${TX_DIR}/webdav_auth" ]; then cp -a "${TX_DIR}/webdav_auth" "$(webdav_user_auth_file "$TX_USER")"; else rm -f "$(webdav_user_auth_file "$TX_USER")"; fi
  else
    rm -f "$account_state" "$(webdav_user_auth_file "$TX_USER")" \
      "${AUTHORIZED_KEYS_DIR}/${TX_USER}" "${STATE_DIR}/expired/${TX_PROTOCOL}-${TX_USER}"
    if id "$TX_USER" >/dev/null 2>&1 && is_owned users "$TX_USER"; then
      userdel "$TX_USER" >/dev/null 2>&1
      rm -f "${MANAGED_USER_DIR}/${TX_USER}"
    fi
  fi
  case "$TX_PROTOCOL" in
    sftp) load_sftp_service; render_sshd_config >/dev/null 2>&1 ;;
    ftp) load_ftp_service; render_vsftpd_config >/dev/null 2>&1 ;;
    webdav)
      [ -z "$TX_SHARE" ] || refresh_webdav_share "$TX_SHARE" >/dev/null 2>&1
      [ -z "$TX_SECOND_SHARE" ] || [ "$TX_SECOND_SHARE" = "$TX_SHARE" ] || refresh_webdav_share "$TX_SECOND_SHARE" >/dev/null 2>&1
      ;;
  esac
  [ -z "${TX_DIR:-}" ] || rm -rf "$TX_DIR"
  set -e
  exit "$status"
}

save_account() {
  local protocol="$1" name="$2" file temp
  shift 2
  file="$(account_file "$protocol" "$name")"
  temp="$(mktemp)"
  while [ "$#" -gt 0 ]; do
    printf '%s=%q\n' "$1" "$2" >> "$temp"
    shift 2
  done
  atomic_install "$temp" "$file" 600
  rm -f "$temp"
}

load_account() {
  local file
  file="$(account_file "$1" "$2")"
  [ -f "$file" ] || die "账户不存在: $2"
  unset USER GROUP SHARE CHROOT DATA_DIR AUTH_MODE ROOT PORT TEMPORARY EXPIRES_AT
  # shellcheck disable=SC1090
  . "$file"
}

account_expired() {
  local expires_at="${1:-0}"
  [[ "$expires_at" =~ ^[0-9]+$ ]] && [ "$expires_at" -gt 0 ] && [ "$(date +%s)" -ge "$expires_at" ]
}

account_active() {
  ! account_expired "${EXPIRES_AT:-0}"
}

list_accounts() {
  local protocol="$1" file found=0
  for file in "${ACCOUNT_DIR}/${protocol}"/*.env; do
    [ -e "$file" ] || continue
    basename "$file" .env
    found=1
  done
  [ "$found" -eq 1 ]
}

random_hex() {
  od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

generate_temp_username() {
  local protocol="$1" user
  while true; do
    user="tmp_${protocol}_$(random_hex 4)"
    if ! id "$user" >/dev/null 2>&1 &&
      [ ! -f "$(account_file ftp "$user")" ] &&
      [ ! -f "$(account_file sftp "$user")" ] &&
      [ ! -f "$(account_file webdav "$user")" ]; then
      printf '%s' "$user"
      return
    fi
  done
}

generate_temp_password() {
  printf 'T%s!%s' "$(random_hex 8)" "$(random_hex 4)"
}

set_password_value() {
  local user="$1" password="$2" status
  printf '%s:%s\n' "$user" "$password" | chpasswd
  status="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
  [[ "$status" = P* ]] || die "账户 $user 的密码设置失败或账户仍被锁定。"
}

prompt_temp_expiry() {
  local minutes
  minutes="$(prompt "临时账户有效分钟数" "60")"
  [[ "$minutes" =~ ^[0-9]+$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 525600 ] ||
    die "有效期必须是 1-525600 分钟。"
  printf '%s' "$(($(date +%s) + minutes * 60))"
}

format_expiry() {
  date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'
}

server_address() {
  local address=""
  if command_exists ip; then
    address="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  fi
  [ -n "$address" ] || address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${address:-127.0.0.1}"
}

webdav_scheme() {
  [ "$WEBDAV_TLS" = 1 ] && printf https || printf http
}

install_expiry_timer() {
  local runner="${STATE_DIR}/${APP}.sh"
  install -o root -g root -m 700 "${BASH_SOURCE[0]}" "$runner"
  atomic_write_stdin "/etc/systemd/system/${EXPIRY_SERVICE}" 644 <<EOF
[Unit]
Description=Disable expired protocol-manager temporary accounts

[Service]
Type=oneshot
ExecStart=/bin/bash ${runner} expire
EOF
  atomic_write_stdin "/etc/systemd/system/${EXPIRY_TIMER}" 644 <<EOF
[Unit]
Description=Check protocol-manager temporary account expiry

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$EXPIRY_TIMER" >/dev/null
}

list_share_accounts() {
  local share="$1" protocol account
  for protocol in ftp sftp webdav; do
    while IFS= read -r account; do
      (
        local account_share
        load_account "$protocol" "$account"
        case "$protocol" in
          ftp|webdav) account_share="${SHARE:-$(shared_name_from_dir "$ROOT")}" ;;
          sftp) account_share="${SHARE:-$(shared_name_from_dir "$DATA_DIR")}" ;;
        esac
        if [ "$account_share" = "$share" ]; then
          printf '%s:%s\n' "$protocol" "$USER"
        fi
      )
    done < <(list_accounts "$protocol" || true)
  done
}

list_managed_shares() {
  local protocol account
  for protocol in ftp sftp webdav; do
    while IFS= read -r account; do
      (
        load_account "$protocol" "$account"
        case "$protocol" in
          ftp|webdav) printf '%s\n' "${SHARE:-$(shared_name_from_dir "$ROOT")}" ;;
          sftp) printf '%s\n' "${SHARE:-$(shared_name_from_dir "$DATA_DIR")}" ;;
        esac
      )
    done < <(list_accounts "$protocol" || true)
  done | sort -u
}

announce_shared_instance() {
  local share="$1" accounts
  accounts="$(list_share_accounts "$share" | paste -sd ',' - || true)"
  if [ -n "$accounts" ]; then
    warn "共享实例 ${share} 已有账户: ${accounts}；新账户将访问同一目录。"
  else
    log "将创建共享实例: ${share}"
  fi
}

assert_port_free() {
  local port="$1" exclude_protocol="${2:-}" exclude_name="${3:-}" account used_port used_user used_share allow_listener=0
  if [ "$exclude_protocol" != "sftp" ] && [ -f "$SFTP_STATE" ] && list_accounts sftp >/dev/null 2>&1; then
    used_port="$(. "$SFTP_STATE"; printf '%s' "$SFTP_PORT")"
    [ "$port" != "$used_port" ] || die "端口 ${port} 已被 SFTP 服务使用。"
  elif [ "$exclude_protocol" = "sftp" ] && [ -f "$SFTP_STATE" ]; then
    used_port="$(. "$SFTP_STATE"; printf '%s' "$SFTP_PORT")"
    [ "$port" != "$used_port" ] || allow_listener=1
  fi
  if [ "$exclude_protocol" != "ftp" ] && [ -f "$FTP_STATE" ] && list_accounts ftp >/dev/null 2>&1; then
    used_port="$(. "$FTP_STATE"; printf '%s' "$FTP_PORT")"
    [ "$port" != "$used_port" ] || die "端口 ${port} 已被 FTP 服务使用。"
  elif [ "$exclude_protocol" = "ftp" ] && [ -f "$FTP_STATE" ]; then
    used_port="$(. "$FTP_STATE"; printf '%s' "$FTP_PORT")"
    [ "$port" != "$used_port" ] || allow_listener=1
  fi
  while IFS= read -r account; do
    used_port="$(. "$(account_file webdav "$account")"; printf '%s' "$PORT")"
    used_user="$(. "$(account_file webdav "$account")"; printf '%s' "$USER")"
    used_share="$(. "$(account_file webdav "$account")"; printf '%s' "${SHARE:-$(shared_name_from_dir "$ROOT")}")"
    [ "$exclude_protocol" = "webdav" ] && [ "$used_share" = "$exclude_name" ] && continue
    [ "$port" != "$used_port" ] || die "端口 ${port} 已被 WebDAV 共享实例 ${used_share} 使用。"
  done < <(list_accounts webdav || true)
  if [ "$allow_listener" -eq 0 ] && command_exists ss; then
    if [ "$exclude_protocol" = sftp ] && ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -q sshd; then
      allow_listener=1
    elif [ "$exclude_protocol" = ftp ] && ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -q vsftpd; then
      allow_listener=1
    fi
  fi
  if [ "$allow_listener" -eq 0 ] && command_exists ss &&
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
    die "端口 ${port} 已被系统中的其他监听进程占用。"
  fi
}

choose_account() {
  local protocol="$1" accounts=() item
  while IFS= read -r item; do accounts+=("$item"); done < <(list_accounts "$protocol" || true)
  [ "${#accounts[@]}" -gt 0 ] || die "${protocol} 暂无账户。"
  select_menu "请选择 ${protocol^^} 账户" "${accounts[@]}"
}

install_packages() {
  local packages=("$@")
  if [ "$FAMILY" = "debian" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  else
    "$PKG" install -y "${packages[@]}"
  fi
}

replace_config_and_restart() {
  local candidate="$1" target="$2" service="$3" validator="${4:-}" backup=""
  [ -f "$target" ] && { backup="$(mktemp)"; cp -a "$target" "$backup"; }
  atomic_install "$candidate" "$target" 600
  if { [ -z "$validator" ] || bash -c "$validator"; } && systemctl restart "$service" &&
    systemctl is-active --quiet "$service"; then
    [ -z "$backup" ] || rm -f "$backup"
    return
  fi
  warn "配置验证或服务重启失败，正在恢复 ${target}。"
  if [ -n "$backup" ]; then
    atomic_install "$backup" "$target" "$(stat -c %a "$backup")" "$(stat -c %U "$backup")" "$(stat -c %G "$backup")"
  else
    rm -f "$target"
  fi
  systemctl restart "$service" >/dev/null 2>&1 || true
  [ -z "$backup" ] || rm -f "$backup"
  die "配置应用失败，已回滚: ${target}"
}

ensure_tls_certificate() {
  local cert="${TLS_DIR}/server.crt" key="${TLS_DIR}/server.key" temp_dir hostname_value address
  [ -s "$cert" ] && [ -s "$key" ] && return
  command_exists openssl || install_packages openssl
  temp_dir="$(mktemp -d)"
  hostname_value="$(hostname -f 2>/dev/null || hostname)"
  address="$(server_address)"
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -subj "/CN=${hostname_value}" -addext "subjectAltName=DNS:${hostname_value},IP:${address}" \
    -keyout "${temp_dir}/server.key" -out "${temp_dir}/server.crt" >/dev/null 2>&1
  install -o root -g root -m 600 "${temp_dir}/server.key" "$key"
  install -o root -g root -m 644 "${temp_dir}/server.crt" "$cert"
  rm -rf "$temp_dir"
  warn "已生成本地自签名 TLS 证书；生产公网环境建议替换为受信任证书。"
}

selinux_active() {
  command_exists getenforce && [ "$(getenforce 2>/dev/null)" != Disabled ]
}

ensure_semanage() {
  command_exists semanage && return
  [ "$FAMILY" = rhel ] || return
  install_packages policycoreutils-python-utils
}

configure_selinux_port() {
  local type="$1" port="$2"
  selinux_active || return 0
  ensure_semanage
  semanage port -a -t "$type" -p tcp "$port" 2>/dev/null ||
    semanage port -m -t "$type" -p tcp "$port" ||
    die "无法配置 SELinux 端口类型 ${type}: ${port}/tcp。"
}

configure_selinux_shared_root() {
  selinux_active || return 0
  ensure_semanage
  semanage fcontext -a -t public_content_rw_t "${SHARED_ROOT}(/.*)?" 2>/dev/null ||
    semanage fcontext -m -t public_content_rw_t "${SHARED_ROOT}(/.*)?" ||
    die "无法配置共享目录 SELinux 上下文。"
  restorecon -RF "$SHARED_ROOT" >/dev/null || die "无法应用共享目录 SELinux 上下文。"
  setsebool -P httpd_unified 1 >/dev/null || die "无法启用 WebDAV 所需 SELinux 布尔值。"
  setsebool -P ftpd_full_access 1 >/dev/null || die "无法启用 FTP 所需 SELinux 布尔值。"
  if getsebool -a 2>/dev/null | grep -q '^ssh_chroot_rw_homedirs'; then
    setsebool -P ssh_chroot_rw_homedirs 1 >/dev/null || die "无法启用 SFTP chroot 写入所需 SELinux 布尔值。"
  fi
}

configure_selinux_webdav_state() {
  selinux_active || return 0
  ensure_semanage
  semanage fcontext -a -t httpd_config_t "${STATE_DIR}/webdav.*" 2>/dev/null ||
    semanage fcontext -m -t httpd_config_t "${STATE_DIR}/webdav.*" ||
    die "无法配置 WebDAV 认证文件 SELinux 上下文。"
  semanage fcontext -a -t cert_t "${TLS_DIR}(/.*)?" 2>/dev/null ||
    semanage fcontext -m -t cert_t "${TLS_DIR}(/.*)?" ||
    die "无法配置 TLS 证书 SELinux 上下文。"
  restorecon -RF "$WEBDAV_USER_AUTH_DIR" "$TLS_DIR" >/dev/null ||
    die "无法应用 WebDAV/TLS SELinux 上下文。"
}

set_firewall_port() {
  local action="$1" port="$2"
  if command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    if ! firewall-cmd --permanent "--${action}-port=${port}/tcp" >/dev/null; then
      [ "$action" = remove ] && warn "firewalld 未移除端口 ${port}/tcp，规则可能原本不存在。" ||
        die "firewalld 无法开放端口 ${port}/tcp。"
    fi
    firewall-cmd --reload >/dev/null || die "firewalld 重载失败。"
  elif command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ "$action" = "add" ]; then
      ufw allow "${port}/tcp" || die "UFW 无法开放端口 ${port}/tcp。"
    else
      ufw --force delete allow "${port}/tcp" ||
        warn "UFW 未移除端口 ${port}/tcp，规则可能原本不存在。"
    fi
  fi
}

set_ftp_passive_firewall() {
  local action="$1"
  if command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    if ! firewall-cmd --permanent "--${action}-port=40000-40100/tcp" >/dev/null; then
      [ "$action" = remove ] && warn "firewalld 未移除 FTP 被动端口范围，规则可能原本不存在。" ||
        die "firewalld 无法开放 FTP 被动端口范围。"
    fi
    firewall-cmd --reload >/dev/null || die "firewalld 重载失败。"
  elif command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ "$action" = "add" ]; then
      ufw allow 40000:40100/tcp || die "UFW 无法开放 FTP 被动端口范围。"
    else
      ufw --force delete allow 40000:40100/tcp ||
        warn "UFW 未移除 FTP 被动端口范围，规则可能原本不存在。"
    fi
  fi
}

get_nologin() {
  [ -x /usr/sbin/nologin ] && { printf /usr/sbin/nologin; return; }
  [ -x /sbin/nologin ] && { printf /sbin/nologin; return; }
  printf /bin/false
}

ensure_user() {
  local user="$1" group="$2" home="$3" shell="$4"
  if id "$user" >/dev/null 2>&1 && ! is_managed users "$user"; then
    die "系统用户 ${user} 已存在且不归本脚本管理，拒绝接管。请使用其他登录名。"
  fi
  if ! getent group "$group" >/dev/null; then
    groupadd --system "$group"
    mark_owned groups "$group"
  fi
  if id "$user" >/dev/null 2>&1; then
    usermod -g "$group" -d "$home" -s "$shell" "$user"
  else
    useradd --system --gid "$group" --home-dir "$home" --shell "$shell" "$user"
    mark_owned users "$user"
  fi
}

remove_user_and_group() {
  local user="$1" group="$2" protocol="$3" other entry gid members

  for other in ftp sftp; do
    [ "$other" = "$protocol" ] && continue
    if [ -f "$(account_file "$other" "$user")" ]; then
      warn "用户 ${user} 仍被 ${other^^} 使用，已保留。"
      return
    fi
  done

  if id "$user" >/dev/null 2>&1 && ! is_owned users "$user"; then
    warn "用户 ${user} 不归本脚本管理，已保留。"
    return
  fi
  if id "$user" >/dev/null 2>&1 && ! userdel "$user" >/dev/null 2>&1; then
    die "无法删除用户: $user"
  fi
  rm -f "${MANAGED_USER_DIR}/${user}"

  entry="$(getent group "$group" || true)"
  [ -n "$entry" ] || return 0
  IFS=: read -r _ _ gid members _ <<< "${entry}:"
  if getent passwd | awk -F: -v gid="$gid" '$4 == gid { found=1 } END { exit !found }'; then
    warn "用户组 ${group} 仍被其他用户作为主组使用，已保留。"
  elif [ -n "$members" ]; then
    warn "用户组 ${group} 仍有成员，已保留。"
  elif ! is_owned groups "$group"; then
    warn "用户组 ${group} 不归本脚本管理，已保留。"
  elif ! groupdel "$group" >/dev/null 2>&1; then
    warn "无法删除用户组 ${group}，已保留。"
  else
    rm -f "${MANAGED_GROUP_DIR}/${group}"
  fi
}

assert_login_name_free() {
  local user="$1" protocol="$2" other
  for other in ftp sftp webdav; do
    [ "$other" = "$protocol" ] && continue
    [ ! -f "$(account_file "$other" "$user")" ] ||
      die "登录名 ${user} 已被 ${other^^} 使用；不同协议必须使用不同登录名。"
  done
}

write_password() {
  local password
  password="$(read_password "请输入账户 $1 的密码: ")"
  set_password_value "$1" "$password"
}

lock_password() {
  passwd -l "$1" >/dev/null 2>&1 || true
  passwd -S "$1" 2>/dev/null | awk '$2 ~ /^L/ { found=1 } END { exit !found }' ||
    die "账户 $1 锁定失败。"
}

# SFTP
set_random_password() {
  printf '%s:%s\n' "$1" "$(head -c 48 /dev/urandom | base64)" | chpasswd
}

validate_chroot_permissions() {
  local path="$1" current="/" owner mode part
  local -a parts
  IFS=/ read -ra parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    current="${current%/}/${part}"
    owner="$(stat -c %U "$current")"
    mode="$(stat -c %A "$current")"
    [ "$owner" = root ] && [[ "${mode:5:1}${mode:8:1}" != *w* ]] ||
      die "SFTP chroot 路径不安全: ${current} 必须由 root 拥有，且组和其他用户不可写。"
  done
}

prepare_chroot() {
  local path="$1"
  [[ "$path" = "$SHARED_ROOT"/* ]] || die "SFTP chroot 必须位于 ${SHARED_ROOT} 内。"
  mkdir -p "$SHARED_ROOT" "$path"
  chown root:root "$SHARED_ROOT"; chmod 755 "$SHARED_ROOT"
  chown root:root "$path"; chmod 755 "$path"
  validate_chroot_permissions "$path"
}

share_group_name() {
  local share="$1" checksum
  if command_exists sha256sum; then
    checksum="$(printf '%s' "$share" | sha256sum | cut -c1-16)"
  else
    checksum="$(printf '%s' "$share" | cksum | awk '{print $1}')"
  fi
  printf 'spm_%s' "$checksum"
}

detach_other_share_groups() {
  local user="$1" keep="$2" marker group
  [ "$user" != "$APACHE_USER" ] || return 0
  for marker in "${MANAGED_GROUP_DIR}"/spm_*; do
    [ -e "$marker" ] || continue
    group="$(basename "$marker")"
    [ "$group" = "$keep" ] || gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
  done
  if getent group "$SHARED_GROUP" >/dev/null 2>&1; then
    gpasswd -d "$user" "$SHARED_GROUP" >/dev/null 2>&1 || true
  fi
}

prepare_shared_dir() {
  local user="$1" path="$2" chroot share share_group
  chroot="${path%/files}"
  validate_shared_dir "$path" "$chroot"
  command_exists setfacl || install_packages acl
  share="$(shared_name_from_dir "$path")"
  share_group="$(share_group_name "$share")"
  if ! getent group "$share_group" >/dev/null; then
    groupadd --system "$share_group"
    mark_owned groups "$share_group"
  fi
  prepare_chroot "$chroot"
  mkdir -p "$path"
  if getent group "$SHARED_GROUP" >/dev/null 2>&1; then
    setfacl -R -x "g:${SHARED_GROUP}" "$path" 2>/dev/null || true
    find "$path" -type d -exec setfacl -x "d:g:${SHARED_GROUP}" {} + 2>/dev/null || true
  fi
  chgrp -R "$share_group" "$path"; chmod -R g+rwX,o-rwx "$path"; chmod 2770 "$path"
  find "$path" -type d -exec setfacl -m "g:${share_group}:rwx,d:g:${share_group}:rwx,d:m:rwx" {} +
  if [ -n "$user" ]; then
    detach_other_share_groups "$user" "$share_group"
    usermod -aG "$share_group" "$user"
  fi
  configure_selinux_shared_root
}

load_sftp_service() {
  SFTP_PORT=22
  [ -f "$SFTP_STATE" ] && . "$SFTP_STATE"
  return 0
}

save_sftp_service() {
  atomic_write_stdin "$SFTP_STATE" 600 <<EOF
SFTP_PORT=$(printf %q "$SFTP_PORT")
EOF
}

valid_public_key() {
  [[ "$1" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

set_authorized_key() {
  local user="$1" key="$2" file temp key_type
  file="${AUTHORIZED_KEYS_DIR}/${user}"
  valid_public_key "$key" || die "不是有效的 OpenSSH 公钥。"
  temp="$(mktemp)"
  printf '%s\n' "$key" > "$temp"
  if ! ssh-keygen -lf "$temp" >/dev/null 2>&1; then
    rm -f "$temp"
    die "公钥内容无法被 ssh-keygen 解析。"
  fi
  mkdir -p "$AUTHORIZED_KEYS_DIR"
  chown root:root "$AUTHORIZED_KEYS_DIR"
  chmod 755 "$AUTHORIZED_KEYS_DIR"
  install -o root -g root -m 644 "$temp" "$file"
  rm -f "$temp"
  command_exists restorecon && restorecon -RF "$AUTHORIZED_KEYS_DIR" >/dev/null 2>&1 || true
  key_type="${key%%[[:space:]]*}"
  [ "$key_type" != ssh-rsa ] ||
    warn "检测到 RSA 公钥，将仅为用户 ${user} 启用旧版 ssh-rsa 客户端兼容。建议改用 Ed25519 密钥。"
  log "SFTP 公钥指纹: $(ssh-keygen -lf "$file" | awk '{print $2, $4}')"
}

authorized_key_type() {
  local file="${AUTHORIZED_KEYS_DIR}/$1" key_type=""
  [ -s "$file" ] && read -r key_type _ < "$file"
  printf '%s' "$key_type"
}

set_sftp_auth() {
  local user="$1" mode="$2" key=""
  case "$mode" in
    password)
      rm -f "${AUTHORIZED_KEYS_DIR}/${user}"
      write_password "$user"
      ;;
    key)
      printf '请粘贴一行 SSH 公钥: ' >&2; read -r key
      set_authorized_key "$user" "$key"
      set_random_password "$user"
      ;;
    mixed)
      printf '请粘贴一行 SSH 公钥: ' >&2; read -r key
      set_authorized_key "$user" "$key"
      write_password "$user"
      ;;
    *) die "无效登录方式。" ;;
  esac
}

validate_sftp_account() {
  local user="$1" chroot="$2" mode="$3" effective key_file key_type password_status auth_methods
  effective="$(sshd -T -C "user=${user},host=localhost,addr=127.0.0.1")"
  password_status="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
  auth_methods="$(awk '$1 == "authenticationmethods" {print $2}' <<< "$effective")"
  [[ "$password_status" = P* ]] || die "SFTP 用户 ${user} 的系统账户仍处于锁定状态。"
  [ "$auth_methods" = any ] ||
    die "SFTP 用户 ${user} 的 AuthenticationMethods=${auth_methods}，会阻止独立使用密码或密钥登录。"
  grep -qxF "chrootdirectory ${chroot}" <<< "$effective" ||
    die "SFTP 用户 ${user} 的 chroot 配置未生效。"
  grep -qxF 'forcecommand internal-sftp -d /files -u 0002' <<< "$effective" ||
    die "SFTP 用户 ${user} 的 internal-sftp 配置未生效。"
  case "$mode" in
    password)
      grep -qxF 'passwordauthentication yes' <<< "$effective" ||
        die "SFTP 用户 ${user} 的密码认证未生效。"
      grep -qxF 'pubkeyauthentication no' <<< "$effective" ||
        die "SFTP 用户 ${user} 未正确禁用公钥认证。"
      ;;
    key)
      key_file="${AUTHORIZED_KEYS_DIR}/${user}"
      key_type="$(authorized_key_type "$user")"
      [ -s "$key_file" ] || die "SFTP 用户 ${user} 缺少公钥。"
      [ "$(stat -c '%U:%G %a' "$key_file")" = 'root:root 644' ] ||
        die "SFTP 用户 ${user} 的公钥文件权限不安全。"
      runuser -u "$user" -- test -r "$key_file" ||
        die "SFTP 用户 ${user} 无法读取公钥文件，请检查路径权限或 SELinux 策略。"
      ssh-keygen -lf "$key_file" >/dev/null 2>&1 || die "SFTP 用户 ${user} 的公钥无效。"
      grep -qxF 'pubkeyauthentication yes' <<< "$effective" ||
        die "SFTP 用户 ${user} 的公钥认证未生效。"
      grep -qxF "authorizedkeysfile ${key_file}" <<< "$effective" ||
        die "SFTP 用户 ${user} 的公钥路径未生效。"
      grep -qxF 'passwordauthentication no' <<< "$effective" ||
        die "SFTP 用户 ${user} 未正确禁用密码认证。"
      if [ "$key_type" = ssh-rsa ]; then
        grep -E '^pubkeyacceptedalgorithms .*ssh-rsa' <<< "$effective" >/dev/null ||
          die "SFTP 用户 ${user} 的旧版 RSA 客户端兼容未生效。"
      fi
      ;;
    mixed)
      key_file="${AUTHORIZED_KEYS_DIR}/${user}"
      key_type="$(authorized_key_type "$user")"
      [ -s "$key_file" ] || die "SFTP 用户 ${user} 缺少公钥。"
      [ "$(stat -c '%U:%G %a' "$key_file")" = 'root:root 644' ] ||
        die "SFTP 用户 ${user} 的公钥文件权限不安全。"
      runuser -u "$user" -- test -r "$key_file" ||
        die "SFTP 用户 ${user} 无法读取公钥文件，请检查路径权限或 SELinux 策略。"
      ssh-keygen -lf "$key_file" >/dev/null 2>&1 || die "SFTP 用户 ${user} 的公钥无效。"
      grep -qxF 'pubkeyauthentication yes' <<< "$effective" ||
        die "SFTP 用户 ${user} 的公钥认证未生效。"
      grep -qxF 'passwordauthentication yes' <<< "$effective" ||
        die "SFTP 用户 ${user} 的密码认证未生效。"
      grep -qxF "authorizedkeysfile ${key_file}" <<< "$effective" ||
        die "SFTP 用户 ${user} 的公钥路径未生效。"
      if [ "$key_type" = ssh-rsa ]; then
        grep -E '^pubkeyacceptedalgorithms .*ssh-rsa' <<< "$effective" >/dev/null ||
          die "SFTP 用户 ${user} 的旧版 RSA 客户端兼容未生效。"
      fi
      ;;
  esac
}

choose_sftp_auth_mode() {
  local choice
  choice="$(select_menu "选择 SFTP 登录方式" "仅密钥登录" "仅密码登录" "混合登录")"
  case "$choice" in
    "仅密码登录") printf password ;;
    "仅密钥登录") printf key ;;
    "混合登录") printf mixed ;;
  esac
}

render_sshd_config() {
  local config="/etc/ssh/sshd_config" clean block temp account start_dir key_type
  clean="$(mktemp)"
  block="$(mktemp)"
  temp="$(mktemp)"
  awk -v begin="$SSH_BEGIN" -v end="$SSH_END" '
    $0 == begin {skip=1; next} $0 == end {skip=0; next} skip != 1 {print}
  ' "$config" > "$clean"
  {
    printf '%s\nPort %s\n' "$SSH_BEGIN" "$SFTP_PORT"
    while IFS= read -r account; do
      load_account sftp "$account"
      account_active || continue
      start_dir="${DATA_DIR#"$CHROOT"}"
      printf '\nMatch User %s\n' "$USER"
      printf '    ChrootDirectory %s\n    ForceCommand internal-sftp -d %s -u 0002\n' "$CHROOT" "$start_dir"
      printf '    AuthorizedKeysFile %s/%s\n' "$AUTHORIZED_KEYS_DIR" "$USER"
      key_type="$(authorized_key_type "$USER")"
      [ "$key_type" != ssh-rsa ] || printf '    PubkeyAcceptedAlgorithms +ssh-rsa\n'
      case "$AUTH_MODE" in
        password) printf '    PasswordAuthentication yes\n    KbdInteractiveAuthentication yes\n    PubkeyAuthentication no\n' ;;
        key) printf '    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    PubkeyAuthentication yes\n' ;;
        mixed) printf '    PasswordAuthentication yes\n    KbdInteractiveAuthentication yes\n    PubkeyAuthentication yes\n' ;;
      esac
      printf '    X11Forwarding no\n    AllowTcpForwarding no\n    PermitTunnel no\n'
    done < <(list_accounts sftp || true)
    printf '%s\n' "$SSH_END"
  } > "$block"
  awk -v block="$block" '
    function emit() { while ((getline line < block) > 0) print line; close(block) }
    inserted != 1 && /^Match[[:space:]]/ { emit(); print ""; inserted=1 }
    { print }
    END { if (inserted != 1) { print ""; emit() } }
  ' "$clean" > "$temp"
  mkdir -p /run/sshd
  chmod 755 /run/sshd
  sshd -t -f "$temp" || { rm -f "$clean" "$block" "$temp"; die "生成的 SSH 配置验证失败，未修改现有配置。"; }
  systemctl enable "$SSH_SERVICE" >/dev/null
  replace_config_and_restart "$temp" "$config" "$SSH_SERVICE" "sshd -t"
  rm -f "$clean" "$block" "$temp"
  while IFS= read -r account; do
    load_account sftp "$account"
    account_active || continue
    validate_sftp_account "$USER" "$CHROOT" "$AUTH_MODE"
  done < <(list_accounts sftp || true)
}

remove_sshd_managed_config() {
  local config="/etc/ssh/sshd_config" temp
  [ -f "$config" ] || return 0
  temp="$(mktemp)"
  awk -v begin="$SSH_BEGIN" -v end="$SSH_END" '
    $0 == begin {skip=1; next} $0 == end {skip=0; next} skip != 1 {print}
  ' "$config" > "$temp"
  sshd -t -f "$temp" || { rm -f "$temp"; die "移除托管 SSH 配置后的候选配置无效。"; }
  systemctl enable "$SSH_SERVICE" >/dev/null
  replace_config_and_restart "$temp" "$config" "$SSH_SERVICE" "sshd -t"
  rm -f "$temp"
}

add_sftp() {
  local share="${1:-}" user group chroot data mode default_user="sftpuser"
  install_packages openssh-server acl
  load_sftp_service
  [ -z "$share" ] || { validate_name "$share"; default_user="sftp_${share}"; }
  user="$(prompt "SFTP 登录名" "$default_user")"; validate_name "$user"
  [ ! -f "$(account_file sftp "$user")" ] || die "账户已存在: $user"
  assert_login_name_free "$user" sftp
  group="$(prompt "SFTP 用户组" "sftpusers")"; validate_name "$group"
  [ -n "$share" ] || { share="$(prompt "共享实例名称" "$user")"; validate_name "$share"; }
  announce_shared_instance "$share"
  if list_accounts sftp >/dev/null 2>&1; then
    log "SFTP 多账户共享服务端口: ${SFTP_PORT}"
  else
    SFTP_PORT="$(prompt "SFTP 服务端口" "$SFTP_PORT")"; validate_port "$SFTP_PORT"; assert_port_free "$SFTP_PORT" sftp
  fi
  chroot="$(account_chroot "$share")"
  data="$(account_shared_dir "$share")"
  mode="$(choose_sftp_auth_mode)"
  begin_account_transaction sftp "$user" "$group" "$share"
  ensure_user "$user" "$group" /nonexistent "$(get_nologin)"
  prepare_shared_dir "$user" "$data"
  set_sftp_auth "$user" "$mode"
  save_account sftp "$user" USER "$user" GROUP "$group" SHARE "$share" CHROOT "$chroot" DATA_DIR "$data" AUTH_MODE "$mode"
  save_sftp_service
  configure_selinux_port ssh_port_t "$SFTP_PORT"
  render_sshd_config
  set_firewall_port add "$SFTP_PORT"
  commit_account_transaction
  log "SFTP 账户已新增: $user"
}

modify_sftp() {
  local account group share chroot data old_port new_port
  account="$(choose_account sftp)"; load_account sftp "$account"; load_sftp_service
  old_port="$SFTP_PORT"
  warn "SFTP 端口由全部 SFTP 账户共享。"
  new_port="$(prompt "SFTP 服务端口" "$SFTP_PORT")"; validate_port "$new_port"; assert_port_free "$new_port" sftp
  group="$(prompt "用户组" "$GROUP")"; validate_name "$group"
  share="$(prompt "共享实例名称" "${SHARE:-$(shared_name_from_dir "$DATA_DIR")}")"; validate_name "$share"
  announce_shared_instance "$share"
  chroot="$(account_chroot "$share")"
  data="$(account_shared_dir "$share")"
  begin_account_update sftp "$USER" "$share"
  ensure_user "$USER" "$group" /nonexistent "$(get_nologin)"
  prepare_shared_dir "$USER" "$data"
  save_account sftp "$USER" USER "$USER" GROUP "$group" SHARE "$share" CHROOT "$chroot" DATA_DIR "$data" AUTH_MODE "$AUTH_MODE" TEMPORARY "${TEMPORARY:-0}" EXPIRES_AT "${EXPIRES_AT:-0}"
  SFTP_PORT="$new_port"; save_sftp_service
  configure_selinux_port ssh_port_t "$SFTP_PORT"
  render_sshd_config
  [ "$old_port" = "$new_port" ] || { set_firewall_port remove "$old_port"; set_firewall_port add "$new_port"; }
  commit_account_transaction
  log "SFTP 配置已更新: $USER"
}

manage_sftp_auth() {
  local account share chroot data mode
  account="$(choose_account sftp)"; load_account sftp "$account"
  share="${SHARE:-$(shared_name_from_dir "$DATA_DIR")}"
  chroot="$(account_chroot "$share")"
  data="$(account_shared_dir "$share")"
  mode="$(choose_sftp_auth_mode)"
  begin_account_update sftp "$USER" "$share"
  ensure_user "$USER" "$GROUP" /nonexistent "$(get_nologin)"
  prepare_shared_dir "$USER" "$data"
  set_sftp_auth "$USER" "$mode"
  save_account sftp "$USER" USER "$USER" GROUP "$GROUP" SHARE "$share" CHROOT "$chroot" DATA_DIR "$data" AUTH_MODE "$mode" TEMPORARY "${TEMPORARY:-0}" EXPIRES_AT "${EXPIRES_AT:-0}"
  load_sftp_service; render_sshd_config
  commit_account_transaction
  log "SFTP 登录方式已更新: $USER"
}

purge_sftp_account() {
  local account
  account="$(choose_account sftp)"; load_account sftp "$account"
  confirm "确认 purge SFTP 账户 ${USER}？数据目录会保留。" || return
  remove_user_and_group "$USER" "$GROUP" sftp
  rm -f "${AUTHORIZED_KEYS_DIR}/${USER}"
  rm -f "$(account_file sftp "$account")" "${STATE_DIR}/expired/sftp-${account}"
  load_sftp_service
  if list_accounts sftp >/dev/null 2>&1; then
    render_sshd_config
  else
    remove_sshd_managed_config
    set_firewall_port remove "$SFTP_PORT"
    rm -f "$SFTP_STATE"
  fi
  log "SFTP 账户已 purge，数据目录已保留: $DATA_DIR"
}

# FTP: 不支持 SSH 公钥。无密码账户会被锁定，设置密码后方可登录。
load_ftp_service() {
  FTP_PORT=21
  [ -f "$FTP_STATE" ] && . "$FTP_STATE"
  return 0
}

save_ftp_service() {
  atomic_write_stdin "$FTP_STATE" 600 <<EOF
FTP_PORT=$(printf %q "$FTP_PORT")
EOF
}

render_vsftpd_config() {
  local conf="/etc/vsftpd.conf" user_dir="${STATE_DIR}/vsftpd-users" userlist="${STATE_DIR}/vsftpd.userlist" account candidate list_temp entry_temp
  mkdir -p "$user_dir"
  list_temp="$(mktemp)"
  while IFS= read -r account; do
    load_account ftp "$account"
    account_active || continue
    ensure_user "$USER" "$GROUP" "$ROOT" "$(get_nologin)"
    printf '%s\n' "$USER" >> "$list_temp"
    entry_temp="$(mktemp)"
    printf 'local_root=%s\n' "$ROOT" > "$entry_temp"
    atomic_install "$entry_temp" "${user_dir}/${USER}" 600
    rm -f "$entry_temp"
  done < <(list_accounts ftp || true)
  atomic_install "$list_temp" "$userlist" 600
  rm -f "$list_temp"
  candidate="$(mktemp)"
  cat > "$candidate" <<EOF
listen=YES
listen_ipv6=NO
listen_port=${FTP_PORT}
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=002
chroot_local_user=YES
allow_writeable_chroot=YES
user_config_dir=${user_dir}
userlist_enable=YES
userlist_deny=NO
userlist_file=${userlist}
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
ssl_enable=NO
EOF
  capture_original_file "$conf" vsftpd.conf
  configure_selinux_port ftp_port_t "$FTP_PORT"
  configure_selinux_port ftp_port_t 40000-40100
  systemctl enable "$FTP_SERVICE" >/dev/null
  replace_config_and_restart "$candidate" "$conf" "$FTP_SERVICE"
  rm -f "$candidate"
}

add_ftp() {
  local share="${1:-}" user group root shell default_user="ftpuser"
  install_packages vsftpd acl
  load_ftp_service
  [ -z "$share" ] || { validate_name "$share"; default_user="ftp_${share}"; }
  user="$(prompt "FTP 登录名" "$default_user")"; validate_name "$user"
  [ ! -f "$(account_file ftp "$user")" ] || die "账户已存在: $user"
  assert_login_name_free "$user" ftp
  group="$(prompt "FTP 用户组" "ftpusers")"; validate_name "$group"
  [ -n "$share" ] || { share="$(prompt "共享实例名称" "$user")"; validate_name "$share"; }
  announce_shared_instance "$share"
  if list_accounts ftp >/dev/null 2>&1; then
    log "FTP 多账户共享服务端口: ${FTP_PORT}"
  else
    FTP_PORT="$(prompt "FTP 服务端口" "$FTP_PORT")"; validate_port "$FTP_PORT"; assert_port_free "$FTP_PORT" ftp
  fi
  root="$(account_shared_dir "$share")"
  shell="$(get_nologin)"; grep -qxF "$shell" /etc/shells 2>/dev/null || printf '%s\n' "$shell" >> /etc/shells
  begin_account_transaction ftp "$user" "$group" "$share"
  ensure_user "$user" "$group" "$root" "$shell"
  prepare_shared_dir "$user" "$root"
  lock_password "$user"
  save_account ftp "$user" USER "$user" GROUP "$group" SHARE "$share" ROOT "$root"
  save_ftp_service; render_vsftpd_config; set_firewall_port add "$FTP_PORT"
  set_ftp_passive_firewall add
  commit_account_transaction
  warn "注意：当前的 FTP 配置未开启加密，用户的密码和数据将在网络上明文传输。"
  warn "FTP 账户默认无密码且已锁定；请在“管理 FTP 密码”中设置密码后登录。"
}

modify_ftp() {
  local account group share root old_port new_port
  account="$(choose_account ftp)"; load_account ftp "$account"; load_ftp_service
  old_port="$FTP_PORT"
  warn "FTP 端口由全部 FTP 账户共享。"
  new_port="$(prompt "FTP 服务端口" "$FTP_PORT")"; validate_port "$new_port"; assert_port_free "$new_port" ftp
  group="$(prompt "FTP 用户组" "$GROUP")"; validate_name "$group"
  share="$(prompt "共享实例名称" "${SHARE:-$(shared_name_from_dir "$ROOT")}")"; validate_name "$share"
  announce_shared_instance "$share"
  root="$(account_shared_dir "$share")"
  begin_account_update ftp "$USER" "$share"
  ensure_user "$USER" "$group" "$root" "$(get_nologin)"
  prepare_shared_dir "$USER" "$root"
  save_account ftp "$USER" USER "$USER" GROUP "$group" SHARE "$share" ROOT "$root" TEMPORARY "${TEMPORARY:-0}" EXPIRES_AT "${EXPIRES_AT:-0}"
  FTP_PORT="$new_port"; save_ftp_service; render_vsftpd_config
  [ "$old_port" = "$new_port" ] || { set_firewall_port remove "$old_port"; set_firewall_port add "$new_port"; }
  commit_account_transaction
  log "FTP 配置已更新: $USER"
}

manage_ftp_password() {
  local account choice
  account="$(choose_account ftp)"; load_account ftp "$account"
  begin_account_update ftp "$USER" "${SHARE:-$(shared_name_from_dir "$ROOT")}"
  ensure_user "$USER" "$GROUP" "$ROOT" "$(get_nologin)"
  choice="$(select_menu "管理 FTP 密码: $USER" "重置 FTP 密码" "取消 FTP 密码并锁定登录")"
  case "$choice" in
    "重置 FTP 密码") write_password "$USER" ;;
    "取消 FTP 密码并锁定登录") lock_password "$USER" ;;
  esac
  load_ftp_service
  render_vsftpd_config
  commit_account_transaction
  log "FTP 密码状态已更新: $USER"
}

purge_ftp_account() {
  local account
  account="$(choose_account ftp)"; load_account ftp "$account"
  confirm "确认 purge FTP 账户 ${USER}？根目录会保留。" || return
  remove_user_and_group "$USER" "$GROUP" ftp
  rm -f "$(account_file ftp "$account")" "${STATE_DIR}/vsftpd-users/${USER}" "${STATE_DIR}/expired/ftp-${account}"
  load_ftp_service
  if list_accounts ftp >/dev/null 2>&1; then
    render_vsftpd_config
  else
    set_firewall_port remove "$FTP_PORT"
    set_ftp_passive_firewall remove
    rm -f "$FTP_STATE"
    restore_original_file /etc/vsftpd.conf vsftpd.conf
    if [ -f /etc/vsftpd.conf ]; then
      systemctl restart "$FTP_SERVICE" >/dev/null 2>&1 || warn "原始 vsftpd 配置已恢复，但服务重启失败。"
    else
      systemctl stop "$FTP_SERVICE" 2>/dev/null || true
    fi
  fi
  log "FTP 账户已 purge，根目录已保留: $ROOT"
}

# WebDAV: 每个共享实例使用一个端口和认证文件，多个账户可共用同一入口。
webdav_conf_file() {
  if [ "$FAMILY" = "debian" ]; then printf '/etc/apache2/sites-available/%s-webdav-%s.conf' "$APP" "$1"
  else printf '/etc/httpd/conf.d/%s-webdav-%s.conf' "$APP" "$1"; fi
}

webdav_auth_file() {
  printf '%s/webdav-%s.htpasswd' "$STATE_DIR" "$1"
}

webdav_user_auth_file() {
  printf '%s/%s.htpasswd' "$WEBDAV_USER_AUTH_DIR" "$1"
}

find_webdav_share_account() {
  local share="$1" account
  while IFS= read -r account; do
    (
      load_account webdav "$account"
      if [ "${SHARE:-$(shared_name_from_dir "$ROOT")}" = "$share" ] && account_active; then
        printf '%s\n' "$account"
      fi
    )
  done < <(list_accounts webdav || true)
}

first_webdav_share_account() {
  local account
  while IFS= read -r account; do
    printf '%s' "$account"
    return 0
  done < <(find_webdav_share_account "$1")
  return 1
}

webdav_share_port() {
  local account
  account="$(first_webdav_share_account "$1")"
  [ -n "$account" ] || return 1
  load_account webdav "$account"
  printf '%s' "$PORT"
}

normalize_webdav_share_port() {
  local share="$1" port="$2" account account_share
  while IFS= read -r account; do
    (
      load_account webdav "$account"
      account_share="${SHARE:-$(shared_name_from_dir "$ROOT")}"
      [ "$account_share" = "$share" ] || exit 0
      save_account webdav "$USER" USER "$USER" SHARE "$share" PORT "$port" ROOT "$ROOT" TEMPORARY "${TEMPORARY:-0}" EXPIRES_AT "${EXPIRES_AT:-0}"
    )
  done < <(list_accounts webdav || true)
}

render_webdav_share() {
  local share="$1" account conf auth lock port root legacy legacy_share candidate
  account="$(first_webdav_share_account "$share" || true)"
  conf="$(webdav_conf_file "$share")"
  while IFS= read -r legacy; do
    load_account webdav "$legacy"
    legacy_share="${SHARE:-$(shared_name_from_dir "$ROOT")}"
    if [ "$legacy_share" != "$share" ]; then continue; fi
    if [ "$USER" = "$share" ]; then continue; fi
    if list_managed_shares | grep -qxF "$USER"; then continue; fi
    if [ "$FAMILY" = "debian" ]; then a2dissite "$(basename "$(webdav_conf_file "$USER")")" >/dev/null 2>&1 || true; fi
    rm -f "$(webdav_conf_file "$USER")"
  done < <(list_accounts webdav || true)
  if [ -z "$account" ]; then
    [ "$FAMILY" = "debian" ] && a2dissite "$(basename "$conf")" >/dev/null 2>&1 || true
    rm -f "$conf"
    return
  fi
  load_account webdav "$account"
  port="$PORT"; root="$ROOT"; auth="$(webdav_auth_file "$share")"; lock="${STATE_DIR}/davlock"
  normalize_webdav_share_port "$share" "$port"
  prepare_shared_dir "$APACHE_USER" "$root"
  mkdir -p "$lock"; chown "$APACHE_USER:$APACHE_USER" "$lock"; chmod 750 "$lock"
  [ "$WEBDAV_TLS" != 1 ] || ensure_tls_certificate
  candidate="$(mktemp)"
  {
    cat <<EOF
DavLockDB ${lock}/DavLock
Listen ${port}
<VirtualHost *:${port}>
    ServerName localhost
EOF
    if [ "$WEBDAV_TLS" = 1 ]; then
      cat <<EOF
    SSLEngine on
    SSLCertificateFile "${TLS_DIR}/server.crt"
    SSLCertificateKeyFile "${TLS_DIR}/server.key"
EOF
    fi
    cat <<EOF
    DocumentRoot "${root}"
    <Directory "${root}">
        DAV On
        Options Indexes
        AuthType Basic
        AuthName "WebDAV"
        AuthUserFile "${auth}"
        Require valid-user
    </Directory>
</VirtualHost>
EOF
  } > "$candidate"
  atomic_install "$candidate" "$conf" 644
  rm -f "$candidate"
  if [ "$FAMILY" = "debian" ]; then
    a2ensite "$(basename "$conf")" >/dev/null
  fi
}

rebuild_webdav_auth_file() {
  local share="$1" account auth source legacy first=1 temp
  auth="$(webdav_auth_file "$share")"
  mkdir -p "$WEBDAV_USER_AUTH_DIR"; chmod 700 "$WEBDAV_USER_AUTH_DIR"
  while IFS= read -r account; do
    load_account webdav "$account"
    source="$(webdav_user_auth_file "$USER")"
    legacy="${STATE_DIR}/webdav-${USER}.htpasswd"
    [ -f "$source" ] || [ ! -f "$legacy" ] || install -o root -g "$APACHE_USER" -m 640 "$legacy" "$source"
  done < <(find_webdav_share_account "$share")
  temp="$(mktemp "${STATE_DIR}/.webdav_auth.XXXXXX")"
  while IFS= read -r account; do
    load_account webdav "$account"
    account_active || continue
    source="$(webdav_user_auth_file "$USER")"
    [ -f "$source" ] || continue
    if [ "$first" -eq 1 ]; then
      cp "$source" "$temp"; first=0
    else
      cat "$source" >> "$temp"
    fi
  done < <(find_webdav_share_account "$share")
  if [ "$first" -eq 0 ]; then
    atomic_install "$temp" "$auth" 640 root "$APACHE_USER"
  else
    rm -f "$auth"
  fi
  rm -f "$temp"
}

refresh_webdav_share() {
  local share="$1" conf backup=""
  conf="$(webdav_conf_file "$share")"
  [ -f "$conf" ] && { backup="$(mktemp)"; cp -a "$conf" "$backup"; }
  rebuild_webdav_auth_file "$share"
  render_webdav_share "$share"
  [ "$WEBDAV_TLS" != 1 ] || configure_selinux_webdav_state
  if apache_configtest && systemctl restart "$APACHE_SERVICE" && systemctl is-active --quiet "$APACHE_SERVICE"; then
    [ -z "$backup" ] || rm -f "$backup"
    return
  fi
  warn "WebDAV 配置验证或 Apache 重启失败，正在回滚共享实例 ${share}。"
  if [ -n "$backup" ]; then
    cp -a "$backup" "$conf"
    [ "$FAMILY" != debian ] || a2ensite "$(basename "$conf")" >/dev/null 2>&1
  else
    rm -f "$conf"
    [ "$FAMILY" != debian ] || a2dissite "$(basename "$conf")" >/dev/null 2>&1 || true
  fi
  systemctl restart "$APACHE_SERVICE" >/dev/null 2>&1 || true
  rm -f "$backup"
  die "WebDAV 配置应用失败，已回滚。"
}

repair_all_webdav_shares() {
  local account share
  while IFS= read -r share; do
    refresh_webdav_share "$share"
    log "WebDAV 配置已修复: ${share} -> $(webdav_scheme)://$(server_address):$(webdav_share_port "$share")/"
  done < <(
    while IFS= read -r account; do
      load_account webdav "$account"
      printf '%s\n' "${SHARE:-$(shared_name_from_dir "$ROOT")}"
    done < <(list_accounts webdav || true) | sort -u
  )
}

apache_configtest() {
  if [ "$FAMILY" = "debian" ]; then
    apache2ctl configtest
  else
    apachectl configtest
  fi
}

find_webdav_port() {
  local port
  for ((port=18080; port<=18999; port++)); do
    if ( assert_port_free "$port" ) >/dev/null 2>&1; then
      printf '%s' "$port"
      return
    fi
  done
  die "无法在 18080-18999 范围内找到可用 WebDAV 端口。"
}

write_webdav_password_file() {
  local auth="$1" user="$2" password="$3" temp
  temp="$(mktemp "${STATE_DIR}/.webdav_auth.XXXXXX")"
  printf '%s\n' "$password" | htpasswd -ci "$temp" "$user" >/dev/null ||
    { rm -f "$temp"; die "WebDAV 用户 ${user} 的认证文件创建失败。"; }
  printf '%s\n' "$password" | htpasswd -vi "$temp" "$user" >/dev/null ||
    { rm -f "$temp"; die "WebDAV 用户 ${user} 的认证文件校验失败。"; }
  atomic_install "$temp" "$auth" 640 root "$APACHE_USER"
  rm -f "$temp"
}

add_webdav() {
  local share="${1:-}" user port root auth password default_user="webdavuser" default_port
  if [ "$FAMILY" = "debian" ]; then
    install_packages apache2 apache2-utils acl
    a2enmod dav dav_fs auth_basic authn_file >/dev/null
    [ "$WEBDAV_TLS" != 1 ] || a2enmod ssl >/dev/null
  else
    install_packages httpd httpd-tools acl
    [ "$WEBDAV_TLS" != 1 ] || install_packages mod_ssl
  fi
  [ -z "$share" ] || { validate_name "$share"; default_user="webdav_${share}"; }
  user="$(prompt "WebDAV 登录名" "$default_user")"; validate_name "$user"
  [ ! -f "$(account_file webdav "$user")" ] || die "账户已存在: $user"
  assert_login_name_free "$user" webdav
  [ -n "$share" ] || { share="$(prompt "共享实例名称" "$user")"; validate_name "$share"; }
  announce_shared_instance "$share"
  if port="$(webdav_share_port "$share" 2>/dev/null)"; then
    log "WebDAV 共享实例 ${share} 复用端口: ${port}"
  else
    default_port="$(find_webdav_port)"
    port="$(prompt "WebDAV 共享实例端口" "$default_port")"; validate_port "$port"; assert_port_free "$port"
  fi
  root="$(account_shared_dir "$share")"
  password="$(read_password "请输入 WebDAV 用户 ${user} 的密码: ")"
  begin_account_transaction webdav "$user" "" "$share"
  auth="$(webdav_user_auth_file "$user")"; write_webdav_password_file "$auth" "$user" "$password"
  save_account webdav "$user" USER "$user" SHARE "$share" PORT "$port" ROOT "$root"
  configure_selinux_port http_port_t "$port"
  refresh_webdav_share "$share"; set_firewall_port add "$port"
  commit_account_transaction
  [ "$WEBDAV_TLS" = 1 ] || warn "注意：当前的 WebDAV 未开启 TLS 加密，将使用 Basic Auth 进行明文传输密码和数据。"
  log "WebDAV 账户已新增: $(webdav_scheme)://$(server_address):${port}/"
}

modify_webdav() {
  local account old_share old_port share port root
  account="$(choose_account webdav)"; load_account webdav "$account"
  old_share="${SHARE:-$(shared_name_from_dir "$ROOT")}"; old_port="$PORT"
  share="$(prompt "共享实例名称" "${SHARE:-$(shared_name_from_dir "$ROOT")}")"; validate_name "$share"
  announce_shared_instance "$share"
  if [ "$share" = "$old_share" ]; then
    port="$old_port"
  elif port="$(webdav_share_port "$share" 2>/dev/null)"; then
    log "WebDAV 共享实例 ${share} 复用端口: ${port}"
  else
    port="$(find_webdav_port)"
    port="$(prompt "WebDAV 共享实例端口" "$port")"; validate_port "$port"; assert_port_free "$port"
  fi
  root="$(account_shared_dir "$share")"
  begin_account_update webdav "$USER" "$old_share" "$share"
  save_account webdav "$USER" USER "$USER" SHARE "$share" PORT "$port" ROOT "$root" TEMPORARY "${TEMPORARY:-0}" EXPIRES_AT "${EXPIRES_AT:-0}"
  configure_selinux_port http_port_t "$port"
  refresh_webdav_share "$old_share"
  [ "$share" = "$old_share" ] || refresh_webdav_share "$share"
  if ! find_webdav_share_account "$old_share" | grep -q .; then set_firewall_port remove "$old_port"; fi
  set_firewall_port add "$port"
  commit_account_transaction
  log "WebDAV 配置已更新: $USER"
}

manage_webdav_password() {
  local account auth password share
  account="$(choose_account webdav)"; load_account webdav "$account"
  share="${SHARE:-$(shared_name_from_dir "$ROOT")}"
  password="$(read_password "请输入 WebDAV 用户 ${USER} 的新密码: ")"
  begin_account_update webdav "$USER" "$share"
  auth="$(webdav_user_auth_file "$USER")"
  write_webdav_password_file "$auth" "$USER" "$password"
  refresh_webdav_share "$share"
  commit_account_transaction
  log "WebDAV 密码已更新: $USER"
}

purge_webdav_account() {
  local account share port
  account="$(choose_account webdav)"; load_account webdav "$account"
  confirm "确认 purge WebDAV 账户 ${USER}？根目录会保留。" || return
  share="${SHARE:-$(shared_name_from_dir "$ROOT")}"; port="$PORT"
  rm -f "$(webdav_user_auth_file "$USER")" "${STATE_DIR}/webdav-${USER}.htpasswd" "$(account_file webdav "$account")" "${STATE_DIR}/expired/webdav-${account}"
  refresh_webdav_share "$share"
  if ! find_webdav_share_account "$share" | grep -q .; then set_firewall_port remove "$port"; fi
  log "WebDAV 账户已 purge，根目录已保留: $ROOT"
}

create_temp_sftp() {
  local share="$1" expires_at="$2" user password group="sftpusers" chroot data
  install_packages openssh-server acl
  load_sftp_service
  if ! list_accounts sftp >/dev/null 2>&1; then
    assert_port_free "$SFTP_PORT" sftp
  fi
  user="$(generate_temp_username sftp)"
  password="$(generate_temp_password)"
  chroot="$(account_chroot "$share")"; data="$(account_shared_dir "$share")"
  begin_account_transaction sftp "$user" "$group" "$share"
  ensure_user "$user" "$group" /nonexistent "$(get_nologin)"
  prepare_shared_dir "$user" "$data"
  set_password_value "$user" "$password"
  save_account sftp "$user" USER "$user" GROUP "$group" SHARE "$share" CHROOT "$chroot" DATA_DIR "$data" AUTH_MODE password TEMPORARY 1 EXPIRES_AT "$expires_at"
  save_sftp_service; configure_selinux_port ssh_port_t "$SFTP_PORT"; render_sshd_config; set_firewall_port add "$SFTP_PORT"
  commit_account_transaction
  printf 'SFTP 临时账户: %s\nSFTP 临时密码: %s\nSFTP 端口: %s\n' "$user" "$password" "$SFTP_PORT"
}

create_temp_ftp() {
  local share="$1" expires_at="$2" user password group="ftpusers" root shell
  install_packages vsftpd acl
  load_ftp_service
  if ! list_accounts ftp >/dev/null 2>&1; then
    assert_port_free "$FTP_PORT" ftp
  fi
  user="$(generate_temp_username ftp)"
  password="$(generate_temp_password)"
  root="$(account_shared_dir "$share")"
  shell="$(get_nologin)"; grep -qxF "$shell" /etc/shells 2>/dev/null || printf '%s\n' "$shell" >> /etc/shells
  begin_account_transaction ftp "$user" "$group" "$share"
  ensure_user "$user" "$group" "$root" "$shell"
  prepare_shared_dir "$user" "$root"
  set_password_value "$user" "$password"
  save_account ftp "$user" USER "$user" GROUP "$group" SHARE "$share" ROOT "$root" TEMPORARY 1 EXPIRES_AT "$expires_at"
  save_ftp_service; render_vsftpd_config; set_firewall_port add "$FTP_PORT"; set_ftp_passive_firewall add
  commit_account_transaction
  printf 'FTP 临时账户: %s\nFTP 临时密码: %s\nFTP 端口: %s\n' "$user" "$password" "$FTP_PORT"
}

create_temp_webdav() {
  local share="$1" expires_at="$2" user password port root auth
  if [ "$FAMILY" = "debian" ]; then
    install_packages apache2 apache2-utils acl
    a2enmod dav dav_fs auth_basic authn_file >/dev/null
    [ "$WEBDAV_TLS" != 1 ] || a2enmod ssl >/dev/null
  else
    install_packages httpd httpd-tools acl
    [ "$WEBDAV_TLS" != 1 ] || install_packages mod_ssl
  fi
  user="$(generate_temp_username webdav)"
  password="$(generate_temp_password)"
  port="$(webdav_share_port "$share" 2>/dev/null || find_webdav_port)"
  root="$(account_shared_dir "$share")"
  auth="$(webdav_user_auth_file "$user")"
  begin_account_transaction webdav "$user" "" "$share"
  write_webdav_password_file "$auth" "$user" "$password"
  save_account webdav "$user" USER "$user" SHARE "$share" PORT "$port" ROOT "$root" TEMPORARY 1 EXPIRES_AT "$expires_at"
  configure_selinux_port http_port_t "$port"
  refresh_webdav_share "$share"; set_firewall_port add "$port"
  commit_account_transaction
  printf 'WebDAV 临时账户: %s\nWebDAV 临时密码: %s\nWebDAV 地址: %s://%s:%s/\n' "$user" "$password" "$(webdav_scheme)" "$(server_address)" "$port"
}

create_temporary_account() {
  local protocol="${1:-}" choice share expires_at
  if [ -z "$protocol" ]; then
    choice="$(select_menu "添加临时账户" "FTP 临时账户" "SFTP 临时账户" "WebDAV 临时账户" "返回主菜单")"
    case "$choice" in
      "FTP 临时账户") protocol=ftp ;;
      "SFTP 临时账户") protocol=sftp ;;
      "WebDAV 临时账户") protocol=webdav ;;
      "返回主菜单") return ;;
    esac
  fi
  share="$(prompt "共享实例名称" "ba")"; validate_name "$share"
  announce_shared_instance "$share"
  expires_at="$(prompt_temp_expiry)"
  title "临时账户凭据"
  case "$protocol" in
    ftp) create_temp_ftp "$share" "$expires_at" ;;
    sftp) create_temp_sftp "$share" "$expires_at" ;;
    webdav) create_temp_webdav "$share" "$expires_at" ;;
    *) die "不支持的临时账户协议: $protocol" ;;
  esac
  install_expiry_timer
  printf '到期时间: %s\n' "$(format_expiry "$expires_at")"
  warn "请立即保存以上随机密码；脚本不会保存明文密码。"
}

expire_temporary_accounts() {
  local protocol account marker sftp_changed=0 ftp_changed=0 share port
  for protocol in sftp ftp webdav; do
    while IFS= read -r account; do
      marker="${STATE_DIR}/expired/${protocol}-${account}"
      [ ! -f "$marker" ] || continue
      load_account "$protocol" "$account"
      [ "${TEMPORARY:-0}" = 1 ] || continue
      account_expired "${EXPIRES_AT:-0}" || continue
      case "$protocol" in
        sftp)
          remove_user_and_group "$USER" "$GROUP" sftp; rm -f "${AUTHORIZED_KEYS_DIR}/${USER}" "$(account_file sftp "$account")"; sftp_changed=1
          ;;
        ftp)
          remove_user_and_group "$USER" "$GROUP" ftp; rm -f "$(account_file ftp "$account")" "${STATE_DIR}/vsftpd-users/${USER}"; ftp_changed=1
          ;;
        webdav)
          share="${SHARE:-$(shared_name_from_dir "$ROOT")}"; port="$PORT"
          rm -f "$(webdav_user_auth_file "$USER")" "${STATE_DIR}/webdav-${USER}.htpasswd" "$(account_file webdav "$account")"
          refresh_webdav_share "$share"
          if ! find_webdav_share_account "$share" | grep -q .; then set_firewall_port remove "$port"; fi
          ;;
      esac
      rm -f "$marker"
      log "临时账户已到期并被彻底清理: ${protocol}:${USER}"
    done < <(list_accounts "$protocol" || true)
  done
  if [ "$sftp_changed" -eq 1 ]; then
    load_sftp_service
    if list_accounts sftp >/dev/null 2>&1; then
      render_sshd_config
    else
      remove_sshd_managed_config
      set_firewall_port remove "$SFTP_PORT"
      rm -f "$SFTP_STATE"
    fi
  fi
  if [ "$ftp_changed" -eq 1 ]; then
    load_ftp_service
    if list_accounts ftp >/dev/null 2>&1; then
      render_vsftpd_config
    else
      set_firewall_port remove "$FTP_PORT"
      set_ftp_passive_firewall remove
      rm -f "$FTP_STATE"
      restore_original_file /etc/vsftpd.conf vsftpd.conf
      if [ -f /etc/vsftpd.conf ]; then systemctl restart "$FTP_SERVICE" >/dev/null 2>&1 || true; else systemctl stop "$FTP_SERVICE" 2>/dev/null || true; fi
    fi
  fi
}

install_all_protocols() {
  local share
  share="$(prompt "共享实例名称" "ba")"; validate_name "$share"
  add_ftp "$share"
  add_sftp "$share"
  add_webdav "$share"
}

purge_all_accounts() {
  local protocol account share marker group
  local -A webdav_ports=()
  confirm "确认 purge 全部协议和账户？所有数据目录会保留。" || return
  for protocol in sftp ftp webdav; do
    while IFS= read -r account; do
      case "$protocol" in
        sftp) load_account sftp "$account"; remove_user_and_group "$USER" "$GROUP" sftp; rm -f "${AUTHORIZED_KEYS_DIR}/${USER}" "$(account_file sftp "$account")" ;;
        ftp) load_account ftp "$account"; remove_user_and_group "$USER" "$GROUP" ftp; rm -f "$(account_file ftp "$account")" ;;
        webdav)
          load_account webdav "$account"
          share="${SHARE:-$(shared_name_from_dir "$ROOT")}"
          webdav_ports["$PORT"]=1
          [ "$FAMILY" = "debian" ] && a2dissite "$(basename "$(webdav_conf_file "$USER")")" >/dev/null 2>&1 || true
          [ "$FAMILY" = "debian" ] && a2dissite "$(basename "$(webdav_conf_file "$share")")" >/dev/null 2>&1 || true
          rm -f "$(webdav_conf_file "$USER")" "$(webdav_conf_file "$share")" "$(webdav_user_auth_file "$USER")" "${STATE_DIR}/webdav-${USER}.htpasswd" "$(webdav_auth_file "$share")" "$(account_file webdav "$account")"
          ;;
      esac
    done < <(list_accounts "$protocol" || true)
  done
  if [ -f "$SFTP_STATE" ]; then load_sftp_service; set_firewall_port remove "$SFTP_PORT"; fi
  if [ -f "$FTP_STATE" ]; then load_ftp_service; set_firewall_port remove "$FTP_PORT"; set_ftp_passive_firewall remove; fi
  for marker in "${!webdav_ports[@]}"; do set_firewall_port remove "$marker"; done
  remove_sshd_managed_config
  systemctl disable --now "$EXPIRY_TIMER" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${EXPIRY_SERVICE}" "/etc/systemd/system/${EXPIRY_TIMER}"
  systemctl daemon-reload
  restore_original_file /etc/vsftpd.conf vsftpd.conf
  if [ -f /etc/vsftpd.conf ]; then
    systemctl restart "$FTP_SERVICE" >/dev/null 2>&1 || warn "原始 vsftpd 配置已恢复，但服务重启失败。"
  else
    systemctl stop "$FTP_SERVICE" >/dev/null 2>&1 || true
  fi
  apache_configtest && systemctl restart "$APACHE_SERVICE" >/dev/null 2>&1 ||
    warn "托管 WebDAV 配置已移除，但 Apache 配置验证或重启失败。"
  for marker in "${MANAGED_GROUP_DIR}"/spm_*; do
    [ -e "$marker" ] || continue
    group="$(basename "$marker")"
    gpasswd -d "$APACHE_USER" "$group" >/dev/null 2>&1 || true
    groupdel "$group" >/dev/null 2>&1 || true
  done
  rm -rf "$STATE_DIR"
  init_state
  log "全部托管账户与配置已 purge，数据目录和系统软件包均已保留。"
}

status_report() {
  local protocol accounts share share_accounts account state expiry webdav_port address
  address="$(server_address)"
  title "服务状态"
  systemctl --no-pager --full status "$SSH_SERVICE" 2>/dev/null | sed -n '1,6p' || true
  systemctl --no-pager --full status "$FTP_SERVICE" 2>/dev/null | sed -n '1,6p' || true
  systemctl --no-pager --full status "$APACHE_SERVICE" 2>/dev/null | sed -n '1,6p' || true
  title "账户清单"
  for protocol in ftp sftp webdav; do
    accounts="$(list_accounts "$protocol" 2>/dev/null | paste -sd ',' - || true)"
    printf '%s: %s\n' "${protocol^^}" "${accounts:-无}"
  done
  title "共享实例账户"
  while IFS= read -r share; do
    share_accounts="$(list_share_accounts "$share" | paste -sd ',' - || true)"
    printf '%s: %s\n' "$share" "$share_accounts"
  done < <(list_managed_shares)
  title "WebDAV 共享入口"
  while IFS= read -r share; do
    if webdav_port="$(webdav_share_port "$share" 2>/dev/null)"; then
      printf '%s: %s://%s:%s/\n' "$share" "$(webdav_scheme)" "$address" "$webdav_port"
    fi
  done < <(list_managed_shares)
  title "临时账户"
  for protocol in ftp sftp webdav; do
    while IFS= read -r account; do
      (
        load_account "$protocol" "$account"
        [ "${TEMPORARY:-0}" = 1 ] || exit 0
        if account_expired "${EXPIRES_AT:-0}"; then state="已到期"; else state="有效"; fi
        expiry="$(format_expiry "$EXPIRES_AT")"
        printf '%s:%s [%s] 到期: %s\n' "$protocol" "$USER" "$state" "$expiry"
      )
    done < <(list_accounts "$protocol" || true)
  done
  title "共享文件路径"
  while IFS= read -r share; do
    printf '%s: %s\n' "$share" "$(account_shared_dir "$share")"
  done < <(list_managed_shares)
}

ftp_menu() {
  local choice
  choice="$(select_menu "安装或管理 FTP" "新增 FTP" "purge FTP" "修改 FTP 配置" "管理 FTP 密码" "返回主菜单")"
  case "$choice" in
    "新增 FTP") add_ftp; pause_screen ;;
    "purge FTP") purge_ftp_account; pause_screen ;;
    "修改 FTP 配置") modify_ftp; pause_screen ;;
    "管理 FTP 密码") manage_ftp_password; pause_screen ;;
  esac
}

sftp_menu() {
  local choice
  choice="$(select_menu "安装或管理 SFTP" "新增 SFTP" "purge SFTP" "修改 SFTP 配置" "管理 SFTP 登录方式" "返回主菜单")"
  case "$choice" in
    "新增 SFTP") add_sftp; pause_screen ;;
    "purge SFTP") purge_sftp_account; pause_screen ;;
    "修改 SFTP 配置") modify_sftp; pause_screen ;;
    "管理 SFTP 登录方式") manage_sftp_auth; pause_screen ;;
  esac
}

webdav_menu() {
  local choice
  choice="$(select_menu "安装或管理 WebDAV" "新增 WebDAV" "purge WebDAV" "修改 WebDAV 配置" "修改 WebDAV 密码" "返回主菜单")"
  case "$choice" in
    "新增 WebDAV") add_webdav; pause_screen ;;
    "purge WebDAV") purge_webdav_account; pause_screen ;;
    "修改 WebDAV 配置") modify_webdav; pause_screen ;;
    "修改 WebDAV 密码") manage_webdav_password; pause_screen ;;
  esac
}

all_protocols_menu() {
  local choice
  choice="$(select_menu "一键安装管理所有协议" "一键安装所有协议和账户" "一键 purge 所有协议和账户" "返回主菜单")"
  case "$choice" in
    "一键安装所有协议和账户") install_all_protocols; pause_screen ;;
    "一键 purge 所有协议和账户") purge_all_accounts; pause_screen ;;
  esac
}

main_menu() {
  local choice
  while true; do
    choice="$(select_menu "流媒体协议安装工具" "一键安装管理所有协议" "安装或管理 FTP" "安装或管理 SFTP" "安装或管理 WebDAV" "查看服务状态" "添加临时账户" "退出")"
    case "$choice" in
      "一键安装管理所有协议") all_protocols_menu ;;
      "安装或管理 FTP") ftp_menu ;;
      "安装或管理 SFTP") sftp_menu ;;
      "安装或管理 WebDAV") webdav_menu ;;
      "查看服务状态") status_report; pause_screen ;;
      "添加临时账户") create_temporary_account; pause_screen ;;
      "退出") return ;;
    esac
  done
}

main() {
  case "${1:-}" in -h|--help|help) usage; return ;; esac
  require_root
  exec 9> "/run/${APP}.lock"
  flock -n 9 || die "配置脚本正在运行中，请不要并发操作。"
  detect_system
  init_state
  case "${1:-}" in
    "") main_menu ;;
    status) status_report ;;
    expire) expire_temporary_accounts ;;
    repair-webdav) repair_all_webdav_shares ;;
    purge-all) purge_all_accounts ;;
    *) usage; die "未知命令: $1" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
