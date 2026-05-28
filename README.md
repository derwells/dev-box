# Dev Box

Remote development server for Claude Code, accessible via Tailscale SSH from laptop and phone. Includes a desktop environment for visual verification via noVNC in a browser.

Provisioned with OpenTofu on Hetzner Cloud. One command to create, one to destroy.

## Stack

```
Hetzner CPX31 (4 vCPU, 8GB RAM, ~$12/mo)
Ubuntu Server 24.04
├── Tailscale          — private mesh networking, no public ports
├── Claude Code        — Node.js + npm
├── Playwright         — headless browser for automated screenshots
├── XFCE4             — lightweight desktop (~200MB)
├── TigerVNC          — serves the desktop session
├── noVNC             — web-based VNC client (browser tab on laptop/phone)
└── Chromium          — for manual visual verification
```

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) installed locally
- [Hetzner CLI](https://github.com/hetznercloud/cli) (`hcloud`) for server management
- A [Hetzner Cloud](https://console.hetzner.cloud) account with an API token
- [Tailscale](https://tailscale.com) account (free for personal use)
- An SSH key pair (`~/.ssh/id_ed25519` by default)

## Setup

### 1. Create your config

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with:
- Your Hetzner API token (create at Hetzner Console → Security → API Tokens)
- Optionally, a [Tailscale auth key](https://login.tailscale.com/admin/settings/keys) for automatic device registration

### 2. Set up Hetzner CLI

```bash
hcloud context create dev-box    # paste your Hetzner API token when prompted
```

### 3. Deploy

```bash
tofu init
tofu apply
```

This creates the server and runs cloud-init, which installs everything. Takes ~5 minutes.

### 4. Post-deploy (one-time)

If you didn't provide a Tailscale auth key:

```bash
ssh <username>@<public-ip>    # from tofu output
sudo tailscale up --ssh
```

Approve the device in the [Tailscale admin console](https://login.tailscale.com/admin/machines).

Log in to Claude Code:

```bash
claude login                  # open URL in browser, paste code back
```

Set a VNC password and start the desktop:

```bash
vncpasswd                     # set password, say "no" to view-only
sudo systemctl enable --now vncserver@1 novnc
```

### 5. Connect

Add to `~/.ssh/config` on your laptop:

```
Host dev-box
    HostName <tailscale-ip-or-hostname>
    User derick
    ForwardAgent yes
```

| From   | Method                                  | Use case                      |
|--------|-----------------------------------------|-------------------------------|
| Laptop | `ssh dev-box`                           | Claude Code, terminal work    |
| Laptop | `http://<tailscale-ip>:6080` in browser | Visual verification, browsing |
| Phone  | SSH app via Tailscale                   | Quick checks, monitoring      |
| Phone  | `http://<tailscale-ip>:6080` in browser | Visual verification           |

## Server Management

```bash
hcloud server list              # check status
hcloud server ssh dev-box       # SSH via hcloud
hcloud server reboot dev-box    # reboot
tofu destroy                    # tear down everything
```

## Costs

| Item          | Cost        |
|---------------|-------------|
| Hetzner CPX31 | ~$12/mo     |
| Tailscale     | Free        |
| **Total**     | **~$12/mo** |
