# New server setup

Turns a fresh Hetzner Cloud Ubuntu server into a private, general-purpose box that only my own devices can reach, over Tailscale.

- Nothing on the internet can reach any port. Hetzner's firewall blocks everything inbound, and `ufw` on the server blocks everything except Tailscale.
- Any device on my tailnet can reach any port.
- Logging in needs two things: a device on my tailnet **and** an SSH key. Login is OpenSSH with keys, as `rahul`, not Tailscale SSH.
- Security updates install themselves, and the server restarts at 04:00 UTC when one needs it.

There are two ways to run it, and they do the same thing: run `setup.sh`, or follow the numbered sections below by hand. Each section number here matches a `section_N_*` function in the script.

Design notes: [`../docs/superpowers/specs/2026-11-01-server-setup-design.md`](../docs/superpowers/specs/2026-11-01-server-setup-design.md).

In the commands below, `<name>` is the server's name, `<public-ip>` its public IPv4 address and `<tailnet-ip>` its Tailscale address. Never commit real values for any of them to this repo.

## Before you start

1. **Hetzner console:** rename the server to `<name>`. Cloud-init resets the OS hostname to the Hetzner name at boot, so the two names must match.
2. **Tailscale admin console:** delete any old device for this server.
3. **Mac:** confirm the Mac can sign new devices under Tailnet Lock: `tailscale lock status` lists this node's key under "Trusted signing keys".
4. **Hetzner console:** detach any firewall left over from a previous build. Re-imaging keeps attached firewalls, and the rules of every attached firewall add together.
5. **On the server, as root:** attach Ubuntu Pro with `pro attach`, which prompts for the token. Never write the token anywhere. Then run `pro enable livepatch` if `pro status` doesn't already show it enabled.

## Running the script

Stage 1, as root over the public IP, from a checkout of this repo:

```bash
scp -r server root@<public-ip>:/root/
ssh -t root@<public-ip> bash /root/server/setup.sh <name>
ssh root@<public-ip> bash /root/server/setup.sh --check
```

Stage 2 comes after the "Between stages" steps. It runs as `rahul` over the tailnet:

```bash
scp -r server rahul@<tailnet-ip>:
ssh rahul@<tailnet-ip> bash server/setup.sh --lockdown
ssh rahul@<tailnet-ip> sudo bash server/setup.sh --check-lockdown
```

## 1 Hostname

```bash
mkdir -p /var/lib/server-setup && echo <name> > /var/lib/server-setup/name   # the script's checks read this
hostnamectl set-hostname <name>
# /etc/hosts: make the 127.0.1.1 line read
#   127.0.1.1 <name>
timedatectl show -p Timezone --value   # should print Etc/UTC; leave it on UTC
```

## 2 Packages

```bash
apt-get update
apt-get -y full-upgrade
apt-get -y install fish fastfetch ufw curl
```

## 3 Swap

A 2 GB swap file. The Hetzner image ships without one.

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

## 4 Adverts

Turns off Ubuntu's "news" on login and in apt output.

```bash
sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
pro config set apt_news=false
```

## 5 User

`rahul`, with passwordless sudo, starting with the key Hetzner put on root. The phone and iPad keys get added in "Between stages".

```bash
useradd --create-home --shell /bin/bash --user-group rahul
echo 'rahul ALL=(ALL) NOPASSWD:ALL' > /tmp/90-rahul
chmod 0440 /tmp/90-rahul
visudo -cf /tmp/90-rahul && mv /tmp/90-rahul /etc/sudoers.d/90-rahul
install -d -m 700 -o rahul -g rahul /home/rahul/.ssh
touch /home/rahul/.ssh/authorized_keys
# Append root's keys that rahul doesn't have yet; never overwrite (that would drop phone keys)
while read -r key; do
  grep -qxF -- "$key" /home/rahul/.ssh/authorized_keys || echo "$key" >> /home/rahul/.ssh/authorized_keys
done < /root/.ssh/authorized_keys
chmod 600 /home/rahul/.ssh/authorized_keys
chown rahul:rahul /home/rahul/.ssh/authorized_keys
```

## 6 Automatic updates

Security updates, including Ubuntu Pro's ESM (Expanded Security Maintenance) updates, install every day. When one needs a restart, the server restarts at 04:00 UTC, even if someone is logged in.

```bash
apt-get -y install unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52server-setup-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
unattended-upgrade --dry-run --debug 2>&1 | grep -i 'allowed origins'   # should list UbuntuESM and UbuntuESMApps
```

Ubuntu Pro is attached by hand, because it needs a secret token: `pro attach` prompts for it ("Before you start", step 5). The script only warns if Pro isn't attached. Livepatch comes with Pro and runs as a snap, which is why `snapd` stays installed.

Anything installed on this server later must start by itself after a restart, e.g. as an enabled systemd service. Otherwise it won't survive the 04:00 restarts.

## 7 Tailscale

Installed from Tailscale's signed apt repo. The server joins as my own device (no tag). Tailscale SSH stays **off**: logins go through OpenSSH with keys. Tailscale updates itself.

```bash
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")   # e.g. resolute
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
apt-get update && apt-get -y install tailscale
tailscale up --hostname=<name>     # prints a login URL; open it and approve
tailscale set --auto-update
tailscale lock status              # prints the `tailscale lock sign ...` line for the Mac
```

**The tailnet policy must allow my devices to reach the server.** An empty rule list in the policy means *deny everything*. Tailscale's default policy allows everything; a stricter one needs at least:

```json
"grants": [ {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]} ]
```

`tailscale ping <tailnet-ip>` can succeed while SSH times out. If that happens, the policy is the problem: on the server, `tailscale debug netmap` shows an empty `PacketFilter`.

Tailscale adds its own firewall rule that accepts all traffic on `tailscale0` before ufw sees it. So the tailnet policy, not ufw, decides what tailnet devices can reach. ufw's job is the public interface.

## 8 SSH

Keys only, with no X11 or agent forwarding. Agent forwarding is off so that a break-in here can't use my Mac's key to reach other servers. Root can still log in with a key until stage 2.

`/etc/ssh/sshd_config.d/00-server-setup.conf`. sshd uses the first value it reads, so this file must sort before any other drop-in:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
PermitRootLogin prohibit-password
```

```bash
sshd -t && systemctl try-reload-or-restart ssh.service   # validate first; ssh.socket only holds the port
sshd -T | grep -E 'passwordauth|kbdinteractive|x11forwarding|allowagentforwarding|permitrootlogin'
```

## 9 Firewall

ufw guards the public interface. Public SSH stays open until stage 2, so that stage 1 can't lock anyone out.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow 22/tcp comment 'temporary: removed by --lockdown'
ufw --force enable
```

## 10 Shell

Interactive logins get fish, with fastfetch as the greeting. Everything else stays in bash: scripts, `sudo -i`, and `ssh host 'command'`. `rahul`'s login shell stays `/bin/bash`, and three lines in `.bashrc` hand interactive sessions over to fish.

Add this to the end of `/home/rahul/.bashrc`:

```bash
# >>> server-setup fish >>>
# Interactive logins get fish; scripts and `ssh host 'cmd'` stay in bash
if [[ $- == *i* && -z $BASH_EXECUTION_STRING && $(ps -o comm= -p $PPID) != fish ]] && command -v fish >/dev/null; then
  exec fish
fi
# <<< server-setup fish <<<
```

Greeting and login stats, as `rahul`:

```bash
mkdir -p ~/.config/fish/functions ~/.config/fastfetch
printf 'function fish_greeting\n    fastfetch\nend\n' > ~/.config/fish/functions/fish_greeting.fish
cp server/fastfetch.jsonc ~/.config/fastfetch/config.jsonc
```

fisher and nvm.fish, as `rahul`. The first download of fisher is pinned to a release and checked against its SHA-256. The script holds the current version and checksum in `FISHER_VERSION` and `FISHER_SHA256`.

```bash
curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/<version>/functions/fisher.fish -o /tmp/fisher.fish
echo '<sha256>  /tmp/fisher.fish' | sha256sum -c
fish -c 'source /tmp/fisher.fish; and fisher install jorgebucaran/fisher jorgebucaran/nvm.fish'
```

### Login stats

`fastfetch.jsonc` shows the Ubuntu logo plus everything worth knowing about a server: identity, health (load, CPU, memory, swap, disk), both IP addresses, package counts, and six server-state lines. Every source is local, and none of them needs root. The whole run takes about 150 ms.

| Line | Source |
|---|---|
| Tailscale | `tailscale status --json` backend state (e.g. Running) |
| Reboot | whether `/var/run/reboot-required` exists |
| Ubuntu Pro | Pro's status cache, `/var/lib/ubuntu-advantage/status.json` |
| Livepatch | the same cache, plus the patch count in `/sys/kernel/livepatch` |
| Updates | update-notifier's cache, `/var/lib/update-notifier/updates-available` |
| Last auto-update | when systemd last finished `apt-daily-upgrade.service` |

Three lines are left out on purpose:
- **`pro status` and `apt-check`** each take over a second.
- **`canonical-livepatch status`** needs root.
- **The unattended-upgrades log** is readable only by the `adm` group.

Later updates are one command, run by hand in fish: `fisher update`. It fetches the latest fisher and nvm.fish from GitHub, unpinned. To install Node: `nvm install lts`.

To run a bash snippet from somewhere, type `bash`, paste, then `exit` to return to fish.

## Between stages

Public SSH is still open at this point. Don't run stage 2 until every step here works.

1. **Sign the server under Tailnet Lock** from the Mac. First check that the node key in the line stage 1 printed matches the server's own key (`tailscale status --json --peers=false | grep PublicKey` on the server), then run:
   ```bash
   /Applications/Tailscale.app/Contents/MacOS/Tailscale lock sign nodekey:<…> tlpub:<…>
   ```
   It can take a few seconds for the server to show "accessible under Tailnet Lock".
2. **Turn off key expiry** for the server in the Tailscale admin console (Machines → the server → Disable key expiry). Otherwise it drops off the tailnet when its key expires.
3. **Test from the Mac over the tailnet:** `ssh rahul@<tailnet-ip> 'sudo -n true && echo ok'` prints `ok`.
4. **Add a key for each phone and tablet** (Termius):
   1. In Termius: Keychain → Keys → **Generate key**, type **ED25519**. Leave Termius's cloud sync off for this key, so the private key never leaves the device.
   2. Copy its **public** key (one line starting `ssh-ed25519`) to the Mac.
   3. Append it on the server: `ssh rahul@<tailnet-ip> 'cat >> ~/.ssh/authorized_keys' <<< '<the ssh-ed25519 line>'`
   4. In Termius, add a host: address `<name>` (MagicDNS) or `<tailnet-ip>`, user `rahul`, that key. Tailscale must be connected on the device.
   5. Log in. It should land in fish, with the fastfetch stats.

   If a device is lost, remove it from the tailnet first, which cuts it off straight away. Then delete its line from `~/.ssh/authorized_keys`.

## L1 SSH lockdown

Only once the Mac **and** a phone have logged in over the tailnet. Run as `rahul`, over the tailnet. The script refuses to run over the public IP or as root, because closing public SSH from a session that came in that way could lock you out.

`00-server-setup.conf` becomes:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
PermitRootLogin no
AllowUsers rahul
```

```bash
sudo sshd -t && sudo systemctl try-reload-or-restart ssh.service
```

## L2 Firewall lockdown

```bash
sudo ufw delete allow 22/tcp      # removes the temporary public SSH rule (IPv4 and IPv6)
sudo ufw status                   # only "Anywhere on tailscale0" rules remain
sudo touch /var/lib/server-setup/lockdown-done
```

That last line records the lockdown, as the script does. After that, re-running stage 1 keeps the lockdown settings: it won't reopen public SSH or allow root back in.

## After lockdown

In the Hetzner console:

1. **Firewalls → Create firewall** with **no inbound rules** (leave outbound as is). Apply it to the server. Make sure it's the only firewall attached.
2. **The server → Rescue → Reset root password**, then log in once through the **Console** button. This is the way back in if Tailscale ever breaks, since nothing else listens publicly.

## Checks

Stop and fix anything that fails.

**On the server** (as root, or with `sudo`): `setup.sh --check` before lockdown, `setup.sh --check-lockdown` after. Every check prints `PASS` or `FAIL`, and the command exits non-zero if anything failed.

**From the Mac:**

```bash
# 1. Nothing is reachable from the internet (the most important check)
nmap -Pn -p- -T4 <public-ip>              # every port "filtered"
nmap -6 -Pn -p- -T4 <public-ipv6>         # same over IPv6 (needs IPv6 on the Mac)
ping -c 3 <public-ip>                     # no replies: Hetzner's firewall drops it before ufw

# 2. The tailnet works
ssh rahul@<tailnet-ip> 'echo $0'          # prints "bash", no fastfetch
ssh rahul@<tailnet-ip>                    # interactive: fish + fastfetch stats

# 3. Logins are locked down
ssh root@<tailnet-ip> true                # Permission denied (publickey)
ssh -o PubkeyAuthentication=no rahul@<tailnet-ip> true   # Permission denied (publickey)

# 4. Survives a restart
ssh rahul@<tailnet-ip> sudo reboot
# then repeat 2 and run --check-lockdown; the hostname must still be <name>
```
