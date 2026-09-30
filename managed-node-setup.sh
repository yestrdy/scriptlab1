#!/usr/bin/env bash
# Managed node дээр root эрхээр ажиллуулна.
#   sudo ./managed-node-setup.sh <username> ["<control node-ийн public key>"]
#
# Хийх зүйлс:
#   - openssh-server суулгаж, boot үед автоматаар асдаг болгоно (хэзээ ч хандах боломжтой)
#   - <username> хэрэглэгч үүсгэж, нууц үггүй sudo эрх өгнө
#   - Public key өгсөн бол authorized_keys-д нэмнэ (тэгвэл нууц үг огт хэрэггүй)
#   - sshd-д public key нэвтрэлт, keepalive тохиргоо хийнэ
#   - Firewall идэвхтэй бол SSH портыг нээнэ
set -euo pipefail

TARGET_USER="${1:-ansible}"
PUBKEY="${2:-}"
SSHD_CONFIG=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN_FILE="$DROPIN_DIR/10-scriptlab1.conf"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "root эрхээр ажиллуулна уу: sudo $0 $*" >&2; exit 1; }

# 1. openssh-server суулгах
if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    log "openssh-server суулгаж байна"
    if command -v apt-get >/dev/null; then
        apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sudo
    elif command -v dnf >/dev/null; then
        dnf install -y openssh-server sudo
    elif command -v yum >/dev/null; then
        yum install -y openssh-server sudo
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install openssh sudo
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm openssh sudo
    else
        echo "Package manager олдсонгүй. openssh-server-ийг гараар суулгана уу." >&2; exit 1
    fi
fi
SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)

# 2. Хэрэглэгч үүсгэх + нууц үггүй sudo (Ansible-д хэрэгтэй)
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    log "'$TARGET_USER' хэрэглэгч үүсгэж байна"
    useradd -m -s /bin/bash "$TARGET_USER"
    if [[ -z "$PUBKEY" ]]; then
        warn "Public key өгөөгүй тул ssh-copy-id-д зориулж түр нууц үг тохируулна:"
        passwd "$TARGET_USER"
    fi
fi
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$TARGET_USER"
chmod 440 "/etc/sudoers.d/$TARGET_USER"
visudo -cf "/etc/sudoers.d/$TARGET_USER" >/dev/null

# 3. ~/.ssh ба authorized_keys
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
USER_GROUP=$(id -gn "$TARGET_USER")
install -d -m 700 -o "$TARGET_USER" -g "$USER_GROUP" "$USER_HOME/.ssh"
AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"
if [[ -n "$PUBKEY" ]] && ! grep -qxF "$PUBKEY" "$AUTH_KEYS"; then
    log "Public key-г authorized_keys-д нэмж байна"
    echo "$PUBKEY" >> "$AUTH_KEYS"
fi
chown "$TARGET_USER:$USER_GROUP" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
command -v restorecon >/dev/null && restorecon -R "$USER_HOME/.ssh" || true

# 4. sshd тохиргоо
SETTINGS="PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
UseDNS no"

if grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG"; then
    log "sshd drop-in тохиргоо бичиж байна: $DROPIN_FILE"
    mkdir -p "$DROPIN_DIR"
    printf '# scriptlab1 managed\n%s\n' "$SETTINGS" > "$DROPIN_FILE"
else
    # Include байхгүй бол файлын эхэнд бичнэ (sshd эхний утгыг авдаг)
    log "sshd_config-ийн эхэнд тохиргоо нэмж байна"
    sed -i '/^# BEGIN scriptlab1/,/^# END scriptlab1/d' "$SSHD_CONFIG"
    { printf '# BEGIN scriptlab1\n%s\n# END scriptlab1\n' "$SETTINGS"; cat "$SSHD_CONFIG"; } > "$SSHD_CONFIG.tmp"
    mv "$SSHD_CONFIG.tmp" "$SSHD_CONFIG"
fi
[[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -A
mkdir -p /run/sshd
"$SSHD_BIN" -t || { echo "sshd тохиргоо алдаатай байна!" >&2; exit 1; }

# 5. sshd-г асааж, boot үед автоматаар асдаг болгох
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    SVC=sshd
    systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' || SVC=ssh
    log "$SVC service-ийг enable + restart хийж байна"
    systemctl enable "$SVC" >/dev/null 2>&1 || true
    systemctl restart "$SVC"
else
    warn "systemd олдсонгүй — sshd-г шууд асаалаа (boot үед асаах тохиргоог гараар хийнэ үү)"
    pkill -x sshd 2>/dev/null || true
    "$SSHD_BIN"
fi

# 6. Firewall
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=ssh >/dev/null && firewall-cmd --reload >/dev/null
    log "firewalld: ssh нээгдлээ"
elif command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow OpenSSH >/dev/null
    log "ufw: OpenSSH нээгдлээ"
fi

log "Бэлэн. Managed node: $(uname -n)  хэрэглэгч: $TARGET_USER"
ip -4 -o addr show scope global 2>/dev/null | awk '{print "    IP: "$4}' || true
