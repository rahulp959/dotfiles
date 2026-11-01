# Server setup: Tailscale-only, lightly hardened Ubuntu

Date: 2026-11-01
Status: approved by Ray, 2026-11-01

## Intent

Ray needs a repeatable way to turn a fresh Hetzner Cloud server into a private, general-purpose box that only Ray's own devices can reach, over Tailscale. The previous approach (an Ansible project) was too heavy to read and maintain. This replaces it with one readable script plus a hand-run guide covering the same steps, so a future server can be built either way.

The first server it will be used on is an existing Hetzner VPS that was just re-imaged (Ubuntu 26.04.1, only `root` can log in, by SSH key, on the public IP). That server is being repurposed from a single app to general use and will be renamed.

## Goals

1. Nobody on the internet can reach any port on the server.
2. Ray's devices on the tailnet (Mac, iPhone, iPad) can reach the server on any port, including 22, 80 and 443.
3. Getting a shell needs two independent things: a device on Ray's tailnet AND a private SSH key.
4. Security updates install automatically, and the server restarts itself when an update needs it.
5. Rebuilding a server later is quick, by script or by hand.

## Non-goals

- Limiting which ports tailnet devices can reach. Ray decided (2026-11-01) that tailnet traffic may hit any port, so there is no tailnet policy change and no tag.
- A web server, TLS certificates or any app. 80/443 are reachable on the tailnet only so a future app can use them. (Note for later: tailnet-only sites can't use the normal Let's Encrypt HTTP check; Tailscale-issued `*.ts.net` certificates are the likely route.)
- Monitoring, metrics, backups, Docker.
- Changing other servers, or Ray's tailnet policy.

## Anti-goals (failure even if it "works")

- **Locking Ray out.** Public SSH must stay open until SSH over Tailscale is proven from the Mac AND a phone.
- **Secrets or identifying details in the repo.** The repo (`dotfiles`) is public. No auth keys, Ubuntu Pro tokens, private keys, IP addresses or real server names in the script, the guide or this document.
- **Drift back towards a framework.** No Ansible, roles, inventories or templating. One bash script, readable top to bottom.
- **Using the old `NEW_SERVER.MD` as a source.** Ray has asked that nothing from it is kept. The new guide replaces it; it is deleted.

## Approaches considered

- **A. Hand-run checklist only.** Lightest, nothing to maintain, but every rebuild is manual and drifts.
- **B. One idempotent bash script, plus a short checklist for the console steps.** Recommended: likely future rebuilds become a ten-minute job, and it stays readable.
- **C. cloud-init at server creation.** Most hands-off, but needs another re-image, runs once at first boot (hard to fix), and the Tailnet Lock signing step is manual anyway.

**Chosen: B, with A's documentation as well.** The script does the work; a guide (`server/README.md`) documents every step as plain commands so it can be repeated by hand without the script.

## Decisions made with Ray

- **Exposure:** no public ports at all. From the tailnet, any port is fine.
- **Login:** user `rahul`, passwordless sudo. Root cannot log in over SSH.
- **SSH authentication:** normal OpenSSH with keys, over Tailscale. **Not** Tailscale SSH, because Tailscale SSH would make the Tailscale account the only thing protecting the server.
- **Keys:** one per device (Mac's existing key, plus a key generated inside Termius on the iPhone and the iPad, with Termius cloud key sync off).
- **Tailnet Lock:** already enabled on Ray's tailnet. New nodes must be signed from a trusted device.
- **Updates:** automatic security updates with automatic restarts.
- **Clock:** the server stays on UTC.
- **Swap:** add a swap file (the Hetzner image has none).
- **SSH forwarding:** X11 forwarding and agent forwarding off.
- **Login/apt adverts:** Ubuntu's "news" on login (`motd-news`) and in apt output (`apt_news`) switched off.
- **Ubuntu Pro:** the server is attached to Ray's free personal Ubuntu Pro subscription, with Livepatch, ESM Infra and ESM Apps enabled. Keep all three.
- **Shell:** fish for Ray's interactive logins, bash for everything else. `rahul`'s login shell stays bash; a few lines in `~/.bashrc` `exec fish` only for interactive sessions (not for `ssh host 'cmd'`, scripts, or when fish is missing). Plain fish from Ubuntu's packages, none of the Mac's fish config.
- **nvm.fish:** installed for `rahul` so Ray can install Node later. Node itself is not installed by the setup.
- **Plugin updates:** easy updating on the running server matters more to Ray than pinning. nvm.fish is installed through fisher, and `fisher update` updates nvm.fish and fisher itself, the same as on the Mac. Updates are manual (Ray runs them), not automatic.
- **Server stats on login:** fastfetch (from Ubuntu's packages) runs as fish's greeting, so it shows on every interactive login and never in scripts or `ssh host 'cmd'`.
- **Location:** `dotfiles` repo, in a `server/` folder.
- **Rename:** the server becomes general-purpose and gets a new name (chosen by Ray before the build; written as `<NAME>` here).

## Calls made by Claude (Ray to check)

- **Two firewall layers against the internet.** Hetzner Cloud Firewall with **no inbound rules** (blocks everything from the internet before it reaches the server), plus `ufw` on the server denying all incoming traffic except on the `tailscale0` interface. Each layer covers a mistake in the other. Tailscale needs no inbound rule: it connects outwards, and the Hetzner firewall is stateful.
- **Tailscale key expiry:** the server joins as Ray's own device (no tag), so its key expiry is turned off by hand in the admin console.
- **No fail2ban, no non-standard SSH port.** With no public ports there is nothing for them to defend.
- **Restart time:** 04:00 server time (UTC), restarting even if a user is logged in.
- **Tailscale login:** interactive (`tailscale up` prints a login URL Ray opens), not an auth key. No secret ever needs handling.
- **Tailscale install:** Tailscale's official apt repository with its signing key (not `curl | sh`).
- **Lockout backstop:** Hetzner's web console. Fresh Hetzner images have no root password; the guide includes resetting it once from the Hetzner console and confirming a console login works.
- **Initial `rahul` key:** copied from `/root/.ssh/authorized_keys`, which Hetzner populates with the key chosen at server creation (Ray's Mac key). Phone/iPad public keys are appended afterwards.
- **How the script reaches the server:** run from the Mac's checkout, e.g. `ssh root@<public-ip> 'bash -s' -- <args> < server/setup.sh`. Nothing is fetched from the internet at run time except signed apt packages and the fisher plugins (below).
- **fisher bootstrap:** the script downloads `fisher.fish` from one tagged fisher release, verifies it against a SHA-256 written in the script, then runs (as `rahul`, in fish) `fisher install jorgebucaran/fisher jorgebucaran/nvm.fish`. That writes `~rahul/.config/fish/fish_plugins` listing both, so fisher manages itself from then on. Accepted trade-off: fisher installs and `fisher update` fetch the latest code from GitHub with no checksum, trusting the plugin author's account, the same trust the Mac already places in them. The builder picks the fisher release at build time.
- **fastfetch configuration:** see "Login stats" below.
- **Who counts as "Ray's devices":** every device on the tailnet. Checked 2026-11-01: the tailnet holds only Ray's Mac, iPhone, iPad and one stale Windows desktop (offline 260+ days, worth removing). No other servers or shared devices, so no per-device restriction is needed.
- **Tailscale updates:** Tailscale's own repo isn't covered by Ubuntu's security-only automatic updates. Turn on Tailscale's built-in auto-update (`tailscale set --auto-update`) so the only way in never goes stale. The Hetzner web console is the backstop if an update ever breaks it.
- **Keep snapd.** Livepatch's client is a snap, so snapd stays. No other snaps are added.
- **Ubuntu Pro on future rebuilds:** attaching needs Ray's Pro token, which is a secret. The script never takes it as an argument or stores it; the guide has Ray run `pro attach` by hand (it prompts), then the script checks Livepatch is enabled. Automatic updates must include the ESM security origins (Ubuntu's default unattended-upgrades config does; the builder confirms it).
- **Swap size:** 2 GB swap file at `/swapfile`, with default swappiness.
- **Who does what:** Ray does every Hetzner and Tailscale admin-console step (Claude has no access to either). Claude runs the scripts over SSH and the Mac-side `tailscale lock sign`.

## Login stats (fastfetch)

Ray's brief: the Ubuntu logo, and as much output as is possible and sensible, because it's fun. Ray accepts that the logo wraps on an iPhone in portrait.

Config lives in `~rahul/.config/fastfetch/config.jsonc` (in the repo as `server/fastfetch.jsonc`, copied by the script). Default full-size Ubuntu logo. No `lolcat`.

**Rule: the whole run takes under 0.5 s, and nothing touches the network.** It runs on every interactive login, so a slow or hanging module makes every login slow or hang. The builder times each custom command on the server and drops any that break the budget.

**Modules, in order:**

| Group | Modules |
|---|---|
| Identity | title (`rahul@<NAME>`), separator, OS, host (Hetzner's virtual machine model), kernel, init system, locale, date and time (UTC) |
| Health | uptime, load average, processes, logged-in users, CPU (model and vCPUs), CPU usage, memory, swap, disk (`/` only) |
| Network | local IPs for `tailscale0` and `eth0`, each labelled |
| Software | packages (apt and snap counts), shell |
| Custom (`command` modules) | **Tailscale** (this node's tailnet IP, `tailscale ip -4`), **Reboot** (pending or not, from `/var/run/reboot-required`), **Livepatch** (`canonical-livepatch status`, a one-word state), **Ubuntu Pro** (attached or not, from `pro status --format json`), **Updates** (pending security updates, from Ubuntu's `apt-check`), **Last auto-update** (date of the last unattended-upgrades run, from its log) |
| Finish | colour palette blocks |

**Left out on purpose:** public IP (needs a network call), GPU, display, desktop environment, window manager, theme, icons, font, cursor, terminal, battery, Wi-Fi, Bluetooth, sound, media. On a headless server over SSH they're empty or meaningless.

**Builder notes:** some custom commands may need root to read their source (Livepatch status, the unattended-upgrades log). If one does, show it another way that doesn't need root (e.g. a world-readable status file), or drop it. Don't grant `rahul` sudo exceptions for a login banner. Each custom command must fail quietly (show "unknown", never an error or a hang).

## Lockout-safe order

The script has two stages; the second is only run by hand after verification.

**Before the script (console and Mac):**
1. Rename the server in the Hetzner console to `<NAME>` (cloud-init may reset the OS hostname to the Hetzner name at boot, so this must match).
2. Delete the old, offline device for this server from the Tailscale admin console. (First build: already done; confirmed 2026-11-01.)
3. Confirm the Mac is a trusted Tailnet Lock signing device (`tailscale lock status`). (First build: confirmed 2026-11-01.)
4. In the Hetzner console, check for firewalls still attached from a previous build and detach them. Re-imaging keeps attached firewalls, and the allow rules of every attached firewall add together, so a leftover one would undo the "no inbound rules" firewall.
5. Attach Ubuntu Pro by hand as root (`pro attach`, which prompts for the token), and enable Livepatch if it isn't already. (First build: already attached, with Livepatch, ESM Infra and ESM Apps enabled; confirmed 2026-11-01.)

**Stage 1, `setup.sh <NAME>` as root over public SSH:**
- Set hostname to `<NAME>` and update `/etc/hosts`.
- Full package upgrade.
- Add the 2 GB swap file and make it permanent (`/etc/fstab`).
- Switch off `motd-news` and Ubuntu Pro's `apt_news`.
- Create `rahul`, passwordless sudo via `/etc/sudoers.d/`, copy root's authorized keys.
- Install fish and fastfetch; add the interactive hand-off to `~rahul/.bashrc`; set fastfetch as fish's greeting; bootstrap fisher (checksum-verified) and install nvm.fish through it for `rahul`.
- Configure automatic security updates with automatic restart at 04:00.
- Install Tailscale from the official repo; run `tailscale up` (interactive login URL). Tailscale SSH stays off.
- SSH hardening that can't lock Ray out yet: keys only, no passwords, no keyboard-interactive, no X11 or agent forwarding. Root login stays allowed (key only) for now.
- ufw: deny incoming by default; allow everything in on `tailscale0`; **temporarily** allow 22 from anywhere.

**Between stages (Mac and phones):**
- Sign the new node from the Mac (`tailscale lock sign <nodekey>`); disable its key expiry in the admin console.
- `ssh rahul@<NAME>` over the tailnet from the Mac; confirm `sudo` works.
- Generate a key in Termius on the iPhone and iPad; append both public keys to `~rahul/.ssh/authorized_keys`; log in from each.

**Stage 2, `setup.sh --lockdown` as `rahul` with sudo, over the tailnet:**
- SSH: no root login; only `rahul` allowed.
- ufw: remove the temporary public 22 rule.

**After stage 2:** attach the Hetzner firewall (no inbound rules). Reset the root password in the Hetzner console and confirm the web-console login works once.

## Checks (end of script and guide; stop if any fail)

1. **From the internet:** a port scan of the public IP (IPv4 and IPv6) from outside the tailnet finds nothing open. This is the most important check: it tests both firewall layers from an attacker's point of view.
2. **From the tailnet:** SSH works on the Tailscale address, and a temporary listener on 443 (nothing serves it yet) is reachable; remove the listener afterwards.
3. **SSH:** `root` login fails; password login fails; `rahul` with a key works.
4. **Settings in force:** `sshd -T` shows no password auth, no root login, `AllowUsers rahul`, no X11 or agent forwarding.
5. **Updates:** an unattended-upgrades dry run succeeds, includes the ESM origins, and automatic restart is on; Tailscale auto-update is on; `canonical-livepatch status` shows it running.
6. **Basics:** `swapon --show` lists the 2 GB swap file; the clock is UTC.
7. **Shell:** an interactive SSH login as `rahul` lands in fish, shows the fastfetch stats (with logo, in under 0.5 s; time it with `time fastfetch`), `nvm --version` works there, and `fisher list` shows fisher and nvm.fish; `ssh rahul@<NAME> 'echo $0'` reports bash and prints no fastfetch output.

## Repository layout

```
dotfiles/
  server/
    setup.sh      the script (stage 1, and stage 2 via --lockdown)
    fastfetch.jsonc  login stats config, copied to ~rahul/.config/fastfetch/config.jsonc
    README.md     the hand-run guide: same steps as plain commands, numbered to match the script's sections, plus the console/Mac/phone steps and the checks
  NEW_SERVER.MD   deleted
```

The guide and the script must stay in step: each script section is a function with the same number and title as the guide section.

## Left to the builder

- Exact sshd drop-in file name and ordering (Ubuntu cloud images ship `50-cloud-init.conf`; sshd uses the first value it reads, so the hardening file must sort earlier). Validate with `sshd -t` before reloading.
- How to reload SSH on Ubuntu 26.04 (socket activation via `ssh.socket` vs `ssh.service`).
- Whether Tailscale's apt repo has a build for Ubuntu 26.04 ("resolute"), and the fallback if not.
- Making every step safe to re-run.
- Post-build housekeeping on Ray's Mac (SSH config alias, Claude memory notes); not part of the public repo.
