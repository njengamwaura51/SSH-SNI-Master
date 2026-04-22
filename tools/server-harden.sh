#!/usr/bin/env bash
# tools/server-harden.sh — idempotent security hardening for the tunnel droplet.
# Safe to re-run. Coexists with shopthelook.page nginx + the tunnel stack.
#
# Run via:
#   sudo bash /opt/sni-hunter-src/tools/server-harden.sh
#   sudo /opt/sni-hunter-src/tools/server-install.sh harden
#   tunnel-tui → 10
#
# Will configure: unattended-upgrades, ufw (allow 22/80/443/445/10000/10001),
# fail2ban (sshd + nginx jails), sysctl (BBR + syncookies + martians),
# sshd hardening (drop-in only — never edits /etc/ssh/sshd_config), tunnel
# group + per-user limits.
#
# Will NOT disable password auth (would lock out tunnel customers) and will
# NOT touch PermitRootLogin (you opt in manually via SSH key first).

set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "needs root — re-run with sudo" >&2; exit 1; }

# Tunnel ports — keep in sync with the existing nginx + stunnel + dropbear setup.
TUNNEL_PORTS=(22/tcp 80/tcp 443/tcp 445/tcp 10000/tcp 10001/tcp)

log() { printf '\e[1;36m  ➜\e[0m %s\n' "$*"; }
hdr() { printf '\n\e[1;33m=== %s ===\e[0m\n' "$*"; }
ok()  { printf '\e[1;32m  ✓\e[0m %s\n' "$*"; }
warn(){ printf '\e[1;31m  ! \e[0m %s\n' "$*"; }

# ----------------------------------------------------------- 1. unattended --
hdr "1. Unattended security upgrades"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled"

# ------------------------------------------------------------- 2. ufw -------
hdr "2. ufw firewall (default deny + tunnel port allow list)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
for p in "${TUNNEL_PORTS[@]}"; do
  ufw allow "$p" >/dev/null
  ok "allow $p"
done
# Burst-protect 22 against scanners
ufw limit 22/tcp >/dev/null
ok "rate-limit 22/tcp (ufw limit)"
ufw --force enable >/dev/null
ok "ufw enabled"

# --------------------------------------------------------- 3. fail2ban ------
hdr "3. fail2ban (sshd + nginx jails)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
install -d /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/tunnel.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = 22
mode    = aggressive

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 1
fail2ban-client status >/dev/null 2>&1 && ok "fail2ban active" || warn "fail2ban not yet ready"

# ---------------------------------------------------------- 4. sysctl -------
hdr "4. sysctl tuning (BBR + syncookies + martians)"
cat > /etc/sysctl.d/99-tunnel.conf <<'EOF'
# tunnel-droplet hardening — managed by server-harden.sh
net.ipv4.tcp_syncookies              = 1
net.ipv4.tcp_max_syn_backlog         = 8192
net.core.somaxconn                   = 4096
net.core.netdev_max_backlog          = 16384
net.ipv4.tcp_congestion_control      = bbr
net.core.default_qdisc               = fq
net.ipv4.tcp_fastopen                = 3
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.conf.all.log_martians       = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects   = 0
kernel.kptr_restrict                 = 2
kernel.dmesg_restrict                = 1
fs.protected_hardlinks               = 1
fs.protected_symlinks                = 1
EOF
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null 2>&1
ok "sysctl applied (current cc: $(sysctl -n net.ipv4.tcp_congestion_control))"

# ----------------------------------------------------- 5. tunnel group ------
hdr "5. tunnel group + per-user limits"
groupadd -f tunnel
local_added=0
while IFS=: read -r u _ uid _ _ _ shell; do
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65000 ] && [ "$shell" = /bin/false ]; then
    if ! id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx tunnel; then
      usermod -aG tunnel "$u" && local_added=$((local_added+1))
    fi
  fi
done < /etc/passwd
ok "tunnel group ensured (added ${local_added} existing /bin/false user(s))"

cat > /etc/security/limits.d/tunnel.conf <<'EOF'
# Per-user resource caps for tunnel customers — managed by server-harden.sh
@tunnel  hard  nproc      100
@tunnel  soft  nproc      80
@tunnel  hard  nofile     4096
@tunnel  soft  nofile     2048
@tunnel  hard  maxlogins  10
EOF
ok "limits.conf caps installed for @tunnel"

# --------------------------------------------------------- 6. sshd ----------
hdr "6. sshd hardening (drop-in /etc/ssh/sshd_config.d/99-tunnel-harden.conf)"
cat > /etc/ssh/sshd_config.d/99-tunnel-harden.conf <<'EOF'
# Tunnel-droplet sshd hardening — managed by server-harden.sh
# (Drop-in: original /etc/ssh/sshd_config is left untouched.)
Protocol 2
LoginGraceTime 30
MaxAuthTries 4
MaxSessions 10
ClientAliveInterval 60
ClientAliveCountMax 3
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
PrintLastLog yes
TCPKeepAlive yes
# Tunnel users have /bin/false — they may forward TCP but cannot exec a shell.
AllowTcpForwarding yes
PermitTunnel no
EOF
chmod 0644 /etc/ssh/sshd_config.d/99-tunnel-harden.conf
if sshd -t 2>&1; then
  systemctl reload ssh && ok "sshd reloaded with hardened drop-in"
else
  warn "sshd config test FAILED — drop-in left in place but NOT reloaded"
fi

# ---------------------------------------------------- 7. permission audit --
hdr "7. permission audit on sensitive paths"
chmod 700 /etc/cron.d /etc/sudoers.d 2>/dev/null || true
chmod 600 /etc/sudoers 2>/dev/null || true
chmod 700 /root 2>/dev/null || true
[ -d /root/cards ] && chmod 700 /root/cards && chmod 600 /root/cards/* 2>/dev/null
ok "tightened cron.d / sudoers.d / /root / cards perms"

# ---------------------------------------------------------- 8. summary ------
hdr "8. Status summary"
echo "  --- ufw ---"
ufw status verbose | sed 's/^/  /'
echo
echo "  --- fail2ban jails ---"
fail2ban-client status 2>/dev/null | sed 's/^/  /'
echo
echo "  --- congestion control ---"
echo "    $(sysctl -n net.ipv4.tcp_congestion_control)  (qdisc: $(sysctl -n net.core.default_qdisc))"

cat <<EON

  Hardening pass complete. Recommended manual follow-ups (NOT done automatically
  to avoid lock-outs):

    1) Add an ed25519 SSH key to /root/.ssh/authorized_keys
    2) Once verified you can log in by key, optionally disable root password
       login by editing /etc/ssh/sshd_config.d/99-tunnel-harden.conf and
       adding:  PermitRootLogin prohibit-password
       Then:  sshd -t && systemctl reload ssh
    3) Re-run:  sudo tunnel-tui → 1  to confirm all services still healthy.

EON
