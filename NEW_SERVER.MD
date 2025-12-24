# Ray's New Ubuntu Server Setup

This setup is designed to help me setup a new Ubuntu Server from scratch, the last update was based on Ubuntu 24.04.

## Initial Scripts

Update the system, let's make sure we're up to date.

```bash
sudo apt update && sudo apt dist-upgrade
```

Let's list the running services, some obvious ones to kill are below.

```bash
sudo systemctl list-units --type=service --state=running
```


1. packagekit.service
2. snapd.service
3. snap.canonical-livepatch.canonical-livepatchd.service

These are all around automatic GUI updates or Snap updates. We don't need either.

Add a new user:

```bash
adduser rahul
usermod -aG sudo rahul
```

## SSH Security

Edit `/etc/ssh/sshd_config`

Update `Port` to a new port. (30082)

```
Port 30082
```

Restart the SSH Service
```bash
sudo systemctl restart ssh.service
```

Replace the contents of `/etc/issue.net`

```
ALERT! You are entering a secured area! Your IP, Login Time, and Username have been noted and have been sent to the server administrator!
This service is restricted to authorized users only. All activities on this system are logged.
Unauthorized access will be fully investigated and reported to the appropriate law enforcement agencies.
```

Update the SSH config to show the new banner

```
# no default banner path
#Banner none
```

Append your SSH public key (`~/.ssh/id_xxx.pub`) to the authorized keys file:

```bash
~/.ssh/authorized_keys
```

Disable Root Login with password

```
PermitRootLogin prohibit-password
```

Disable all logins without password

```
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes 
```

## UFW (Firewall)

Install UFW

```bash
sudo apt install ufw
```

Set some sensible defaults
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

Allow the essentials
```bash
sudo ufw allow 30082/tcp    # Custom SSH
sudo ufw allow 53/udp       # DNS (if applicable)
sudo ufw allow 9001/tcp     # Example: application service
```

Enable UFW
```bash
sudo ufw enable
```

## Fail2Ban

Install Fail2Ban

```bash
sudo apt install fail2ban
```

Configure Fail2Ban locally

```bash
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo nano /etc/fail2ban/jail.local
```

Update the SSH protection

```bash
[sshd]
enabled = true
port    = 30082
logpath = %(sshd_log)s
backend = %(sshd_backend)s
```

Enable Fail2Ban

```bash
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

Check Fail2Ban

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

## Lynis

When you're bored, run Lynis for an up to date view:

```bash
(cd ~ && sudo rm -rf ~/lynis && mkdir lynis && git clone https://github.com/CISOfy/lynis --depth=1 && sudo chown -R 0:0 lynis && cd lynis && sudo ./lynis audit system --pentest && cd ~ && sudo rm -rf ~/lynis)
```
