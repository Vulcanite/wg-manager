# wg-manager

`wg-manager` is a single Bash script that sets up a WireGuard VPN server on a systemd-based Linux machine and manages its users. It installs the packages, writes the server config, enables IPv4 forwarding and NAT, and then lets you add and remove users, print a client config as a QR code, and see per-user traffic and last handshake. All state is plain files under `/etc/wireguard`; there is no daemon or database.

## Requirements

- Linux with systemd (`wg-quick@.service` is used to run the interface)
- Bash 4 or newer
- Root (every command except `help` must be run with `sudo`)
- A kernel with WireGuard support (mainline since 5.6)
- One of these package managers: `apt-get`, `dnf`, `yum`, `pacman`, `zypper`. The script installs `wireguard-tools`, `qrencode`, `iproute2` and `iptables` with it (see the tested-on table for what has actually been checked)
- A public IP or hostname, and the chosen UDP port (default 51820) open in any cloud or provider firewall

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Vulcanite/wg-manager/main/wg-manager -o wg-manager && sudo install -m 755 -o root -g root wg-manager /usr/local/sbin/wg-manager
```

Read the script before running it as root. It is one file.

## Quick start

```sh
# Set up the server (installs packages, creates wg0, starts it)
sudo wg-manager install --endpoint vpn.example.com

# Add a user; prints a QR code you can scan with the WireGuard mobile app
sudo wg-manager add alice

# Show the QR code again later
sudo wg-manager qr alice

# List users with status and last handshake
sudo wg-manager list

# Traffic for everyone, or for one user
sudo wg-manager traffic
sudo wg-manager traffic alice

# Remove a user (removes the peer from the running interface and the config)
sudo wg-manager delete alice
```

Running `sudo wg-manager` with no arguments in a terminal opens a numbered menu with the same actions.

## Commands

| Command | Aliases | What it does |
|---|---|---|
| `install --endpoint <host-or-ip> [options]` | | Install packages, create the server config and keys, enable forwarding, open the port in UFW or firewalld if one is active, start `wg-quick@<interface>`. Refuses to run if it is already installed or if `/etc/wireguard/<interface>.conf` already exists. |
| `add <username>` | | Create keys, a pre-shared key and the next free address for a user, add the peer to the running interface and the config, write the client config and a QR PNG, print the QR code. |
| `delete <username>` | `del`, `remove` | Remove the peer from the config and the running interface, then delete the user's directory. |
| `list` | `users` | Users, tunnel addresses, status (`active` if the last handshake was within 180 seconds, else `inactive` or `never`) and last handshake. |
| `traffic [username]` | | Received and sent bytes per user and totals. With a username, same as `traffic-user`. |
| `traffic-user <username>` | `user-traffic` | Traffic, last handshake and latest endpoint for one user. |
| `active [seconds]` | | Users with a handshake in the last N seconds (default 180). |
| `qr <username>` | | Regenerate the QR PNG and print the QR code and file paths. |
| `dns "<server1, server2>"` | | Change the DNS line in every client config and regenerate the QR images. Devices must re-import their profile. |
| `doctor` | `diagnose` | Check that the interface is up, forwarding is on, the outbound interface has not changed, and the NAT and FORWARD rules exist. Exits non-zero if something is missing. |
| `repair-network` | `repair` | Re-detect the outbound interface, rewrite the `PostUp`/`PostDown` firewall rules, re-enable forwarding and restart the interface. |
| `config` | | Print the saved settings and whether the interface is up. |
| `help` | `-h`, `--help` | Print usage. |

Install options:

| Option | Default | Notes |
|---|---|---|
| `--endpoint <value>` | prompted if run in a terminal | Public hostname or IP that clients connect to. A `:port` suffix is accepted; IPv6 may be given as `2001:db8::1`, `[2001:db8::1]` or `[2001:db8::1]:port`. |
| `--port <1-65535>` | `51820` | UDP listen port. |
| `--subnet <x.x.x.0/24>` | `10.66.66.0/24` | Must be a private (RFC 1918) /24. The server takes `.1`, clients get `.2` to `.254`. |
| `--dns <servers>` | `1.1.1.1, 1.0.0.1` | Comma-separated DNS servers written into client configs. |
| `--interface <name>` | `wg0` | WireGuard interface name. |

Usernames are 1 to 32 characters: letters, digits, `.`, `_` and `-`, starting with a letter or digit.

## Where things live

| Path | Contents |
|---|---|
| `/etc/wireguard/<interface>.conf` | Server config: server private key, firewall `PostUp`/`PostDown` rules, one `# BEGIN_PEER` / `# END_PEER` block per user |
| `/etc/wireguard/wg-manager/settings.conf` | Saved install settings (interface, port, endpoint, subnet, DNS, outbound interface) |
| `/etc/wireguard/wg-manager/server-public.key` | Server public key |
| `/etc/wireguard/wg-manager/users/<name>/` | `private.key`, `public.key`, `preshared.key`, `ip`, `<name>.conf` (client config) and `<name>.png` (QR code) |
| `/etc/sysctl.d/99-wireguard-forward.conf` | `net.ipv4.ip_forward = 1` |
| `/run/wg-manager.lock` | Lock directory held while a command that changes state is running |

Directories are mode 700 and files mode 600, owned by root. If a run is killed and leaves the lock behind, remove it with `sudo rmdir /run/wg-manager.lock` (it is also cleared on reboot).

Traffic counters come from the kernel and reset when the interface is restarted or the server reboots.

## Uninstall

There is no uninstall command. With the default interface name and port:

```sh
sudo systemctl disable --now wg-quick@wg0        # stops the tunnel; PostDown removes the FORWARD and NAT rules
sudo rm -f /etc/wireguard/wg0.conf
sudo rm -rf /etc/wireguard/wg-manager            # deletes all user keys and client configs
sudo rm -f /etc/sysctl.d/99-wireguard-forward.conf
sudo sysctl -w net.ipv4.ip_forward=0             # only if nothing else on the host needs forwarding
sudo ufw delete allow 51820/udp                  # if UFW was active during install
sudo firewall-cmd --permanent --remove-port=51820/udp && sudo firewall-cmd --reload   # if firewalld was active
sudo rm -f /usr/local/sbin/wg-manager
```

The installed packages are left in place. If you saved iptables rules with `netfilter-persistent` or similar while the tunnel was up, remove the WireGuard rules from that saved file too.

The same steps clean up after an install that failed halfway, since `install` refuses to run again while `settings.conf` or the interface config exists.

## Security notes

- The script runs as root. Install it owned by root and not writable by other users (the install line above does this).
- The server keeps every client's private key, pre-shared key, config and QR image under `/etc/wireguard/wg-manager/users`. Anyone with root on the server can read them and connect as that user. `delete` removes them. Keys are not generated on the client device.
- The client config and QR code contain the client's private key. `add` and `qr` print the QR code to the terminal, so mind screen sharing and terminal logs. Send `.conf` files over a private channel.
- Each user gets their own pre-shared key in addition to the key pair.
- Client configs route `0.0.0.0/0` through the tunnel. IPv6 is not configured, so on a network with IPv6 a client's IPv6 traffic does not go through the VPN.
- Firewall changes made by the script:
  - `install` opens the UDP port with `ufw allow` or `firewall-cmd --permanent --add-port` if UFW or firewalld is active. Otherwise it changes nothing for incoming traffic and prints a reminder; if your host's INPUT chain rejects unknown traffic (some cloud images do), allow the UDP port yourself.
  - `PostUp` inserts two FORWARD rules at the top of the chain (tunnel to internet, and established return traffic) and appends a MASQUERADE rule for the tunnel subnet. `PostDown` removes them.
  - `net.ipv4.ip_forward` is set to 1 and persisted in `/etc/sysctl.d`.
- Usernames are checked against a strict pattern before they are used in any path or config, so they cannot inject shell or config syntax.
- Clients can reach other hosts the server can reach, including the server's LAN or VPC. Add your own FORWARD rules if they should not.

## Tested on

This table separates what has been run from what has only been read.

| Environment | What was checked | Result |
|---|---|---|
| Ubuntu 24.04, Oracle Cloud VM, kernel 6.17 | Version 1.1.0 (before the fixes in this repo's history) has been in use there with a live `wg0`. | Works in day-to-day use. The current version has not been run there. |
| Ubuntu 26.04 (WSL2), Bash 5.3, unprivileged sandbox with no network | Every command run end to end as fake root, with `wg`, `systemctl`, `iptables`, `qrencode`, `ip` and the package managers replaced by stubs. Checked file layout and permissions, peer add/delete in the config, input validation, locking, error paths. | Pass. This does not touch a real WireGuard interface, real firewall rules or real packages. |
| `bash -n` | Syntax | Pass |
| ShellCheck | Runs in CI on every push (`.github/workflows/lint.yml`) | Not run locally yet |
| Debian | apt path, same as Ubuntu | Untested |
| Fedora / RHEL / Rocky / Alma | dnf path (`yum` fallback for old releases) | Untested. On RHEL-family systems `qrencode` may need EPEL, which the dnf path does not enable. With firewalld active, its own forward rules may block client traffic even though the iptables rules are present. |
| Arch | pacman path | Untested. Uses `pacman -Sy`, which Arch does not support as a partial upgrade, and the `iptables` package may conflict with an installed `iptables-nft`. |
| openSUSE | zypper path | Untested. Same firewalld caveat as Fedora. |

If you run it on one of the untested systems, an issue with the result (working or not) is welcome.

## License

MIT. See [LICENSE](LICENSE).
