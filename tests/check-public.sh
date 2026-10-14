#!/usr/bin/env bash
# check-public.sh — fail if tracked files contain things this PUBLIC repo must not:
# IPv4 literals (except 127.0.0.1, 0.0.0.0, documentation ranges), *.ts.net names,
# and private-key / token patterns. Scans `git ls-files`, so gitignored secrets
# (terraform.tfvars) are out of scope but must never be committed.
#
# Usage: tests/check-public.sh        (run from anywhere; exits 1 on any hit)
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
report() {  # report <label> <grep output>
  [ -n "$2" ] || return 0
  printf 'FAIL: %s\n%s\n' "$1" "$2" >&2
  fail=1
}

# Text files only; skip this script (it contains the patterns) and binary blobs.
mapfile -t files < <(git ls-files | grep -v '^tests/check-public\.sh$')
scan() { grep -InHE "$1" "${files[@]}" 2>/dev/null; }

# 1. IPv4 literals. Allowed: 127.0.0.1, 0.0.0.0, 192.0.2.x / 198.51.100.x / 203.0.113.x
#    (RFC 5737), plus version-like strings are not matched (needs four octets 0-255).
octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
ipv4="(^|[^0-9.])${octet}\\.${octet}\\.${octet}\\.${octet}([^0-9.]|\$)"
ips=$(scan "$ipv4" | grep -vE '(^|[^0-9.])(127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)([^0-9.]|$)')
report "IPv4 literal (use <public-ip> or a documentation range)" "$ips"

# 2. Tailnet names
report "*.ts.net name" "$(scan '[A-Za-z0-9-]+\.ts\.net')"

# 3. Private keys and tokens (require a long token body so "sk-..." in docs passes)
report "private key block" "$(scan 'BEGIN [A-Z ]*PRIVATE KEY')"
report "token-shaped string" "$(scan '(^|[^A-Za-z0-9_])(sk-[A-Za-z0-9_-]{16,}|tp-[A-Za-z0-9_-]{16,}|ttp-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})')"

# 4. Secret files must not be tracked
report "tracked secret file" "$(git ls-files | grep -E '(^|/)(terraform\.tfvars|\.env|.*\.tfstate.*|credentials\.enc|\.encryption_key|client_secret\.json|.*_token)$')"

if [ "$fail" -eq 0 ]; then
  echo "check-public: OK (${#files[@]} files scanned)"
else
  exit 1
fi
