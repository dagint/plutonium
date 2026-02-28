# Ansible VPS Hardening Reference

Concrete task patterns for reviewing Ansible playbooks that provision and harden VPS servers.

---

## SSH Hardening

### Expected Configuration

```yaml
# Role: ssh-hardening/tasks/main.yml
- name: Configure SSH daemon
  ansible.builtin.template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: '0600'
    validate: '/usr/sbin/sshd -t -f %s'  # Validate before applying!
  notify: Restart sshd

# Role: ssh-hardening/templates/sshd_config.j2
# Minimum secure sshd_config settings:
Port {{ ssh_port | default(22) }}
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
MaxAuthTries 3
LoginGraceTime 30
AllowUsers {{ ssh_allowed_users | join(' ') }}
ClientAliveInterval 300
ClientAliveCountMax 2
```

### Anti-patterns

```yaml
# CRITICAL — root login allowed
- name: Configure SSH
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^PermitRootLogin'
    line: 'PermitRootLogin yes'

# HIGH — password auth enabled (brute-force target)
- name: Configure SSH
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^PasswordAuthentication'
    line: 'PasswordAuthentication yes'

# MEDIUM — using lineinfile for sshd_config (fragile, hard to audit)
# Use template instead for the complete config
- name: Set SSH port
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^Port'
    line: 'Port 2222'
# Dozens more lineinfile tasks follow...

# FIXED — single template for complete, auditable config
- name: Deploy hardened SSH config
  ansible.builtin.template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    validate: '/usr/sbin/sshd -t -f %s'
  notify: Restart sshd
```

---

## Firewall (UFW)

```yaml
# Expected: default deny + explicit allow
- name: Set UFW default deny incoming
  community.general.ufw:
    direction: incoming
    default: deny

- name: Set UFW default allow outgoing
  community.general.ufw:
    direction: outgoing
    default: allow

- name: Allow SSH
  community.general.ufw:
    rule: allow
    port: "{{ ssh_port }}"
    proto: tcp
    src: "{{ item }}"
  loop: "{{ ssh_allowed_cidrs }}"  # Restrict SSH to known IPs if possible

- name: Allow HTTP/HTTPS
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
  loop:
    - "80"
    - "443"

- name: Enable UFW
  community.general.ufw:
    state: enabled
    logging: "on"
```

Anti-patterns:
```yaml
# HIGH — blanket allow on non-web port
- name: Allow all traffic on port 5432
  community.general.ufw:
    rule: allow
    port: "5432"
    # Missing src restriction — DB open to internet!

# MEDIUM — firewall disabled or not enabled
# Check that UFW is enabled and starts on boot

# HIGH — using shell instead of module
- name: Configure firewall
  ansible.builtin.shell: |
    ufw allow 22
    ufw allow 80
    ufw allow 443
    ufw --force enable
  # Not idempotent, no error handling, harder to audit
```

---

## fail2ban

```yaml
- name: Install fail2ban
  ansible.builtin.apt:
    name: fail2ban
    state: present

- name: Configure fail2ban for SSH
  ansible.builtin.template:
    src: jail.local.j2
    dest: /etc/fail2ban/jail.local
    owner: root
    group: root
    mode: '0644'
  notify: Restart fail2ban

# jail.local.j2
# [DEFAULT]
# bantime = 3600
# findtime = 600
# maxretry = 5
# banaction = ufw
#
# [sshd]
# enabled = true
# port = {{ ssh_port }}
# maxretry = 3
# bantime = 86400

- name: Enable and start fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    state: started
    enabled: true
```

Flag if fail2ban is missing entirely — it's a baseline control for any internet-facing VPS.

---

## Automatic Security Updates

```yaml
- name: Install unattended-upgrades
  ansible.builtin.apt:
    name:
      - unattended-upgrades
      - apt-listchanges
    state: present

- name: Configure unattended-upgrades
  ansible.builtin.template:
    src: 50unattended-upgrades.j2
    dest: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root
    group: root
    mode: '0644'

- name: Enable auto-upgrade timer
  ansible.builtin.template:
    src: 20auto-upgrades.j2
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root
    group: root
    mode: '0644'

# 20auto-upgrades.j2
# APT::Periodic::Update-Package-Lists "1";
# APT::Periodic::Unattended-Upgrade "1";
# APT::Periodic::AutocleanInterval "7";
```

---

## User Management

```yaml
# Expected: dedicated deploy user with limited sudo
- name: Create deploy user
  ansible.builtin.user:
    name: deploy
    shell: /bin/bash
    create_home: true
    groups: docker  # Only if Docker is needed
    append: true

- name: Set authorized key for deploy user
  ansible.posix.authorized_key:
    user: deploy
    key: "{{ deploy_ssh_public_key }}"
    exclusive: true  # Remove all other keys

- name: Configure sudo for deploy user
  ansible.builtin.template:
    src: sudoers_deploy.j2
    dest: /etc/sudoers.d/deploy
    owner: root
    group: root
    mode: '0440'
    validate: '/usr/sbin/visudo -cf %s'  # Always validate sudoers!

# sudoers_deploy.j2
# deploy ALL=(ALL) NOPASSWD: /usr/bin/docker compose *, /usr/bin/systemctl restart app
# (Specific commands only, NOT blanket NOPASSWD: ALL)
```

Anti-patterns:
```yaml
# CRITICAL — blanket NOPASSWD for everything
- name: Give deploy user sudo
  ansible.builtin.lineinfile:
    path: /etc/sudoers
    line: 'deploy ALL=(ALL) NOPASSWD: ALL'
    # Never edit /etc/sudoers directly — use /etc/sudoers.d/
    # Never grant blanket NOPASSWD

# HIGH — no sudoers validation
- name: Configure sudo
  ansible.builtin.copy:
    content: 'deploy ALL=(ALL) NOPASSWD: /usr/bin/docker'
    dest: /etc/sudoers.d/deploy
    # Missing: validate: '/usr/sbin/visudo -cf %s'
    # Syntax error in sudoers = locked out of sudo!
```

---

## Kernel Hardening (sysctl)

```yaml
- name: Apply kernel security parameters
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_set: true
    state: present
    reload: true
  loop:
    # Network security
    - { key: 'net.ipv4.conf.all.rp_filter', value: '1' }
    - { key: 'net.ipv4.conf.default.rp_filter', value: '1' }
    - { key: 'net.ipv4.icmp_echo_ignore_broadcasts', value: '1' }
    - { key: 'net.ipv4.conf.all.accept_source_route', value: '0' }
    - { key: 'net.ipv4.conf.default.accept_source_route', value: '0' }
    - { key: 'net.ipv4.conf.all.accept_redirects', value: '0' }
    - { key: 'net.ipv4.conf.default.accept_redirects', value: '0' }
    - { key: 'net.ipv4.conf.all.send_redirects', value: '0' }
    - { key: 'net.ipv4.conf.default.send_redirects', value: '0' }
    - { key: 'net.ipv4.conf.all.log_martians', value: '1' }
    - { key: 'net.ipv4.tcp_syncookies', value: '1' }
    # Kernel security
    - { key: 'kernel.randomize_va_space', value: '2' }
    - { key: 'kernel.sysrq', value: '0' }
    - { key: 'kernel.core_uses_pid', value: '1' }
    - { key: 'fs.suid_dumpable', value: '0' }
    # IPv6 (disable if not used)
    - { key: 'net.ipv6.conf.all.disable_ipv6', value: '1' }
    - { key: 'net.ipv6.conf.default.disable_ipv6', value: '1' }
```

---

## Ansible-Specific Anti-Patterns

### Plaintext Secrets

```yaml
# CRITICAL — plaintext password in vars
vars:
  db_password: "supersecret123"
  api_key: "sk-abc123def456"

# FIXED — use ansible-vault
# Encrypt the vars file:
#   ansible-vault encrypt group_vars/production/vault.yml
# Reference in playbook:
vars_files:
  - group_vars/production/vault.yml
# Where vault.yml contains (encrypted):
#   vault_db_password: "supersecret123"
# And the variable is referenced as:
#   db_password: "{{ vault_db_password }}"
```

### Idempotency Violations

```yaml
# MEDIUM — shell command with no idempotency control
- name: Create application directory
  ansible.builtin.shell: mkdir -p /opt/app && chown deploy:deploy /opt/app
  # Runs every time, always reports "changed"

# FIXED — use proper modules
- name: Create application directory
  ansible.builtin.file:
    path: /opt/app
    state: directory
    owner: deploy
    group: deploy
    mode: '0755'

# If shell/command is unavoidable, use guards:
- name: Initialize database
  ansible.builtin.shell: /opt/app/init-db.sh
  args:
    creates: /opt/app/.db_initialized  # Only runs if file doesn't exist
  register: db_init
  changed_when: db_init.rc == 0
```

### Missing FQCN

```yaml
# MEDIUM — short module names (ambiguous, deprecated style)
- name: Install packages
  apt:
    name: nginx
- copy:
    src: nginx.conf
    dest: /etc/nginx/nginx.conf
- service:
    name: nginx
    state: started

# FIXED — fully qualified collection names
- name: Install packages
  ansible.builtin.apt:
    name: nginx
    state: present
- ansible.builtin.copy:
    src: nginx.conf
    dest: /etc/nginx/nginx.conf
- ansible.builtin.service:
    name: nginx
    state: started
    enabled: true
```

### Blanket become

```yaml
# MEDIUM — entire play runs as root
- hosts: webservers
  become: true  # Every task runs as root
  tasks:
    - name: Read log file  # Doesn't need root
      ansible.builtin.command: cat /var/log/app/access.log
    - name: Deploy app config  # Doesn't need root
      ansible.builtin.copy:
        src: app.conf
        dest: /home/deploy/app/config.yml
        owner: deploy

# FIXED — become only where needed
- hosts: webservers
  tasks:
    - name: Install packages
      ansible.builtin.apt:
        name: nginx
      become: true  # This task needs root

    - name: Deploy app config
      ansible.builtin.copy:
        src: app.conf
        dest: /home/deploy/app/config.yml
        owner: deploy
      # No become — runs as connection user
```

### Ignoring Errors

```yaml
# HIGH — silently ignoring failures
- name: Stop old service
  ansible.builtin.systemd:
    name: legacy-app
    state: stopped
  ignore_errors: yes  # What if it fails for a real reason?

# FIXED — handle the specific expected condition
- name: Check if legacy service exists
  ansible.builtin.systemd:
    name: legacy-app
  register: legacy_service
  failed_when: false  # Don't fail, just capture state

- name: Stop legacy service if it exists
  ansible.builtin.systemd:
    name: legacy-app
    state: stopped
  when: legacy_service.status.ActiveState is defined
```

---

## Ansible Linting

Recommend `ansible-lint` in CI. Key rules to watch for:

| Rule | What It Catches |
|------|----------------|
| `command-instead-of-module` | Using shell/command when a module exists |
| `no-changed-when` | shell/command without changed_when |
| `yaml[truthy]` | `yes`/`no` instead of `true`/`false` |
| `name[missing]` | Tasks without names |
| `risky-shell-pipe` | Pipes in shell without pipefail |
| `no-free-form` | Free-form module syntax |
| `fqcn[action-core]` | Missing FQCN for core modules |
| `var-naming` | Variables not following naming conventions |

GitHub Actions integration:
```yaml
- name: Lint Ansible
  uses: ansible/ansible-lint@SHA
  with:
    args: "playbooks/ roles/"
```
