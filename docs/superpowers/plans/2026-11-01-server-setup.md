# Server Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One readable bash script, a matching hand-run guide and a fastfetch config that turn a fresh Hetzner Ubuntu 26.04 server into a Tailscale-only, lightly hardened, general-purpose box.

**Architecture:** `server/setup.sh` is a single bash file of numbered section functions (`section_N_*`), each paired with a check function (`check_N_*`). Stage 1 runs as root over public SSH; stage 2 (`--lockdown`) runs as `rahul` over the tailnet. `--check` / `--check-lockdown` run every check and exit non-zero on any failure; these checks are the test suite. `server/README.md` documents the same sections, same numbers, as plain commands.

**Tech Stack:** bash, OpenSSH, ufw, Tailscale (official apt repo), unattended-upgrades, Ubuntu Pro (Livepatch, ESM), fish, fisher, nvm.fish, fastfetch. Mac-side: shellcheck, nmap, Tailscale CLI.

**Spec:** `docs/superpowers/specs/2026-11-01-server-setup-design.md` (approved 2026-11-01). Read it before any task.

## Global Constraints

- The repo is public. Never write the server's IP, its real name, any Tailscale/Pro token or private key into any committed file. In commands below, `$IP` (public IPv4) and `$NAME` are Mac shell variables set by the executor, and `$TS_IP` is the server's tailnet IPv4.
- No Ansible, no templating, no framework. One bash script, readable top to bottom.
- Nothing fetched at run time except signed apt packages and the fisher bootstrap/plugins.
- Login user `rahul`, passwordless sudo. Timezone stays UTC. Swap 2 GB at `/swapfile`. Automatic restart at `04:00`.
- Every section is safe to re-run. Every check prints `PASS <label>` or `FAIL <label>`.
- Nothing from the old `NEW_SERVER.MD` is reused.
- `dotfiles` has an unrelated uncommitted change to `_homebrew/Brewfile`. Never stage it: always `git add` explicit paths.
- Don't push. Ray decides about pushing at the end.

## Review Focus

1. **Re-running stage 1 after lockdown** must not reopen public SSH or re-allow root login. Test lives in Task 8.
2. **Running `--lockdown` from anywhere but the tailnet** (e.g. over the public IP) must refuse before changing anything. Otherwise it could lock Ray out. Test lives in Task 8.
3. **A missing or invalid server name** must stop stage 1 before anything changes. Test lives in Task 1.
4. **A reboot** must keep everything: hostname (Hetzner cloud-init can reset it), swap, ufw, the sshd config, Tailscale reconnecting, and the fish/fastfetch login. Test lives in Task 9.
5. **A fastfetch custom command failing** (Tailscale stopped, file missing) must show `unknown` quickly, never an error or a hang. Test lives in Task 5.

---

### Task 1: Skeleton, base system (sections 1–4)

**Files:**
- Create: `server/setup.sh`, `server/README.md`
- Delete: `NEW_SERVER.MD`

**Interfaces:**
- Produces, in `setup.sh`:
  - constants `TARGET_USER=rahul`, `SWAPFILE=/swapfile`, `SWAP_SIZE=2G`, `REBOOT_TIME=04:00`, `STATE_DIR=/var/lib/server-setup` (files: `name`, `lockdown-done`)
  - `log MSG`, `die MSG` (stderr, exit 1)
  - `as_root CMD...` (run directly if EUID 0, else `sudo`)
  - `check LABEL CMD...` (runs CMD quietly, prints `PASS LABEL` / `FAIL LABEL`, increments global `FAILS`)
  - `main "$@"` dispatch: `setup.sh <name>` → stage 1; `--lockdown` → stage 2; `--check` → stage 1 checks; `--check-lockdown` → all checks with lockdown expectations. Exit 2 on bad usage.
  - section/check pairs: `section_1_hostname` / `check_1_hostname`, `section_2_packages` / `check_2_packages`, `section_3_swap` / `check_3_swap`, `section_4_adverts` / `check_4_adverts`
- Name rule: `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`. Stage 1 saves it to `$STATE_DIR/name`; checks read it from there.

- [ ] **Step 1: Prepare the branch, tools and console.** In `~/Projects/dotfiles`: `git switch -c server-setup`, `brew install shellcheck nmap`. Ray (Hetzner console): rename the server to `$NAME` and detach any firewall left from the old build (spec "Before the script" steps 1 and 4). Expected: on branch `server-setup`, both commands on PATH, Ray confirms the console steps.

- [ ] **Step 2: Write the skeleton and the section 1–4 checks only** (sections are empty stubs). Checks:
```bash
check_1_hostname()  { check "hostname is saved name" test "$(hostname)" = "$(cat $STATE_DIR/name)"
                      check "/etc/hosts has name"    grep -qw "$(cat $STATE_DIR/name)" /etc/hosts
                      check "timezone is UTC"         test "$(timedatectl show -p Timezone --value)" = "Etc/UTC"; }
check_2_packages()  { for p in fish fastfetch ufw curl; do check "package $p" dpkg -s "$p"; done; }
check_3_swap()      { check "swap active"   swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"
                      check "swap is 2G"    test "$(stat -c %s $SWAPFILE)" -eq 2147483648
                      check "swap in fstab" grep -q "^$SWAPFILE " /etc/fstab; }
check_4_adverts()   { check "motd-news off" grep -qx 'ENABLED=0' /etc/default/motd-news
                      check "apt_news off"  sh -c 'pro config show apt_news | grep -q False'; }
```

- [ ] **Step 3: Write `README.md` skeleton.** Sections in this order, headings numbered exactly as the script: "Before you start" (console/Mac steps 1–5 from the spec), "1 Hostname", "2 Packages", "3 Swap", "4 Adverts", then placeholders "5 User", "6 Automatic updates", "7 Tailscale", "8 SSH", "9 Firewall", "10 Shell", "Between stages", "L1 SSH lockdown", "L2 Firewall lockdown", "After lockdown", "Checks". Fill 1–4 with the plain commands that do what the sections will do. `git rm NEW_SERVER.MD`.

- [ ] **Step 4: Static and usage tests fail as expected.** Run: `shellcheck server/setup.sh` → clean. `bash server/setup.sh` → exit 2. `bash server/setup.sh 'Bad_Name!'` → exit 2 and prints the name rule. Then copy and check on the server: `scp -r server root@$IP:/root/ && ssh root@$IP bash /root/server/setup.sh --check`. Expected: FAIL lines (no saved name yet, no swap, adverts on); exit non-zero. Packages may already PASS on the fresh image.

- [ ] **Step 5: Implement sections 1–4.**
  - **Hostname:** `hostnamectl set-hostname`, plus the `127.0.1.1 <name>` line in `/etc/hosts`.
  - **Packages:** `apt-get update && apt-get -y full-upgrade`, then install `fish fastfetch ufw curl`.
  - **Swap:** `fallocate`, `chmod 600`, `mkswap`, `swapon`. Add the fstab line `/swapfile none swap sw 0 0` once.
  - **Adverts:** set `ENABLED=0` in `/etc/default/motd-news`, then run `pro config set apt_news=false`.
  - Each section skips work that's already done.

- [ ] **Step 6: Run stage 1 twice and check.** `scp -r server root@$IP:/root/ && ssh root@$IP bash /root/server/setup.sh $NAME` (twice) then `ssh root@$IP bash /root/server/setup.sh --check`. Expected: second run changes nothing; all checks PASS. Bad-name test: `ssh root@$IP bash /root/server/setup.sh BAD!` exits 2 and `hostname` is unchanged.

- [ ] **Step 7: Commit.** `git add server/setup.sh server/README.md NEW_SERVER.MD && git commit -m "server: add setup script skeleton and base system sections"`

### Task 2: User and shell (sections 5 and 10)

**Files:**
- Modify: `server/setup.sh`, `server/README.md` (sections 5 and 10)

**Interfaces:**
- Consumes: `check`, `as_root`, `TARGET_USER`, packages from section 2.
- Produces: `section_5_user` / `check_5_user`, `section_10_shell` / `check_10_shell`; constants `FISHER_VERSION`, `FISHER_SHA256`. Section 10 copies `server/fastfetch.jsonc` if present (Task 3 creates it) and installs the greeting.

- [ ] **Step 1: Write the checks.**
```bash
check_5_user()  { check "user exists"          id "$TARGET_USER"
                  check "passwordless sudo"    sudo -n -u "$TARGET_USER" sudo -n true
                  check "sudoers file valid"   visudo -cf /etc/sudoers.d/90-$TARGET_USER
                  check "has root's keys"      sh -c "grep -qFf /root/.ssh/authorized_keys /home/$TARGET_USER/.ssh/authorized_keys"
                  check "login shell is bash"  test "$(getent passwd $TARGET_USER | cut -d: -f7)" = /bin/bash; }
check_10_shell(){ check "bashrc hands off to fish" grep -q 'exec fish' /home/$TARGET_USER/.bashrc
                  check "cmd over ssh stays bash"  timeout 5 sudo -u $TARGET_USER -H bash -ic 'echo ok' # exits 0 only if fish wasn't started
                  check "fisher has nvm.fish"      sudo -u $TARGET_USER -H fish -c 'fisher list | grep -q jorgebucaran/nvm.fish'
                  check "fisher manages itself"    sudo -u $TARGET_USER -H fish -c 'fisher list | grep -q jorgebucaran/fisher'
                  check "nvm works"                sudo -u $TARGET_USER -H fish -c 'nvm --version'
                  check "greeting is fastfetch"    sudo -u $TARGET_USER -H fish -c 'functions fish_greeting | grep -q fastfetch'; }
```
(The "cmd over ssh stays bash" check approximates `ssh host 'cmd'`. Task 9 tests the real thing from the Mac.)

- [ ] **Step 2: Run `--check` on the server.** Expected: the new checks FAIL.

- [ ] **Step 3: Implement `section_5_user`.**
  - **Account:** `adduser --disabled-password --gecos ""` if the user is missing.
  - **Sudo:** write `/etc/sudoers.d/90-rahul` containing `rahul ALL=(ALL) NOPASSWD:ALL` with mode 0440, and validate it with `visudo -cf` before moving it into place.
  - **Keys:** append any root keys that `rahul` doesn't already have to `~rahul/.ssh/authorized_keys`, with modes 700/600 and owner `rahul`.

- [ ] **Step 4: Implement `section_10_shell`.**
  - **bashrc hand-off:** add this exact block to `~rahul/.bashrc` between `# >>> server-setup fish >>>` / `# <<< server-setup fish <<<` markers, replacing any existing block:
```bash
# Interactive logins get fish; scripts and `ssh host 'cmd'` stay in bash
if [[ $- == *i* && -z $BASH_EXECUTION_STRING && $(ps -o comm= -p $PPID) != fish ]] && command -v fish >/dev/null; then
  exec fish
fi
```
  - **Fisher pinning:** set `FISHER_VERSION` to the latest fisher release tag at build time. Then, on the Mac, run `curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/$FISHER_VERSION/functions/fisher.fish | shasum -a 256` and paste the result into `FISHER_SHA256`.
  - **Fisher install:** download to a temp file and verify with `sha256sum -c`; abort the section on a mismatch. Then, as rahul: `fish -c 'source <tmp>; fisher install jorgebucaran/fisher jorgebucaran/nvm.fish'`. Skip this step if `fisher list` already shows both.
  - **Greeting:** write `~rahul/.config/fish/functions/fish_greeting.fish`, whose body is just `fastfetch`.
  - **fastfetch config:** copy `server/fastfetch.jsonc` to `~rahul/.config/fastfetch/config.jsonc` if it exists.

- [ ] **Step 5: Run stage 1 twice, then `--check`.** Expected: all PASS, and the second run does no fisher download. Manual: `ssh -t root@$IP su - rahul` lands in fish with fastfetch output (default layout for now).

- [ ] **Step 6: Fill README sections 5 and 10, then commit.** `git add server/setup.sh server/README.md && git commit -m "server: add rahul user and fish shell sections"`

### Task 3: Login stats (fastfetch config)

**Files:**
- Create: `server/fastfetch.jsonc`
- Modify: `server/setup.sh` (`check_10_shell` gains two checks), `server/README.md` (section 10)

**Interfaces:**
- Consumes: section 10 copies this file.
- Produces: a valid fastfetch config: full Ubuntu logo, modules in the spec's "Login stats" order and groups, no network calls.

- [ ] **Step 1: Add the checks.**
```bash
check "fastfetch config installed" test -f /home/$TARGET_USER/.config/fastfetch/config.jsonc
check "fastfetch under 0.5s"       sh -c "s=\$(date +%s%N); sudo -u $TARGET_USER -H fastfetch >/dev/null 2>&1; test \$(( (\$(date +%s%N)-s)/1000000 )) -lt 500"
```
Run `--check`. Expected: FAIL on the first (file missing).

- [ ] **Step 2: Measure each custom command on the server** before using it, timing it as `rahul` with `time`:
  - `tailscale ip -4`
  - `test -f /var/run/reboot-required`
  - `canonical-livepatch status`
  - `pro status --format json`
  - `/usr/lib/update-notifier/apt-check --human-readable`
  - reading the last date from `/var/log/unattended-upgrades/unattended-upgrades.log`

  For each one that needs root or takes over ~100 ms: find a root-free source, or drop it and note why in the README. Adding `rahul` to the `adm` group to read logs is allowed. No sudo rules are allowed.

- [ ] **Step 3: Write `server/fastfetch.jsonc`.**
  - **Modules, per the spec:** title, separator, os, host, kernel, initsystem, locale, datetime, uptime, loadavg, processes, users, cpu, cpuusage, memory, swap, disk (`folders: "/"`), localip (one entry each for `tailscale0` and `eth0`, labelled), packages, shell, the surviving custom `command` modules, colors.
  - **Each custom command:** wrapped as `timeout 0.3 <cmd> 2>/dev/null || echo unknown`, so a failure shows `unknown` quickly.
  - No `publicip` module.

- [ ] **Step 4: Run stage 1, then `--check`.** Expected: all PASS. Manual: `ssh -t root@$IP su - rahul` shows the logo and every module with a real value.

- [ ] **Step 5: Commit.** (The failure test for these commands needs Tailscale installed, so it lives in Task 5 Step 5.) `git add server/fastfetch.jsonc server/setup.sh server/README.md && git commit -m "server: add fastfetch login stats"`

### Task 4: Automatic updates (section 6)

**Files:**
- Modify: `server/setup.sh`, `server/README.md` (section 6)

**Interfaces:**
- Produces: `section_6_updates` / `check_6_updates`; file `/etc/apt/apt.conf.d/52server-setup-reboot`.

- [ ] **Step 1: Write the checks.**
```bash
check_6_updates() {
  check "periodic upgrades on"     sh -c "apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade \"1\"'"
  check "auto reboot on"           sh -c "apt-config dump | grep -q 'Unattended-Upgrade::Automatic-Reboot \"true\"'"
  check "reboot with users"        sh -c "apt-config dump | grep -q 'Automatic-Reboot-WithUsers \"true\"'"
  check "reboot at 04:00"          sh -c "apt-config dump | grep -q 'Automatic-Reboot-Time \"$REBOOT_TIME\"'"
  check "ESM origins allowed"      sh -c "unattended-upgrade --dry-run --debug 2>&1 | grep -i 'allowed origins' | grep -q ESM"
  check "Pro attached"             sh -c "pro status --format json | grep -q '\"attached\": true'"
  check "Livepatch enabled"        sh -c "canonical-livepatch status 2>/dev/null | grep -q 'running: true'"
}
```
Run `--check`. Expected: the reboot checks FAIL. The Pro and Livepatch checks already PASS on the first build.

- [ ] **Step 2: Implement `section_6_updates`.**
  - **Package and timers:** install `unattended-upgrades` and write `20auto-upgrades` with both periodic values set to `"1"`.
  - **Restart settings:** write `52server-setup-reboot` with the three Automatic-Reboot values.
  - **Ubuntu Pro:** don't attach it here. If it isn't attached, print the `pro attach` reminder and continue. The token is never handled by the script.

- [ ] **Step 3: Run stage 1, then `--check`.** Expected: all PASS.

- [ ] **Step 4: Fill README section 6, including the manual `pro attach` note, then commit.** `git commit -m "server: add automatic updates section"` (explicit paths)

### Task 5: Tailscale (section 7) and joining the tailnet

**Files:**
- Modify: `server/setup.sh`, `server/README.md` (section 7, "Between stages")

**Interfaces:**
- Produces: `section_7_tailscale` / `check_7_tailscale`. After this task, `$TS_IP` exists and `ssh rahul@$TS_IP` works from the Mac (still with root key login and public SSH open).

- [ ] **Step 1: Write the checks.**
```bash
check_7_tailscale() {
  check "tailscaled running"   systemctl is-active --quiet tailscaled
  check "logged in, running"   sh -c "tailscale status --json | grep -q '\"BackendState\": \"Running\"'"
  check "tailscale ssh off"    sh -c "! tailscale debug prefs | grep -q '\"RunSSH\": true'"
  check "auto-update on"       sh -c "tailscale debug prefs | grep -q '\"AutoUpdate\".*\"Apply\": true'"
}
```
(Builder: confirm the prefs JSON key names on the installed version and adjust the patterns. The intent is fixed: SSH off, auto-update apply on.) Run `--check`. Expected: FAIL.

- [ ] **Step 2: Implement `section_7_tailscale`.**
  - **Repository:** add Tailscale's apt repo for the release codename (`/usr/share/keyrings/tailscale-archive-keyring.gpg` plus the `.list` file from pkgs.tailscale.com), then install `tailscale`.
  - **Missing 26.04 build:** if `resolute` isn't published yet, fall back to the newest published Ubuntu codename and say so in a log line.
  - **Joining:** if the backend isn't Running, run `tailscale up --hostname=<name>`, which prints the login URL and waits. Then run `tailscale set --auto-update`.
  - **Tailnet Lock:** afterwards, print the output of `tailscale lock status`, which contains the `tailscale lock sign ...` line to run on the Mac.

- [ ] **Step 3: Run stage 1 interactively.** `ssh -t root@$IP bash /root/server/setup.sh $NAME`. Ray opens the login URL. Then on the Mac: `/Applications/Tailscale.app/Contents/MacOS/Tailscale lock sign <nodekey> <tlpub>` using the printed line. Ray then disables key expiry for the node in the Tailscale admin console.

- [ ] **Step 4: Verify the tailnet path.** `--check` shows all PASS. From the Mac, `ssh rahul@$TS_IP 'sudo -n true && echo ok'` prints `ok`.

- [ ] **Step 5: fastfetch failure test (Review Focus 5).** Over the **public** IP as root (the tailnet path drops when tailscaled stops), run `systemctl stop tailscaled`, then `sudo -u rahul -H fastfetch`, then `systemctl start tailscaled`. Expected: the Tailscale line shows `unknown`, no error text appears, and it finishes in under 0.5 s.

- [ ] **Step 6: Fill README section 7 and "Between stages" (signing, key expiry). Commit.** `git commit -m "server: add tailscale section"` (explicit paths)

### Task 6: SSH and firewall, stage 1 (sections 8 and 9)

**Files:**
- Modify: `server/setup.sh`, `server/README.md` (sections 8 and 9)

**Interfaces:**
- Produces: `write_sshd_config MODE` (`stage1` or `lockdown`), which writes `/etc/ssh/sshd_config.d/00-server-setup.conf`, runs `sshd -t` (restoring the previous file and dying on failure), then reloads SSH. Also `section_8_ssh` / `check_8_ssh`, `section_9_firewall` / `check_9_firewall`. Task 8 reuses `write_sshd_config lockdown`.
- File contents. Both modes: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `X11Forwarding no`, `AllowAgentForwarding no`. `stage1` adds `PermitRootLogin prohibit-password`. `lockdown` adds `PermitRootLogin no` and `AllowUsers rahul`.
- Both sections pick `lockdown` mode whenever `$STATE_DIR/lockdown-done` exists (Review Focus 1).

- [ ] **Step 1: Write the checks.** Use `sshd -T` (effective settings):
```bash
check_8_ssh() {
  check "no password auth"   sh -c "sshd -T | grep -qx 'passwordauthentication no'"
  check "no kbd-interactive" sh -c "sshd -T | grep -qx 'kbdinteractiveauthentication no'"
  check "no X11 forwarding"  sh -c "sshd -T | grep -qx 'x11forwarding no'"
  check "no agent forwarding" sh -c "sshd -T | grep -qx 'allowagentforwarding no'"
}
check_9_firewall() {
  check "ufw active"            sh -c "ufw status | grep -q 'Status: active'"
  check "deny incoming default" sh -c "ufw status verbose | grep -q 'deny (incoming)'"
  check "tailscale0 allowed"    sh -c "ufw status | grep -q 'Anywhere on tailscale0.*ALLOW'"
}
```
`--check-lockdown` adds `permitrootlogin no`, `allowusers rahul` and "no public 22 rule" (Task 8). Run `--check`. Expected: FAIL.

- [ ] **Step 2: Implement `write_sshd_config`, `section_8_ssh` and `section_9_firewall`.**
  - **SSH reload:** decide how to reload SSH on 26.04 (the `ssh.service` vs `ssh.socket` behaviour) and note the reason in a comment.
  - **Firewall order:** set the defaults, add `ufw allow in on tailscale0`, add `ufw allow 22/tcp comment 'temporary: removed by --lockdown'` unless the lockdown marker exists, and only then run `ufw --force enable`.

- [ ] **Step 3: Run stage 1 over the public IP, then `--check`.** Expected: all PASS. From the Mac, both `ssh root@$IP true` and `ssh rahul@$TS_IP true` still succeed. `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@$IP` is refused without prompting for a password.

- [ ] **Step 4: Fill README sections 8 and 9, then commit.** `git commit -m "server: add ssh and firewall stage 1 sections"` (explicit paths)

### Task 7: Phone and iPad keys (Ray, manual)

**Files:**
- Modify: `server/README.md` ("Between stages": the Termius steps)

- [ ] **Step 1: Ray creates the keys.** In Termius on the iPhone and iPad: generate an ED25519 key with Termius cloud key sync off, and send Claude the **public** key text.
- [ ] **Step 2: Add the keys.** Append each one to `~rahul/.ssh/authorized_keys`, from the Mac via `ssh rahul@$TS_IP`. Each key must be a single `ssh-ed25519 ...` line.
- [ ] **Step 3: Ray tests both devices.** Log in from each over the tailnet as `rahul@$NAME` (MagicDNS) or `$TS_IP`. Expected: lands in fish and shows fastfetch.
- [ ] **Step 4: Document and commit.** Write the steps generically in the README (no key material). `git commit -m "server: document mobile key setup"` (explicit paths)

### Task 8: Lockdown (stage 2) and the Hetzner firewall

**Files:**
- Modify: `server/setup.sh`, `server/README.md` (L1, L2, "After lockdown")

**Interfaces:**
- Consumes: `write_sshd_config lockdown`, `STATE_DIR`.
- Produces: `section_L1_ssh_lockdown`, `section_L2_firewall_lockdown`, `check_lockdown`, and `lockdown_guard`. The guard runs as `rahul`, not root. It requires the first field of `$SSH_CONNECTION` to fall in 100.64.0.0/10, and `~rahul/.ssh/authorized_keys` to hold at least one key. Otherwise it dies before any change. On success it writes `$STATE_DIR/lockdown-done`.

- [ ] **Step 1: Write the checks** (run by `--check-lockdown`):
```bash
check_lockdown() {
  check "root login off"     sh -c "sshd -T | grep -qx 'permitrootlogin no'"
  check "only rahul allowed" sh -c "sshd -T | grep -qx 'allowusers rahul'"
  check "no public 22 rule"  sh -c "! ufw show added | grep -q 'allow 22/tcp'"
  check "lockdown recorded"  test -f $STATE_DIR/lockdown-done
}
```
Run `--check-lockdown`. Expected: FAIL.

- [ ] **Step 2: Guard test (Review Focus 2).** Implement `lockdown_guard` first. Over the **public** IP: `scp -r server rahul@$IP: && ssh rahul@$IP bash server/setup.sh --lockdown`. Expected: refuses with a message naming the tailnet requirement, changes nothing, and `--check-lockdown` still FAILs on every lockdown check.

- [ ] **Step 3: Implement L1 and L2.** L1 runs `write_sshd_config lockdown`. L2 deletes the temporary 22 rule. Then write the marker file.

- [ ] **Step 4: Run lockdown over the tailnet.** `scp -r server rahul@$TS_IP: && ssh rahul@$TS_IP bash server/setup.sh --lockdown`, then `ssh rahul@$TS_IP sudo bash server/setup.sh --check-lockdown`. Expected: all PASS.

- [ ] **Step 5: Re-run test (Review Focus 1).** `ssh rahul@$TS_IP sudo bash server/setup.sh $NAME`, then `--check-lockdown`. Expected: still all PASS. Public 22 isn't reopened and root login stays off.

- [ ] **Step 6: Ray's console steps.**
  - **Firewall:** in Hetzner, create a firewall with no inbound rules and attach it to the server. Confirm no other firewall is attached.
  - **Backstop:** reset the root password from the Hetzner console and log in once through the web console.
  - Claude can't do either of these.

- [ ] **Step 7: Fill the README's L1, L2 and "After lockdown" sections, then commit.** `git commit -m "server: add lockdown stage"` (explicit paths)

### Task 9: Final verification and handover

**Files:**
- Modify: `server/README.md` ("Checks"). Off-repo: `~/.ssh/config`, Claude memory.

- [ ] **Step 1: Outside scan (Spec check 1).**
  - **IPv4:** from the Mac, `nmap -Pn -p- $IP`. Expected: every port filtered, none open.
  - **IPv6:** get the server's global address (`ip -6 addr show eth0 scope global`). If the Mac has IPv6 (`curl -6 -s https://ifconfig.co`), run `nmap -6 -Pn -p- <v6>`. Expected: nothing open.
  - **No IPv6 on the Mac:** scan from another machine outside the tailnet, `ssh <another-server>`, using `nc -6 -z -w2` on 22/80/443. Record which vantage point was used.
- [ ] **Step 2: Tailnet and SSH behaviour (Spec checks 2, 3, 7).** From the Mac:
  - `ssh rahul@$TS_IP 'echo $0'` prints `bash` with no fastfetch output.
  - `ssh -t rahul@$TS_IP` lands in fish with fastfetch.
  - `ssh root@$TS_IP true` is refused.
  - `ssh -o PreferredAuthentications=password rahul@$TS_IP` is refused.
  - A temporary listener on 443 (`sudo timeout 20 nc -l 443`) is reachable from the Mac with `nc -z $TS_IP 443`.
- [ ] **Step 3: Reboot test (Review Focus 4).** `ssh rahul@$TS_IP sudo reboot`, wait for it to come back over the tailnet, then run `--check-lockdown` and the Step 2 checks again. Expected: all PASS, with the hostname still `$NAME`.
- [ ] **Step 4: Read the README end to end against the script.** Check that every section number and title matches, every script action has a hand-run command, and no IP, name or token appears in any committed file: `git grep -nF -e "$NAME" -e "$IP" -e "$TS_IP" -e tskey- -- server docs`. Expected: no matches. (Literal IP patterns would false-match `127.0.1.1` and `100.64.0.0/10`, so match the real values.)
- [ ] **Step 5: Commit.** `git commit -m "server: complete hand-run guide and checks"` (explicit paths). Don't push; ask Ray.
- [ ] **Step 6: Off-repo housekeeping.**
  - **SSH config:** in `~/.ssh/config`, replace the old server's block with `Host $NAME`, `HostName $TS_IP`, `User rahul`.
  - **Claude memory:** rename the old server's memory file to `$NAME.md` and rewrite it for the new state. Update `servers.md` and `MEMORY.md`.
  - **Report:** tell Ray the results, including the stale Windows desktop still on the tailnet.
