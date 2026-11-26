#!/usr/bin/env bash
# Unit checks for the parts of wg-manager that parse input or rewrite config.
# Needs no root, network or WireGuard: it sources the script and calls functions.
set -uo pipefail
# The WG_* variables set below are read by the sourced functions.
# shellcheck disable=SC2034

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=wg-manager
source "$ROOT/wg-manager"
set +e
IFS=$' \t\n'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$(( FAILS + 1 )); }

expect_eq() {
    if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: expected [$3], got [$2]"; fi
}

# Validators call die (exit 1), so run them in a subshell.
expect_ok()   { if ( "${@:2}" ) >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }
expect_fail() { if ( "${@:2}" ) >/dev/null 2>&1; then fail "$1"; else pass "$1"; fi; }

# --- validators
expect_ok   "username alice"            validate_username alice
expect_ok   "username with dot/dash"    validate_username a.b-c_d
expect_fail "username starting with -"  validate_username -x
expect_fail "username with slash"       validate_username ../etc
expect_fail "username 33 chars"         validate_username "$(printf 'a%.0s' {1..33})"
expect_ok   "port 51820"                validate_port 51820
expect_fail "port 0"                    validate_port 0
expect_fail "port 65536"                validate_port 65536
expect_fail "port 000051820"            validate_port 000051820
expect_ok   "subnet 10.66.66.0/24"      validate_subnet_24 10.66.66.0/24
expect_ok   "subnet 172.20.1.0/24"      validate_subnet_24 172.20.1.0/24
expect_fail "subnet public"             validate_subnet_24 8.8.8.0/24
expect_fail "subnet /16"                validate_subnet_24 10.66.0.0/16
expect_fail "subnet not .0"             validate_subnet_24 10.66.66.5/24
expect_fail "subnet zero-padded"        validate_subnet_24 10.066.66.0/24
expect_ok   "dns two servers"           validate_dns "1.1.1.1, 1.0.0.1"
expect_fail "dns with ;"                validate_dns "1.1.1.1; rm"
expect_fail "dns with newline"          validate_dns $'1.1.1.1\nPostUp = x'

# --- endpoints
expect_eq "endpoint host"           "$(normalize_endpoint vpn.example.com 51820)" "vpn.example.com:51820"
expect_eq "endpoint host:port"      "$(normalize_endpoint 1.2.3.4:9999 51820)"    "1.2.3.4:9999"
expect_eq "endpoint bare ipv6"      "$(normalize_endpoint 2001:db8::1 51820)"     "[2001:db8::1]:51820"
expect_eq "endpoint bracketed ipv6" "$(normalize_endpoint '[2001:db8::1]' 51820)" "[2001:db8::1]:51820"
expect_eq "endpoint ipv6 with port" "$(normalize_endpoint '[2001:db8::1]:7' 51820)" "[2001:db8::1]:7"

# --- remove_peer_block must drop only the exact user's block
SERVER_CONFIG="$TMP/wg0.conf"
cat > "$SERVER_CONFIG" <<'CONF'
[Interface]
Address = 10.66.66.1/24

# BEGIN_PEER alice
[Peer]
PublicKey = A
# END_PEER alice

# BEGIN_PEER alice2
[Peer]
PublicKey = B
# END_PEER alice2
CONF
( remove_peer_block alice ) >/dev/null 2>&1
if grep -q 'PublicKey = B' "$SERVER_CONFIG" && ! grep -q 'PublicKey = A' "$SERVER_CONFIG"; then
    pass "delete alice keeps alice2"
else
    fail "delete alice keeps alice2"
fi

printf '# BEGIN_PEER bob\n[Peer]\nPublicKey = C\n' >> "$SERVER_CONFIG"
before=$(cat "$SERVER_CONFIG")
expect_fail "missing END_PEER refuses" remove_peer_block bob
expect_eq   "missing END_PEER leaves file unchanged" "$(cat "$SERVER_CONFIG")" "$before"

# --- firewall rules and hooks
WG_INTERFACE=wg0 WG_PORT=51820 WG_SUBNET=10.66.66.0/24 WG_OUT_INTERFACE=ens3 WG_ENCRYPTED_DNS=0
expect_eq "4 rules without encrypted DNS" "$(firewall_rules | wc -l)" "4"
WG_ENCRYPTED_DNS=1
expect_eq "6 rules with encrypted DNS" "$(firewall_rules | wc -l)" "6"
hooks=$(hook_lines)
expect_eq "PostUp opens the UDP port" \
    "$(grep -c 'iptables -w -t filter -I INPUT -p udp --dport 51820 -j ACCEPT' <<< "$hooks")" "1"
expect_eq "PostDown deletes MASQUERADE" \
    "$(grep -c 'iptables -w -t nat -D POSTROUTING -s 10.66.66.0/24 -o ens3 -j MASQUERADE 2>/dev/null || true' <<< "$hooks")" "1"
expect_eq "repair can target the old interface" "$(firewall_rules eth9 | grep -c eth9)" "3"

# write_hooks replaces both lines and keeps peers
cat > "$SERVER_CONFIG" <<'CONF'
[Interface]
PostUp = old up
PostDown = old down

# BEGIN_PEER alice
[Peer]
# END_PEER alice
CONF
( write_hooks ) >/dev/null 2>&1
expect_eq "write_hooks: one PostUp"   "$(grep -c '^PostUp = iptables' "$SERVER_CONFIG")" "1"
expect_eq "write_hooks: one PostDown" "$(grep -c '^PostDown = iptables' "$SERVER_CONFIG")" "1"
expect_eq "write_hooks: old hooks gone" "$(grep -c 'old' "$SERVER_CONFIG")" "0"
expect_eq "write_hooks: peers kept" "$(grep -c 'BEGIN_PEER alice' "$SERVER_CONFIG")" "1"

printf '\n%s failure(s)\n' "$FAILS"
(( FAILS == 0 ))
