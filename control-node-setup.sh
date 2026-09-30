#!/usr/bin/env bash
# Control node дээр (Ansible ажиллуулах хэрэглэгчээр, root биш байж болно) ажиллуулна.
#   ./control-node-setup.sh [inventory.conf]
#
# Хийх зүйлс:
#   1. Нууц үггүй ed25519 SSH key үүсгэнэ (~/.ssh/id_ed25519)
#   2. ~/.ssh/config-д managed node бүрийн alias бичнэ  ->  `ssh M1`
#   3. Public key-г managed node руу хуулна (зөвхөн анх нэг удаа)
#   4. ~/.bashrc-д alias, tab-completion, туслах функцууд нэмнэ
#   5. Холболт бүрийг нууц үггүйгээр (BatchMode) шалгана
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${1:-$SCRIPT_DIR/inventory.conf}"
SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_ed25519"
CONFIG="$SSH_DIR/config"
BASHRC="$HOME/.bashrc"
BEGIN="# BEGIN scriptlab1"
END="# END scriptlab1"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

[[ -f "$INVENTORY" ]] || { echo "Inventory файл олдсонгүй: $INVENTORY" >&2; exit 1; }

# Inventory унших (коммент, хоосон мөрийг алгасна)
declare -a ALIASES HOSTS USERS PORTS
while read -r a h u p _; do
    [[ -z "${a:-}" || "$a" == \#* ]] && continue
    [[ -n "${h:-}" && -n "${u:-}" ]] || { warn "Буруу мөр алгаслаа: $a $h $u"; continue; }
    ALIASES+=("$a"); HOSTS+=("$h"); USERS+=("$u"); PORTS+=("${p:-22}")
done < "$INVENTORY"
(( ${#ALIASES[@]} > 0 )) || { echo "Inventory хоосон байна" >&2; exit 1; }

# 1. SSH key
install -d -m 700 "$SSH_DIR"
if [[ ! -f "$KEY" ]]; then
    log "Нууц үггүй SSH key үүсгэж байна: $KEY"
    ssh-keygen -t ed25519 -N "" -C "$(whoami)@$(uname -n)-control" -f "$KEY" -q
else
    log "SSH key аль хэдийн байна: $KEY"
fi

# 2. ~/.ssh/config
log "$CONFIG тохируулж байна"
touch "$CONFIG"; chmod 600 "$CONFIG"
sed -i "/^$BEGIN/,/^$END/d" "$CONFIG"
{
    echo "$BEGIN (control-node-setup.sh автоматаар үүсгэсэн)"
    for i in "${!ALIASES[@]}"; do
        cat <<EOF
Host ${ALIASES[$i]}
    HostName ${HOSTS[$i]}
    User ${USERS[$i]}
    Port ${PORTS[$i]}
    IdentityFile $KEY
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no

EOF
    done
    cat <<EOF
# Бүх холболтод: тасрахгүй байх (keepalive), шинэ host-ийг автоматаар зөвшөөрөх,
# нэг TCP холболтыг дахин ашиглах (ControlMaster) -> хурдан
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ConnectTimeout 10
    StrictHostKeyChecking accept-new
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
$END
EOF
} >> "$CONFIG"

# 3. Public key-г managed node руу хуулах
for i in "${!ALIASES[@]}"; do
    a=${ALIASES[$i]} h=${HOSTS[$i]} u=${USERS[$i]} p=${PORTS[$i]}
    if ssh -o ConnectTimeout=5 -o ControlMaster=no "$a" true 2>/dev/null; then
        log "$a: key аль хэдийн ажиллаж байна"
        continue
    fi
    log "$a ($u@$h:$p): public key хуулж байна — $u-ийн нууц үгийг НЭГ УДАА асууна"
    if ! ssh-copy-id -i "$KEY.pub" -p "$p" \
            -o ControlMaster=no -o StrictHostKeyChecking=accept-new \
            -o PreferredAuthentications=password,keyboard-interactive \
            "$u@$h"; then
        warn "$a: хуулж чадсангүй. Managed node дээр дараахыг ажиллуулж болно:"
        warn "  sudo ./managed-node-setup.sh $u \"$(cat "$KEY.pub")\""
    fi
done

# 4. ~/.bashrc
log "$BASHRC тохируулж байна"
touch "$BASHRC"
sed -i "/^$BEGIN/,/^$END/d" "$BASHRC"
cat >> "$BASHRC" <<'EOF'
# BEGIN scriptlab1 (control-node-setup.sh автоматаар үүсгэсэн)
# ~/.ssh/config доторх host alias-уудыг жагсаана (M1, M2, ...)
ssh_hosts() {
    awk 'tolower($1)=="host" {for (i=2; i<=NF; i++) if ($i !~ /[*?!]/) print $i}' \
        ~/.ssh/config 2>/dev/null
}

# `M1` гэж бичихэд `ssh M1` ажиллана
for _h in $(ssh_hosts); do
    alias "$_h"="ssh $_h"
done
unset _h

# ssh / scp / sftp дээр Tab дарахад host нэрс гарна
_ssh_host_complete() { COMPREPLY=($(compgen -W "$(ssh_hosts)" -- "${COMP_WORDS[COMP_CWORD]}")); }
complete -o default -F _ssh_host_complete ssh scp sftp ssh-copy-id

# Бүх managed node-ийн холболтыг шалгах:  ssh_check
ssh_check() {
    local h
    for h in ${@:-$(ssh_hosts)}; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null; then
            printf '  \033[32mOK\033[0m    %s\n' "$h"
        else
            printf '  \033[31mFAIL\033[0m  %s\n' "$h"
        fi
    done
}

# Бүх managed node дээр команд ажиллуулах:  ssh_all uptime
ssh_all() {
    [ $# -gt 0 ] || { echo "Хэрэглээ: ssh_all <команд>"; return 1; }
    local h
    for h in $(ssh_hosts); do
        echo "===== $h ====="
        ssh -o BatchMode=yes "$h" "$@"
    done
}

# Ansible ашиглавал нууц үг/host key асуухгүй
export ANSIBLE_HOST_KEY_CHECKING=False
# END scriptlab1
EOF

# 5. Шалгах
echo
log "Холболтыг шалгаж байна (нууц үггүй):"
fail=0
for a in "${ALIASES[@]}"; do
    if out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$a" 'echo "$(whoami)@$(uname -n)"' 2>/dev/null); then
        echo "  OK    $a -> $out"
    else
        echo "  FAIL  $a"; fail=1
    fi
done

echo
log "Дууслаа. Одоогийн shell-д идэвхжүүлэх:  source ~/.bashrc"
log "Дараа нь:  ssh ${ALIASES[0]}   эсвэл   ${ALIASES[0]}"
exit $fail
