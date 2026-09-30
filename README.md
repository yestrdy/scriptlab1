# Control ↔ Managed node SSH тохиргоо

Control node дээр `ssh M1` гэж бичихэд username, password асуухгүйгээр M1 рүү шууд нэвтэрнэ.

| Файл | Хаана ажиллуулах | Юу хийх |
|---|---|---|
| `inventory.conf` | — | Managed node-уудын жагсаалт (`ALIAS IP USER PORT`) |
| `managed-node-setup.sh` | Managed node бүр дээр, **root** | sshd суулгах/enable, хэрэглэгч + NOPASSWD sudo, authorized_keys, keepalive, firewall |
| `control-node-setup.sh` | Control node дээр, энгийн хэрэглэгч | SSH key, `~/.ssh/config`, key хуулах, `~/.bashrc`, шалгалт |

## Ашиглах

**1. Control node** дээр `inventory.conf`-ийг засна:
```
M1   192.168.1.101   ansible   22
M2   192.168.1.102   ansible   22
```

**2. Managed node** бүр дээр (control node-ийн public key-г шууд өгвөл нууц үг огт хэрэггүй болно):
```bash
# control node дээр key-г харах (control-node-setup.sh ажиллуулсны дараа эсвэл ssh-keygen хийсний дараа):
cat ~/.ssh/id_ed25519.pub

# managed node дээр:
sudo ./managed-node-setup.sh ansible "ssh-ed25519 AAAA... user@control"
```
Public key өгөхгүй бол скрипт хэрэглэгчид түр нууц үг тохируулахыг асууна. `control-node-setup.sh` энэ нууц үгийг зөвхөн **нэг удаа** ашиглаж key-г хуулна.

**3. Control node** дээр:
```bash
./control-node-setup.sh
source ~/.bashrc
ssh M1        # эсвэл зүгээр л: M1
```

Скриптүүдийг дахин ажиллуулахад асуудалгүй. `# BEGIN/END scriptlab1` блокийг шинэчилдэг бөгөөд давхар бичдэггүй.

## `~/.bashrc`-д нэмэгдэх зүйлс

| Команд | Үйлдэл |
|---|---|
| `M1` | `ssh M1`-тэй адил (config дахь host бүрт alias үүсгэнэ) |
| `ssh M<Tab>` | Host нэрийг автоматаар гүйцээнэ (ssh/scp/sftp) |
| `ssh_hosts` | Бүх alias-ыг жагсаана |
| `ssh_check` | Бүх node руу нууц үггүй холбогдож байгаа эсэхийг шалгана (OK/FAIL) |
| `ssh_all uptime` | Бүх node дээр команд ажиллуулна |
| `ANSIBLE_HOST_KEY_CHECKING=False` | Ansible host key асуухгүй |

## Холболт "хэзээ ч" ажиллах баталгаа

- Managed node: `sshd` нь `systemctl enable` хийгдсэн тул reboot хийсний дараа ч автоматаар асна. `ClientAliveInterval 60` тохируулсан. Firewall дээр SSH порт нээлттэй.
- Control node: `ServerAliveInterval 30` тул идэвхгүй үед холболт тасрахгүй. `ControlPersist 10m` нь холболтыг дахин ашиглаж хурдасгана. `StrictHostKeyChecking accept-new` тул шинэ host-ийн хувьд "yes/no" асуухгүй.
- Key нь passphrase-гүй тул ssh-agent шаардлагагүй.

## Нэмэлт аюулгүй байдал (заавал биш)

Бүх node дээр key ажиллаж байгааг `ssh_check`-ээр шалгасны дараа managed node дээр password нэвтрэлтийг хааж болно:
```bash
echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/20-nopassword.conf
sudo systemctl restart sshd   # Debian/Ubuntu дээр: ssh
```
