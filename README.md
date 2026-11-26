# wg-manager

`wg-manager` is a single Bash script that sets up a WireGuard VPN server on a systemd-based Linux machine and manages its users. It installs the packages, writes the server config, enables IPv4 forwarding and NAT, and then lets you add and remove users, print a client config as a QR code, and see per-user traffic and last handshake. All state is plain files under `/etc/wireguard`; there is no daemon or database.

## Why I built this

I didn't want to depend on VPN providers like NordVPN or Surfshark. I just wanted a VPN built from the free resources available online.

With Oracle Cloud's free tier I got access to three machines: two x86 machines with 1 GB of RAM, and one Arm machine with 2 cores and 12 GB of RAM. I use one of the 1 GB machines for this. The script installs WireGuard, adds and removes users, generates a QR code for each user, and shows basic traffic stats, so you can see how much data is going through the VPN.

That is good enough for a simple WireGuard network. A lot of people don't know that you can set up your own VPN server with free resources. You don't get a choice of region, but that depends on your account. I live in Singapore, but because my main address is in India, my Oracle account is in India. If you get a free server anywhere else, the script works the same.

The purpose of the project is a simple script that installs WireGuard, adds users to your server and gives each one a QR code. Then you scan the QR code with the WireGuard app (available on both the iOS and Android app stores), and it imports the configuration into your phone straight away. You can also set your own DNS servers, or run an encrypted DNS resolver on the server itself.

## Requirements

- Linux with systemd (`wg-quick@.service` is used to run the interface)
- Bash 4 or newer
- Root (every command except `help` must be run with `sudo`)
- A kernel with WireGuard support (mainline since 5.6)
- One of these package managers: `apt-get`, `dnf`, `pacman`, `zypper`. The script installs `wireguard-tools`, `qrencode`, `iproute2` and `iptables` with it, plus `unbound` for encrypted DNS (see the tested-on table for what has actually been checked)
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

# Or with an encrypted DNS resolver for clients (see "Encrypted DNS")
sudo wg-manager install --endpoint vpn.example.com --encrypted-dns

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
| `install --endpoint <host-or-ip> [options]` | | Install packages, create the server config and keys, enable forwarding, open the port in UFW or firewalld if one is active (and in iptables through the interface's `PostUp`), start `wg-quick@<interface>`. Refuses to run if it is already installed or if `/etc/wireguard/<interface>.conf` already exists. |
| `add <username>` | | Create keys, a pre-shared key and the next free address for a user, add the peer to the running interface and the config, write the client config and a QR PNG, print the QR code. |
| `delete <username>` | `del`, `remove` | Remove the peer from the config and the running interface, then delete the user's directory. |
| `list` | `users` | Users, tunnel addresses, status (`active` if the last handshake was within 180 seconds, else `inactive` or `never`) and last handshake. |
| `traffic [username]` | | Received and sent bytes per user and totals. With a username, same as `traffic-user`. |
| `traffic-user <username>` | `user-traffic` | Traffic, last handshake and latest endpoint for one user. |
| `active [seconds]` | | Users with a handshake in the last N seconds (default 180). |
| `qr <username>` | | Regenerate the QR PNG and print the QR code and file paths. |
| `dns "<server1, server2>"` | | Change the DNS line in every client config and regenerate the QR images. Devices must re-import their profile. |
| `encrypted-dns on\|off` | | Start or stop the DNS-over-TLS resolver on the server and point every client profile at it (or back at `1.1.1.1, 1.0.0.1`). Devices must re-import their profile. |
| `doctor` | `diagnose` | Check that the interface is up, forwarding is on, the outbound interface has not changed, every firewall rule exists and, with encrypted DNS, the resolver is running. Exits non-zero if something is missing. |
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
| `--encrypted-dns` | off | Run a DNS-over-TLS resolver on the server and give clients its tunnel address as DNS. Cannot be combined with `--dns`. |

Usernames are 1 to 32 characters: letters, digits, `.`, `_` and `-`, starting with a letter or digit.

## Where things live

| Path | Contents |
|---|---|
| `/etc/wireguard/<interface>.conf` | Server config: server private key, firewall `PostUp`/`PostDown` rules, one `# BEGIN_PEER` / `# END_PEER` block per user |
| `/etc/wireguard/wg-manager/settings.conf` | Saved install settings (interface, port, endpoint, subnet, DNS, outbound interface) |
| `/etc/wireguard/wg-manager/server-public.key` | Server public key |
| `/etc/wireguard/wg-manager/users/<name>/` | `private.key`, `public.key`, `preshared.key`, `ip`, `<name>.conf` (client config) and `<name>.png` (QR code) |
| `/etc/unbound/wg-manager-<interface>.conf`, `/etc/systemd/system/wg-manager-dns-<interface>.service` | The encrypted DNS resolver, when it is on |
| `/etc/sysctl.d/99-wireguard-forward.conf` | `net.ipv4.ip_forward = 1` |
| `/run/wg-manager.lock` | Lock directory held while a command that changes state is running |

Directories are mode 700 and files mode 600, owned by root. If a run is killed and leaves the lock behind, remove it with `sudo rmdir /run/wg-manager.lock` (it is also cleared on reboot).

Traffic counters come from the kernel and reset when the interface is restarted or the server reboots.

## IPv6

The server only carries IPv4. Before 1.1.1, client configs had `AllowedIPs = 0.0.0.0/0`, so on a network with IPv6 the client sent its IPv6 traffic straight out over that network, outside the VPN.

From 1.1.1, `add` writes `AllowedIPs = 0.0.0.0/0, ::/0`. IPv6 traffic now goes into the tunnel, and the server drops it because it has no IPv6 address or route for clients. While connected, a client has no IPv6; apps fall back to IPv4. DNS is unaffected: the default servers (`1.1.1.1, 1.0.0.1`) are IPv4 and go through the tunnel.

Configs created before 1.1.1 are not changed by the upgrade, and `qr` still prints the stored config as it is (it now prints a note when the config is an old one). For each existing client, either edit the `[Peer]` section on the device so that

```
AllowedIPs = 0.0.0.0/0
```

becomes

```
AllowedIPs = 0.0.0.0/0, ::/0
```

or make the same edit in `/etc/wireguard/wg-manager/users/<name>/<name>.conf` on the server, run `sudo wg-manager qr <name>` to regenerate the QR code, and re-import the profile on the device. Nothing changes on the server side for existing peers.

## Encrypted DNS

By default clients use `1.1.1.1, 1.0.0.1`. Those queries go through the tunnel, but they leave the server as plain DNS on port 53, so the server's network can read them.

With `--encrypted-dns` at install, or `sudo wg-manager encrypted-dns on` later, the script installs `unbound` and runs its own instance (`wg-manager-dns-<interface>.service`):

- It listens only on the server's tunnel address (`10.66.66.1` by default) and answers only the tunnel subnet. It is not reachable from the internet.
- It forwards every query over DNS-over-TLS (port 853) to Cloudflare (`1.1.1.1`, `1.0.0.1`) and Quad9 (`9.9.9.9`, `149.112.112.112`), checking their certificates.
- Client profiles get `DNS = 10.66.66.1`. Existing devices keep their old DNS until they re-import the profile (`sudo wg-manager qr <name>`).
- The interface's `PostUp` adds two INPUT rules that allow port 53 from the tunnel interface only.
- The distribution's own `unbound.service` is disabled if the package was installed by this script. If `unbound` was already installed, it is left alone.

The resolver uses about 20 MB of RAM. `encrypted-dns off` stops and removes it and sets client DNS back to the default; the `unbound` package stays installed.

## Upgrading

Replace the script with the new version. Settings and users are kept. From 1.2.0 the interface's `PostUp` also opens the UDP port in iptables; to get that on an existing install, run `sudo wg-manager repair-network` once (it restarts the interface, so connected clients reconnect).

## Uninstall

There is no uninstall command. With the default interface name and port:

```sh
sudo systemctl disable --now wg-quick@wg0        # stops the tunnel; PostDown removes the firewall rules
sudo systemctl disable --now wg-manager-dns-wg0  # only if encrypted DNS is on
sudo rm -f /etc/systemd/system/wg-manager-dns-wg0.service /etc/unbound/wg-manager-wg0.conf
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
- Client configs route `0.0.0.0/0, ::/0` through the tunnel. The server is IPv4-only, so IPv6 traffic from a connected client goes into the tunnel and is dropped there instead of leaving over the local network. See [IPv6](#ipv6).
- Firewall changes made by the script:
  - `install` opens the UDP port with `ufw allow` or `firewall-cmd --permanent --add-port` if UFW or firewalld is active. The cloud provider's firewall (for example an Oracle Cloud security list) still has to allow it; the script cannot change that.
  - `PostUp` inserts an INPUT rule for the UDP port and two FORWARD rules at the top of their chains (tunnel to internet, and established return traffic), and appends a MASQUERADE rule for the tunnel subnet. With encrypted DNS it also allows port 53 from the tunnel interface. `PostDown` removes them. The INPUT rule is what lets clients in on images whose INPUT chain ends in REJECT, such as Oracle Cloud's Ubuntu.
  - `net.ipv4.ip_forward` is set to 1 and persisted in `/etc/sysctl.d`.
- Usernames are checked against a strict pattern before they are used in any path or config, so they cannot inject shell or config syntax.
- Clients can reach other hosts the server can reach, including the server's LAN or VPC. Add your own FORWARD rules if they should not.

## Tested on

This table separates what has been run from what has only been read.

| Environment | What was checked | Result |
|---|---|---|
| Ubuntu 24.04, Oracle Cloud VM, kernel 6.17 | 1.1.1 runs the live `wg0`. 1.2.0 was installed there as a second instance (`wg9`, its own port and subnet) with `--encrypted-dns`, with a client in a network namespace on the same host connected through a veth pair. Checked: handshake, internet through NAT, DNS over UDP and TCP through the resolver, upstream traffic only on port 853, resolver not reachable from outside, `add` (including rollback after a failure), `delete`, `list`, `traffic`, `encrypted-dns off`/`on` with the interface up, `repair-network`, `doctor`, resolver surviving an interface restart, and a fresh `unbound` install leaving the distribution's `unbound.service` disabled. Removed afterwards; iptables matched the state before the test. | Pass. The client did not come in over the internet (the cloud security list only allows the live port), so the cloud firewall path was not part of this test. |
| `tests/run.sh` | Validators, endpoint parsing, peer block removal, firewall rule and hook generation. Runs in CI. | Pass |
| `bash -n`, ShellCheck | Run in CI on every push (`.github/workflows/lint.yml`) | Pass |
| Debian | apt path, same as Ubuntu | Untested |
| Fedora / RHEL / Rocky / Alma | dnf path | Untested. On RHEL-family systems `qrencode` may need EPEL, which the dnf path does not enable. With firewalld active, its own forward rules may block client traffic even though the iptables rules are present. |
| Arch | pacman path | Untested. Uses `pacman -S --needed` without refreshing the package databases; if they are stale, run `pacman -Syu` first. The `iptables` package may conflict with an installed `iptables-nft`. |
| openSUSE | zypper path | Untested. Same firewalld caveat as Fedora. |

If you run it on one of the untested systems, an issue with the result (working or not) is welcome.

## Known limitations

- IPv4 only on the server. Clients get no IPv6 while connected (see [IPv6](#ipv6)).
- With firewalld active on Fedora, RHEL-family or openSUSE, `install` opens the UDP port, but firewalld's own forwarding policy may still block client traffic to the internet even though the script's iptables rules are in place. This has not been tested.
- `yum`-only systems (EL7 and similar) are not supported: those releases are end of life and their kernels lack built-in WireGuard.
- The encrypted DNS resolver has only been run on Ubuntu. On other distributions the `unbound` user and AppArmor/SELinux policy may differ.
- No uninstall command. See [Uninstall](#uninstall) for the manual steps.

## Changes

### 1.2.0

- Encrypted DNS: `install --encrypted-dns` and `encrypted-dns on|off` run a DNS-over-TLS resolver on the tunnel address (see [Encrypted DNS](#encrypted-dns)).
- The interface's `PostUp` opens the UDP port in iptables. Before, on hosts whose INPUT chain ends in REJECT (Oracle Cloud's Ubuntu images), a fresh install never received a handshake until the port was opened by hand.
- A failed `add` is rolled back: no user folder, peer block or runtime peer is left behind, so the same name can be added again.
- The firewall rules are defined once and used by `install`, `repair-network`, `encrypted-dns` and `doctor`. `doctor` now lists each rule it checks.
- `dns` adds a DNS line to a profile that has none instead of skipping it while counting it as updated.
- The `yum` fallback was removed.
- Added `tests/run.sh`, run in CI.

### 1.1.1

- Client configs route `::/0` as well as `0.0.0.0/0`, so IPv6 no longer bypasses the VPN. Existing configs need a one-line edit (see [IPv6](#ipv6)); `qr` points this out for old configs.
- Arch: install uses `pacman -S --needed` instead of `pacman -Sy`, which was an unsupported partial upgrade.
- `install` puts its FORWARD rules at the top of the chain, as `repair-network` already did. Before, on hosts whose FORWARD chain ends in a REJECT rule (Oracle Cloud Ubuntu images ship one), clients connected but had no internet until `repair-network` was run.
- `install` validates the endpoint before installing any packages, and a bracketed IPv6 endpoint without a port (`[2001:db8::1]`) is written as `[2001:db8::1]:51820` instead of `[[2001:db8::1]]:51820`.
- Overlong port numbers and zero-padded subnet octets are rejected.
- `delete` refuses to rewrite the server config if the user's `# END_PEER` marker is missing, instead of dropping everything after it.
- The lock is kept in root-only `/run` instead of world-writable `/run/lock`.

### 1.1.0

The version that was running on the original server, imported as is.

## License

MIT. See [LICENSE](LICENSE).
