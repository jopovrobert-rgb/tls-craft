set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/selfsite.sh
PREFIX=$(mktemp -d)
KEEP=${SELFSITE_KEEP_PREFIX:-}
NGINX_PID=
LIVE_CONF=
cleanup() {
  if [[ -n "$LIVE_CONF" && -f "$LIVE_CONF" ]]; then
    sudo nginx -c "$LIVE_CONF" -s stop >/dev/null 2>&1 || true
  fi
  if [[ -n "$NGINX_PID" ]]; then
    sudo kill "$NGINX_PID" 2>/dev/null || true
  fi
  if [[ -z "$KEEP" ]]; then
    rm -rf "$PREFIX"
  else
    printf 'prefix left at %s\n' "$PREFIX" >&2
  fi
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
bash -n "$SCRIPT"
bash -n "$ROOT/selftls.sh"
if ! git -C "$ROOT" diff --exit-code -- selftls.sh >/dev/null; then
  fail "selftls.sh was modified"
fi
lone=$(mktemp -d)
cp "$SCRIPT" "$lone/selfsite.sh"
chmod +x "$lone/selfsite.sh"
lone_prefix=$(mktemp -d)
"$lone/selfsite.sh" @ render \
  --prefix "$lone_prefix" \
  --domain lone.example \
  --email a@lone.example \
  --template kiln >/dev/null
grep -q 'Red Clay Atelier' "$lone_prefix/var/www/selfsite/site/index.html" || fail "embedded kiln template missing"
grep -q 'lone.example' "$lone_prefix/var/www/selfsite/site/index.html" || fail "embedded template did not substitute the domain"
rm -rf "$lone" "$lone_prefix"
"$SCRIPT" render \
  --prefix "$PREFIX" \
  --domain Harbor.Example \
  --email admin@harbor.example \
  --template ledger
NGX=$PREFIX/etc/nginx/sites-available/selfsite.conf
SITE=$PREFIX/var/www/selfsite/site/index.html
STATE=$PREFIX/usr/local/etc/selfsite/selfsite.env
[[ -f "$NGX" && -f "$SITE" && -f "$STATE" ]] || fail "render did not write the expected files"
[[ ! -e "$PREFIX/usr/local/etc/xray/config.json" ]] || fail "site script must not write an xray config"
grep -q '^DOMAIN=harbor.example$' "$STATE" || fail "domain was not lowercased"
grep -q 'listen 80 default_server;' "$NGX" || fail "port 80 missing"
grep -q 'listen 443 ssl http2 default_server;' "$NGX" || fail "public 443 missing"
grep -q 'ssl_protocols TLSv1.2 TLSv1.3;' "$NGX" || fail "443 must offer TLS 1.2 and 1.3"
grep -q "ssl_certificate $PREFIX/usr/local/etc/selfsite/cert/fullchain.pem;" "$NGX" || fail "certificate path"
grep -q 'Strict-Transport-Security' "$NGX" || fail "site must send HSTS"
# shellcheck disable=SC2016
grep -q 'return 301 https://harbor.example$request_uri;' "$NGX" || fail "redirect target"
# shellcheck disable=SC2016
grep -q 'try_files $uri $uri/ =404;' "$NGX" || fail "try_files was eaten"
grep -F 'location ~ /\.' "$NGX" >/dev/null || fail "dotfile location"
if grep -q 'proxy_pass\|proxy_protocol\|8443\|xray\|websocket' "$NGX"; then
  fail "site config must not proxy or mention the inbound"
fi
grep -q 'Harbor &amp; Holt' "$SITE" || fail "ledger copy missing"
grep -q 'harbor.example' "$SITE" || fail "domain not substituted"
if grep -q '__ACCENT__\|__YEAR__\|__DOMAIN__\|__STAMP__' "$SITE"; then
  fail "placeholder left in the page"
fi
if grep -qi 'selfsite\|selftls\|xray\|vless\|websocket' "$SITE" "$PREFIX/var/www/selfsite/site/404.html" "$PREFIX/var/www/selfsite/site/robots.txt"; then
  fail "public site mentions the installer"
fi
"$SCRIPT" template use kiln --prefix "$PREFIX" >/dev/null
grep -q 'Red Clay Atelier' "$SITE" || fail "template switch did not rewrite the site"
status=$("$SCRIPT" status --prefix "$PREFIX")
printf '%s\n' "$status" | grep -q 'https://harbor.example' || fail "status lost the site url"
for name in ledger press kiln; do
  dir=$(mktemp -d)
  "$SCRIPT" render --prefix "$dir" --domain "shop-${name}.example" --email "a@shop-${name}.example" --template "$name" >/dev/null
  page=$dir/var/www/selfsite/site/index.html
  if grep -q '__' "$page"; then
    fail "placeholder in $name"
  fi
  if ! grep -q "shop-${name}.example" "$page"; then
    fail "$name page has no domain"
  fi
  rm -rf "$dir"
done
modern=$(mktemp -d)
"$SCRIPT" render \
  --prefix "$modern" \
  --domain modern.example \
  --email a@modern.example \
  --template press \
  --http2-style modern >/dev/null
grep -q 'http2 on;' "$modern/etc/nginx/sites-available/selfsite.conf" || fail "modern http2 directive missing"
if grep -q 'listen 443 ssl http2' "$modern/etc/nginx/sites-available/selfsite.conf"; then
  fail "modern config still uses the legacy listen flag"
fi
rm -rf "$modern"
noh2=$(mktemp -d)
"$SCRIPT" render \
  --prefix "$noh2" \
  --domain http1.example \
  --email a@http1.example \
  --no-h2 >/dev/null
if grep -q 'http2' "$noh2/etc/nginx/sites-available/selfsite.conf"; then
  fail "no-h2 config still enables http2"
fi
rm -rf "$noh2"
if "$SCRIPT" render --prefix "$PREFIX-bad" --domain 'not a domain' --email a@b.co >/dev/null; then
  fail "bad domain was accepted"
fi
if "$SCRIPT" render --prefix "$PREFIX-bad" --domain example.com --email 'you@example.com' >/dev/null; then
  fail "example.com email was accepted"
fi
if "$SCRIPT" render --prefix "$PREFIX-bad" --domain shop.example --email a@shop.example --template blog >/dev/null; then
  fail "bad template was accepted"
fi
if command -v nginx >/dev/null 2>&1; then
  wrap=$PREFIX/nginx.conf
  mkdir -p "$PREFIX/logs" "$PREFIX/tmp/body" "$PREFIX/tmp/proxy" "$PREFIX/tmp/fastcgi" "$PREFIX/tmp/uwsgi" "$PREFIX/tmp/scgi"
  cat >"$wrap" <<EOF
worker_processes 1;
