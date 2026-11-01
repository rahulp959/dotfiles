#!/usr/bin/env bash
# Turn a fresh Hetzner Ubuntu server into a Tailscale-only, lightly hardened box.
#
#   setup.sh <name>         stage 1, as root over public SSH
#   setup.sh --lockdown     stage 2, as rahul over the tailnet (only after testing logins)
#   setup.sh --check        check stage 1 state (as root)
#   setup.sh --check-lockdown   check everything, with lockdown expectations (as root)
#
# Each numbered section matches the same-numbered section of README.md,
# which has the hand-run commands for every step. Every section is safe to re-run.
set -euo pipefail

TARGET_USER=rahul
SWAPFILE=/swapfile
SWAP_SIZE=2G
REBOOT_TIME=04:00
STATE_DIR=/var/lib/server-setup
# sshd uses the first value it reads, so this must sort before other drop-ins.
SSHD_CONF=/etc/ssh/sshd_config.d/00-server-setup.conf
# Used only if pkgs.tailscale.com has no repo for this release yet.
TAILSCALE_FALLBACK_CODENAME=noble
# fisher bootstrap: one pinned release, verified before it runs. After that,
# `fisher update` (run by hand) updates fisher and nvm.fish from GitHub.
FISHER_VERSION=4.4.8
FISHER_SHA256=0fb6c81ae3003e95b5671766fa6c25c3597066e29965b7772f6c1b007387356d
NAME_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FAILS=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# check LABEL CMD... : run CMD quietly, report PASS/FAIL, count failures.
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    FAILS=$((FAILS + 1))
  fi
}

saved_name() { cat "$STATE_DIR/name" 2>/dev/null; }

# ---------------------------------------------------------------- 1 Hostname

section_1_hostname() {
  local name=$1
  # cloud-init rewrites both from the Hetzner server name at every boot, so the
  # Hetzner name must match too (see "Before you start").
  if [[ $(hostname) != "$name" ]]; then
    log "1 hostname: $name"
    hostnamectl set-hostname "$name"
  fi
  if ! hosts_has_name; then
    log "1 /etc/hosts: 127.0.1.1 $name"
    sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
    sed -i "1i 127.0.1.1 $name $name" /etc/hosts
  fi
}

hosts_has_name() {
  local name
  name=$(saved_name)
  [[ -n $name ]] && grep -qE "^127\.0\.1\.1[[:space:]]+$name([[:space:]]|\$)" /etc/hosts
}

check_1_hostname() {
  check "name saved"             test -s "$STATE_DIR/name"
  check "hostname is saved name" test "$(hostname)" = "$(saved_name)"
  check "/etc/hosts has name"    hosts_has_name
  check "timezone is UTC"        test "$(timedatectl show -p Timezone --value)" = "Etc/UTC"
}

# ---------------------------------------------------------------- 2 Packages

section_2_packages() {
  log "2 packages: upgrade and install"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get -y -q full-upgrade
  apt-get -y -q install fish fastfetch ufw curl
}

check_2_packages() {
  local p
  for p in fish fastfetch ufw curl; do check "package $p" dpkg -s "$p"; done
}

# ---------------------------------------------------------------- 3 Swap

section_3_swap() {
  if [[ ! -f $SWAPFILE ]]; then
    log "3 swap: creating $SWAP_SIZE $SWAPFILE"
    fallocate -l "$SWAP_SIZE" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi
  if ! swapon --show=NAME --noheadings | grep -x "$SWAPFILE" >/dev/null; then
    swapon "$SWAPFILE"
  fi
  if ! grep -q "^$SWAPFILE " /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  fi
}

check_3_swap() {
  check "swap active"   sh -c "swapon --show=NAME --noheadings | grep -qx '$SWAPFILE'"
  check "swap is 2G"    test "$(stat -c %s "$SWAPFILE" 2>/dev/null)" = 2147483648
  check "swap in fstab" grep -q "^$SWAPFILE " /etc/fstab
}

# ---------------------------------------------------------------- 4 Adverts

section_4_adverts() {
  if [[ -f /etc/default/motd-news ]] && ! grep -qx 'ENABLED=0' /etc/default/motd-news; then
    log "4 adverts: motd-news off"
    sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  fi
  pro config set apt_news=false >/dev/null
}

check_4_adverts() {
  check "motd-news off" grep -qx 'ENABLED=0' /etc/default/motd-news
  check "apt_news off"  sh -c 'pro config show apt_news | grep -qi false'
}

# ---------------------------------------------------------------- 5 User

section_5_user() {
  local home=/home/$TARGET_USER sudoers=/etc/sudoers.d/90-$TARGET_USER tmp key
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    log "5 user: creating $TARGET_USER"
    useradd --create-home --shell /bin/bash --user-group "$TARGET_USER"
  fi
  if [[ ! -f $sudoers ]]; then
    log "5 sudo: passwordless sudo for $TARGET_USER"
    tmp=$(mktemp)
    echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "$tmp"
    chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null || die "5 sudoers file failed validation"
    mv "$tmp" "$sudoers"
  fi
  # Start with the key(s) Hetzner gave root; phone and iPad keys are added later.
  install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  while IFS= read -r key; do
    [[ -z $key || $key == \#* ]] && continue
    if ! grep -qxF -- "$key" "$home/.ssh/authorized_keys"; then
      log "5 keys: adding a key from root"
      echo "$key" >> "$home/.ssh/authorized_keys"
    fi
  done < /root/.ssh/authorized_keys
  chmod 600 "$home/.ssh/authorized_keys"
  chown "$TARGET_USER:$TARGET_USER" "$home/.ssh/authorized_keys"
}

check_5_user() {
  check "user exists"         id "$TARGET_USER"
  check "passwordless sudo"   sudo -n -u "$TARGET_USER" sudo -n true
  check "sudoers file valid"  visudo -cf "/etc/sudoers.d/90-$TARGET_USER"
  check "has root's keys"     sh -c "grep -qFxf /root/.ssh/authorized_keys /home/$TARGET_USER/.ssh/authorized_keys"
  check "login shell is bash" test "$(getent passwd "$TARGET_USER" | cut -d: -f7)" = /bin/bash
}

# ---------------------------------------------------------------- 6 Automatic updates

section_6_updates() {
  local reboot_conf=/etc/apt/apt.conf.d/52server-setup-reboot want
  apt-get -y -q install unattended-upgrades >/dev/null
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
  want=$(printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-WithUsers "true";\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$REBOOT_TIME")
  if [[ ! -f $reboot_conf || $(cat "$reboot_conf") != "$want" ]]; then
    log "6 updates: automatic restart at $REBOOT_TIME UTC"
    echo "$want" > "$reboot_conf"
  fi
  # Attaching Pro needs a secret token, so it's a manual step ("Before you start").
  if ! pro status --format json | grep '"attached": true' >/dev/null; then
    log "6 NOTE: Ubuntu Pro is not attached; run 'pro attach' by hand (it prompts for the token)"
  fi
}

check_6_updates() {
  check "periodic upgrades on" sh -c "apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade \"1\"'"
  check "auto reboot on"       sh -c "apt-config dump | grep -q 'Unattended-Upgrade::Automatic-Reboot \"true\"'"
  check "reboot with users"    sh -c "apt-config dump | grep -q 'Automatic-Reboot-WithUsers \"true\"'"
  check "reboot at $REBOOT_TIME" sh -c "apt-config dump | grep -q 'Automatic-Reboot-Time \"$REBOOT_TIME\"'"
  check "ESM origins allowed"  sh -c "unattended-upgrade --dry-run --debug 2>&1 | grep -i 'allowed origins' | grep -q ESM"
  check "Pro attached"         sh -c "pro status --format json | grep -q '\"attached\": true'"
  check "Livepatch enabled"    sh -c "canonical-livepatch status 2>/dev/null | grep -q 'running: true'"
}

# ---------------------------------------------------------------- 7 Tailscale

section_7_tailscale() {
  local name=$1 codename base=https://pkgs.tailscale.com/stable/ubuntu
  if ! command -v tailscale >/dev/null; then
    # shellcheck source=/dev/null
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    if ! curl -fsI "$base/$codename.noarmor.gpg" >/dev/null; then
      log "7 tailscale: no repo for $codename yet, using $TAILSCALE_FALLBACK_CODENAME"
      codename=$TAILSCALE_FALLBACK_CODENAME
    fi
    log "7 tailscale: installing from pkgs.tailscale.com ($codename)"
    curl -fsSL "$base/$codename.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "$base/$codename.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -q
    apt-get -y -q install tailscale
  fi
  systemctl enable --now tailscaled
  if ! tailscale status --json | grep '"BackendState": "Running"' >/dev/null; then
    log "7 tailscale: open the login URL below to join the tailnet (Tailscale SSH stays off)"
    tailscale up --hostname="$name"
  fi
  tailscale set --auto-update
  if ! tailscale lock status | grep -i 'This node is accessible under tailnet lock' >/dev/null; then
    log "7 Tailnet Lock: sign this node from a trusted device (the Mac), using the line below"
    tailscale lock status
  fi
}

check_7_tailscale() {
  check "tailscaled running"     systemctl is-active --quiet tailscaled
  check "logged in, running"     sh -c "tailscale status --json | grep -q '\"BackendState\": \"Running\"'"
  check "signed under Tailnet Lock" sh -c "tailscale lock status | grep -qi 'This node is accessible under tailnet lock'"
  # `tailscale debug prefs` is pretty-printed JSON; squash it to one line to match.
  check "tailscale ssh off"      sh -c "tailscale debug prefs | tr -d ' \n' | grep -q '\"RunSSH\":false'"
  check "auto-update on"         sh -c "tailscale debug prefs | tr -d ' \n' | grep -q '\"AutoUpdate\":{[^}]*\"Apply\":true'"
}

# ---------------------------------------------------------------- 8 SSH

section_8_ssh() {
  write_sshd_config "$(current_mode)"
}

# stage1 until the server is locked down; lockdown afterwards, so re-running
# stage 1 never re-allows root login or reopens public SSH. The live sshd state
# counts too, in case the lockdown was done by hand from README.md.
current_mode() {
  if [[ -f $STATE_DIR/lockdown-done ]] \
    || sshd -T 2>/dev/null | grep -x 'permitrootlogin no' >/dev/null; then
    echo lockdown
  else
    echo stage1
  fi
}

# write_sshd_config stage1|lockdown
write_sshd_config() {
  local mode=$1 want backup
  want="# Managed by server/setup.sh ($mode mode)
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no"
  if [[ $mode == lockdown ]]; then
    want+=$'\nPermitRootLogin no\nAllowUsers '"$TARGET_USER"
  else
    want+=$'\nPermitRootLogin prohibit-password'
  fi
  if [[ -f $SSHD_CONF && $(cat "$SSHD_CONF") == "$want" ]]; then
    return 0
  fi
  log "8 ssh: $mode settings"
  backup=$(mktemp)
  if [[ -f $SSHD_CONF ]]; then cp "$SSHD_CONF" "$backup"; fi
  echo "$want" > "$SSHD_CONF"
  if ! sshd -t; then
    if [[ -s $backup ]]; then cp "$backup" "$SSHD_CONF"; else rm -f "$SSHD_CONF"; fi
    rm -f "$backup"
    die "8 new sshd config failed 'sshd -t'; previous config restored"
  fi
  rm -f "$backup"
  # ssh.socket only holds the port; the settings live in sshd (ssh.service),
  # which re-reads its config on reload. Existing sessions are unaffected.
  # try-reload-or-restart: a plain reload fails while socket-activated sshd is
  # idle (e.g. right after a boot); then the next connection reads the new config.
  systemctl try-reload-or-restart ssh.service
}

# No `grep -q` after a pipe in this script: under pipefail its early exit can
# SIGPIPE the writer and fail the pipeline even on a match.
sshd_has() { sshd -T | grep -x "$1" >/dev/null; }

check_8_ssh() {
  check "no password auth"    sshd_has 'passwordauthentication no'
  check "no kbd-interactive"  sshd_has 'kbdinteractiveauthentication no'
  check "no X11 forwarding"   sshd_has 'x11forwarding no'
  check "no agent forwarding" sshd_has 'allowagentforwarding no'
}

# ---------------------------------------------------------------- 9 Firewall

section_9_firewall() {
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow in on tailscale0 >/dev/null
  # Public SSH stays open until --lockdown, so stage 1 can't lock anyone out.
  if [[ $(current_mode) == stage1 ]]; then
    ufw allow 22/tcp comment 'temporary: removed by --lockdown' >/dev/null
  fi
  if ! ufw status | grep 'Status: active' >/dev/null; then
    log "9 firewall: enabling ufw"
    ufw --force enable >/dev/null
  fi
}

check_9_firewall() {
  check "ufw active"            sh -c "ufw status | grep -q 'Status: active'"
  check "deny incoming default" sh -c "ufw status verbose | grep -q 'deny (incoming)'"
  check "tailscale0 allowed"    sh -c "ufw status | grep -q 'Anywhere on tailscale0.*ALLOW'"
}

# ---------------------------------------------------------------- 10 Shell

section_10_shell() {
  local home=/home/$TARGET_USER tmp
  local fishdir=$home/.config/fish

  write_fish_handoff "$home/.bashrc"

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$home/.config" "$fishdir" "$fishdir/functions"
  printf 'function fish_greeting\n    fastfetch\nend\n' > "$fishdir/functions/fish_greeting.fish"
  chown "$TARGET_USER:$TARGET_USER" "$fishdir/functions/fish_greeting.fish"

  if [[ -f $SCRIPT_DIR/fastfetch.jsonc ]]; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$home/.config/fastfetch"
    install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/fastfetch.jsonc" "$home/.config/fastfetch/config.jsonc"
  fi

  if ! as_user_fish 'type -q fisher; and fisher list | grep -q jorgebucaran/nvm.fish'; then
    log "10 fisher $FISHER_VERSION + nvm.fish"
    tmp=$(mktemp)
    curl -fsSL "https://raw.githubusercontent.com/jorgebucaran/fisher/$FISHER_VERSION/functions/fisher.fish" -o "$tmp"
    if ! echo "$FISHER_SHA256  $tmp" | sha256sum -c --quiet; then
      rm -f "$tmp"
      die "10 fisher.fish checksum mismatch: refusing to run it"
    fi
    chmod 644 "$tmp"
    as_user_fish "source $tmp; and fisher install jorgebucaran/fisher jorgebucaran/nvm.fish"
    rm -f "$tmp"
  fi
}

# Hand interactive logins to fish; scripts and `ssh host 'cmd'` stay in bash.
write_fish_handoff() {
  local bashrc=$1 begin='# >>> server-setup fish >>>' end='# <<< server-setup fish <<<' tmp
  tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$bashrc" > "$tmp"
  cat >> "$tmp" <<EOF
$begin
# Interactive logins get fish; scripts and \`ssh host 'cmd'\` stay in bash
if [[ \$- == *i* && -z \$BASH_EXECUTION_STRING && \$(ps -o comm= -p \$PPID) != fish ]] && command -v fish >/dev/null; then
  exec fish
fi
$end
EOF
  if ! cmp -s "$tmp" "$bashrc"; then
    log "10 bashrc: fish hand-off"
    cat "$tmp" > "$bashrc"
  fi
  rm -f "$tmp"
}

as_user_fish() { (cd "/home/$TARGET_USER" && sudo -u "$TARGET_USER" -H fish -c "$1"); }

# An interactive login with a terminal (what Ray gets from Termius or the Mac).
# Capture first, then match: under pipefail, `grep -q` exiting early would
# SIGPIPE `script` and fail the pipeline even on a match.
interactive_login_is_fish() {
  local out
  # shellcheck disable=SC2016 # $FISH_VERSION must expand in the login shell, not here
  out=$(printf 'echo FV=$FISH_VERSION\nexit\n' | timeout 20 script -qec "su - $TARGET_USER" /dev/null) || true
  [[ $out == *FV=[0-9]* ]]
}

check_10_shell() {
  local home=/home/$TARGET_USER
  check "bashrc hands off to fish"        grep -q 'exec fish' "$home/.bashrc"
  check "interactive login gets fish"     interactive_login_is_fish
  check "cmd over ssh stays bash"         timeout 5 sudo -u "$TARGET_USER" -H bash -ic 'echo ok'
  check "fisher has nvm.fish"             as_user_fish 'fisher list | grep -q jorgebucaran/nvm.fish'
  check "fisher manages itself"           as_user_fish 'fisher list | grep -q jorgebucaran/fisher'
  check "nvm works"                       as_user_fish 'nvm --version'
  check "greeting is fastfetch"           as_user_fish 'functions fish_greeting | grep -q fastfetch'
  check "fastfetch config installed"      test -f "$home/.config/fastfetch/config.jsonc"
  check "fastfetch under 0.5s"            fastfetch_is_fast
  check "fastfetch shows tailnet IP"      fastfetch_shows_tailnet_ip
}

fastfetch_shows_tailnet_ip() {
  local out
  out=$(cd "/home/$TARGET_USER" && sudo -u "$TARGET_USER" -H fastfetch --pipe 2>/dev/null) || return 1
  [[ $out == *"Tailnet IP: 100."* ]]
}

# The stats run on every interactive login, so they must stay quick.
fastfetch_is_fast() {
  local start ms
  start=$(date +%s%N)
  (cd "/home/$TARGET_USER" && sudo -u "$TARGET_USER" -H fastfetch >/dev/null 2>&1)
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  [[ $ms -lt 500 ]]
}

# ---------------------------------------------------------------- L Lockdown (stage 2)

# Lockdown closes public SSH and root login, so it must only run from a session
# that already proves the tailnet path works: rahul, over SSH from a tailnet address.
lockdown_guard() {
  local client=${SSH_CONNECTION%% *} a b
  [[ $(id -un) == "$TARGET_USER" ]] \
    || die "--lockdown must run as $TARGET_USER over the tailnet, not as $(id -un)"
  IFS=. read -r a b _ <<< "$client"
  if [[ $client == fd7a:115c:a1e0:* ]]; then
    :
  elif [[ $a != 100 || ! $b =~ ^[0-9]+$ || $b -lt 64 || $b -gt 127 ]]; then
    die "--lockdown must run over the tailnet (SSH from a 100.64.0.0/10 address); this session comes from '${client:-no SSH connection}'. Locking down from here could lock you out."
  fi
  grep -qE '^(ssh-|ecdsa-|sk-)' "$HOME/.ssh/authorized_keys" 2>/dev/null \
    || die "--lockdown: $TARGET_USER has no SSH keys"
  sudo -n true 2>/dev/null || die "--lockdown: $TARGET_USER needs passwordless sudo"
}

stage_2() {
  lockdown_guard
  log "guard passed: $TARGET_USER over the tailnet from ${SSH_CONNECTION%% *}"
  exec sudo bash "$SCRIPT_DIR/setup.sh" --lockdown-apply
}

# Root half of --lockdown; only reachable through the guard (via sudo from rahul).
stage_2_apply() {
  [[ $EUID -eq 0 && ${SUDO_USER:-} == "$TARGET_USER" ]] \
    || die "use --lockdown (as $TARGET_USER over the tailnet), not --lockdown-apply"
  mkdir -p "$STATE_DIR"
  section_L1_ssh_lockdown
  section_L2_firewall_lockdown
  touch "$STATE_DIR/lockdown-done"
  log "lockdown done: public SSH closed, root login off, only $TARGET_USER may log in"
  log "next: attach the Hetzner firewall (no inbound rules), then run --check-lockdown"
}

# ---------------------------------------------------------------- L1 SSH lockdown

section_L1_ssh_lockdown() {
  write_sshd_config lockdown
}

# ---------------------------------------------------------------- L2 Firewall lockdown

section_L2_firewall_lockdown() {
  if ufw show added | grep 'allow 22/tcp' >/dev/null; then
    log "L2 firewall: removing the temporary public SSH rule"
    ufw delete allow 22/tcp >/dev/null
  fi
}

check_lockdown() {
  check "root login off"     sshd_has 'permitrootlogin no'
  check "only rahul allowed" sshd_has "allowusers $TARGET_USER"
  check "no public 22 rule"  sh -c "! ufw show added | grep -q 'allow 22/tcp'"
  check "lockdown recorded"  test -f "$STATE_DIR/lockdown-done"
}

# ---------------------------------------------------------------- main

usage() {
  cat >&2 <<'EOF'
usage: setup.sh <name> | --lockdown | --check | --check-lockdown
  <name> must be a valid hostname: lowercase letters, digits and hyphens,
  1-63 characters, not starting or ending with a hyphen.
EOF
  exit 2
}

stage_1() {
  local name=$1
  [[ $EUID -eq 0 ]] || die "stage 1 must run as root"
  mkdir -p "$STATE_DIR"
  echo "$name" > "$STATE_DIR/name"
  section_1_hostname "$name"
  section_2_packages
  section_3_swap
  section_4_adverts
  section_5_user
  section_6_updates
  section_7_tailscale "$name"
  section_8_ssh
  section_9_firewall
  section_10_shell
  log "stage 1 done"
}

run_checks() {
  local lockdown=${1:-}
  [[ $EUID -eq 0 ]] || die "checks must run as root"
  check_1_hostname
  check_2_packages
  check_3_swap
  check_4_adverts
  check_5_user
  check_6_updates
  check_7_tailscale
  check_8_ssh
  check_9_firewall
  check_10_shell
  if [[ $lockdown == lockdown ]]; then check_lockdown; fi
  if [[ $FAILS -gt 0 ]]; then
    printf '%d check(s) failed\n' "$FAILS"
    exit 1
  fi
  echo "all checks passed"
}

main() {
  case "${1:-}" in
    --check) run_checks ;;
    --check-lockdown) run_checks lockdown ;;
    --lockdown) stage_2 ;;
    --lockdown-apply) stage_2_apply ;;
    '' | -*) usage ;;
    *)
      [[ $1 =~ $NAME_RE ]] || usage
      stage_1 "$1"
      ;;
  esac
}

main "$@"
