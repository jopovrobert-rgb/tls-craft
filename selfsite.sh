#!/usr/bin/env bash
# selfsite — a normal HTTPS site on port 443.
# nginx owns 80 and 443. Xray is not installed and its config is not touched.
# Use this when a proxy inbound already listens on another port, for example 8443.
#
# Debian and Ubuntu, systemd, root. See README.md.

VERSION=1.0.0

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "selfsite: нужен bash" >&2
  exit 1
fi

trap 'echo "selfsite: ошибка на строке $LINENO" >&2' ERR

resolve_script_dir() {
  local source=${BASH_SOURCE[0]}
  local dir
  while [[ -L "$source" ]]; do
    dir=$(cd -P "$(dirname "$source")" && pwd)
    source=$(readlink "$source")
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR=$(resolve_script_dir)

COMMAND=
DOMAIN=
EMAIL=
TEMPLATE=
PREFIX=
HTTP2_STYLE=
FORCE=0
USE_H2=1
PUBLIC_IP=
PROMPTED=0
DISABLED_DEFAULT=0
EXTRA=()
TEMPLATE_DIR=""

usage() {
  cat <<EOF
selfsite ${VERSION}

Только сайт на 443. Сертификат Let's Encrypt, nginx. Xray скрипт не ставит
и чужой инбаунд не переписывает.

Сначала освободи 443: инбаунд, который уже там слушает, перенеси на другой
порт. Потом:

  sudo bash selfsite.sh @ install --domain exit.example.com --email you@example.com

Знак @ перед командой игнорируется.

Шаблоны: ledger (верфь), press (типография), kiln (керамика).

  selfsite status
  selfsite template list
  selfsite template use kiln
  selfsite renew
  selfsite logs
  selfsite guide
  sudo ./selfsite.sh uninstall

Флаги install: --domain --email --template --ip --force
--ip ставит дополнительный адрес этой ВМ, если A-запись смотрит не на основной.
--force пропускает сверку DNS.
Нужны Debian или Ubuntu, свободные порты 80 и 443 и A-запись домена на этот сервер.
EOF
}

die() {
  printf 'selfsite: %s\n' "$*" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "нужен root: sudo ./selfsite.sh $COMMAND"
}

root_path() {
  local path=$1
  if [[ -n "$PREFIX" ]]; then
    printf '%s%s\n' "${PREFIX%/}" "$path"
  else
    printf '%s\n' "$path"
  fi
}

valid_domain() {
  local d=$1
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
  [[ "$d" =~ ^[0-9.]+$ ]] && return 1
  return 0
}

valid_email() {
  local domain
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1
  domain=${1##*@}
  domain=${domain,,}
  case "$domain" in
    example.com|example.org|example.net|example.edu|localhost|*.example.com|*.example.org|*.example.net|*.localhost)
      return 1
      ;;
  esac
  return 0
}

valid_template() {
  case "$1" in
    ledger|press|kiln) return 0 ;;
    *) return 1 ;;
  esac
}

valid_ipv4() {
  local octet
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"$1"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    ((10#$octet <= 255)) || return 1
  done
}

embedded_ledger() {
  cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Harbor &amp; Holt — haul-out and small boats</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta name="description" content="Haul-out, bottom paint, and winter stands for boats under 12 metres.">
<style>
:root { --accent: __ACCENT__; --paper: #f3efe4; --ink: #1c1915; --muted: #5e584e; --line: #ddd4c4; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 18px/1.45 Georgia, "Iowan Old Style", Palatino, serif; }
.wrap { max-width: 40rem; margin: 0 auto; padding: 1.25rem 1.25rem 4rem; }
header { border-top: 8px solid var(--accent); padding-top: 0.9rem; }
.mark { margin: 0; font-family: system-ui, sans-serif; font-size: 0.78rem; letter-spacing: 0.12em; text-transform: uppercase; }
.where { margin: 0.35rem 0 0; color: var(--muted); }
h1 { font-size: 2.05rem; line-height: 1.15; font-weight: 500; margin: 1.6rem 0 0.8rem; }
h2 { margin: 2rem 0 0.4rem; font: 600 0.95rem/1.3 system-ui, sans-serif; letter-spacing: 0.04em; text-transform: uppercase; }
p { margin: 0.7rem 0; }
dl { margin: 0.4rem 0 0; }
dt { margin-top: 1rem; font-family: system-ui, sans-serif; font-weight: 650; }
dd { margin: 0.15rem 0 0; }
footer { margin-top: 2.8rem; color: var(--muted); font-size: 0.92rem; }
footer strong { color: var(--ink); font-weight: 600; }
@media (max-width: 600px) {
  body { font-size: 17px; }
  h1 { font-size: 1.6rem; }
}
</style>
</head>
<body>
<div class="wrap">
<header>
<p class="mark">Harbor &amp; Holt</p>
<p class="where">The shed past the ice plant, green door</p>
</header>
<main>
<h1>Haul-out, bottom paint, and a stand for the winter.</h1>
<p>Boats under 12 metres. If the name is on the ledger in the office, the stand is yours. If it is not, the yard is full and the travel-lift is not taking visitors.</p>
<h2>On the board</h2>
<dl>
<dt>Spring paint</dt>
<dd>Booked from March. Bring a chip of the old colour if you want the same one mixed.</dd>
<dt>Shaft and cutless</dt>
<dd>Two days when the bearing is a size we keep on the shelf. Odd sizes wait on the chandlery.</dd>
<dt>Winter stand</dt>
<dd>Spoken for by the first week of October. After that we stop adding names, even for boats we already know.</dd>
</dl>
<h2>Hours</h2>
<p>Tuesday to Saturday, 8:00–16:00. Monday is haul day: the office is shut and the lift is on the wall.</p>
<p>The number is painted on the door. We do not take a booking from a message left after hours.</p>
</main>
<footer>
<p><strong>Harbor &amp; Holt</strong> · yard ledger since __YEAR__ · sheet __STAMP__<br>__DOMAIN__</p>
</footer>
</div>
</body>
</html>
EOF
}

embedded_press() {
  cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lumen &amp; Co. — short-run letterpress</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta name="description" content="Cotton cards and short-run posters. Two colours, proof in five days.">
<style>
:root { --accent: __ACCENT__; --paper: #f7f1e6; --ink: #221c16; --muted: #6a5e52; --line: #e0d3c2; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 18px/1.45 Georgia, "Iowan Old Style", Palatino, serif; }
.wrap { max-width: 42rem; margin: 0 auto; padding: 1.25rem 1.25rem 4rem; }
header { display: flex; justify-content: space-between; gap: 1rem; align-items: baseline; border-bottom: 1px solid var(--ink); padding-bottom: 0.6rem; }
.mark { margin: 0; font-family: system-ui, sans-serif; font-size: 0.78rem; letter-spacing: 0.14em; text-transform: uppercase; }
.since { margin: 0; color: var(--muted); font-size: 0.92rem; }
h1 { font-size: 2rem; line-height: 1.15; font-weight: 500; max-width: 22ch; }
.rule { height: 6px; width: 4.5rem; background: var(--accent); margin: 0.2rem 0 1rem; }
table { width: 100%; border-collapse: collapse; margin-top: 0.4rem; }
th, td { text-align: left; padding: 0.55rem 0.4rem 0.55rem 0; border-bottom: 1px solid var(--line); vertical-align: baseline; }
th { font: 600 0.78rem/1.3 system-ui, sans-serif; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
td:last-child, th:last-child { text-align: right; padding-right: 0; white-space: nowrap; }
.note { color: var(--muted); }
footer { margin-top: 2.6rem; font-size: 0.92rem; color: var(--muted); }
footer strong { color: var(--ink); font-weight: 600; }
@media (max-width: 600px) {
  body { font-size: 17px; }
  h1 { font-size: 1.55rem; }
  header { flex-direction: column; align-items: flex-start; }
}
</style>
</head>
<body>
<div class="wrap">
<header>
<p class="mark">Lumen &amp; Co.</p>
<p class="since">Pressroom since __YEAR__</p>
</header>
<main>
<div class="rule"></div>
<h1>Cotton cards and posters, two colours at most.</h1>
<p>The small press takes one forme at a time. A second colour is a second pass, not a second job squeezed onto the same lockup. We do not print photographs, and we do not take walk-ins while a run is on.</p>
<table>
<thead>
<tr><th>Piece</th><th>What you get</th><th>From</th></tr>
</thead>
<tbody>
<tr><td>Card</td><td>Cotton, one colour, short edge under 130&nbsp;mm</td><td>£2.40</td></tr>
<tr><td>Second colour</td><td>Same card, another pass</td><td>£1.10</td></tr>
<tr><td>Poster</td><td>A3, one colour, uncoated</td><td>£18</td></tr>
<tr><td>Proof</td><td>Five days. Credited if you print the run</td><td>£40</td></tr>
</tbody>
</table>
<p class="note">A run of cards is twelve working days after the proof is signed. Bring your own stock only if it is already cut square; we will not trim a ream on press day.</p>
<p>Appointments are written in the book by the door. If the book is closed, the press is down for the week and the window will say so.</p>
</main>
<footer>
<p><strong>Lumen &amp; Co.</strong> · job __STAMP__<br>__DOMAIN__</p>
</footer>
</div>
</body>
</html>
EOF
}

embedded_kiln() {
  cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Red Clay Atelier — wheels, hands, and the kiln</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta name="description" content="Evening wheel and handbuilding. Bisque on the first Monday. Clay by the bag for students first.">
<style>
:root { --accent: __ACCENT__; --paper: #f6f0ea; --ink: #241915; --muted: #6d5b52; --line: #e4d5cb; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 18px/1.45 "Segoe UI", system-ui, sans-serif; }
.wrap { max-width: 40rem; margin: 0 auto; padding: 1.25rem 1.25rem 4rem; }
.eyebrow { margin: 0; color: var(--accent); font-size: 0.78rem; letter-spacing: 0.14em; text-transform: uppercase; font-weight: 700; }
h1 { font: 500 2.1rem/1.12 Georgia, "Iowan Old Style", serif; margin: 0.7rem 0 0.8rem; }
h2 { margin: 2rem 0 0.5rem; font-size: 1rem; letter-spacing: 0.04em; text-transform: uppercase; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 0.6rem 0.75rem 0.6rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
th { width: 9.5rem; font-weight: 650; }
.closed { margin-top: 1rem; padding-left: 0.8rem; border-left: 4px solid var(--accent); }
footer { margin-top: 2.8rem; color: var(--muted); font-size: 0.92rem; }
footer strong { color: var(--ink); }
@media (max-width: 600px) {
  h1 { font-size: 1.6rem; }
  th { width: 7.2rem; }
  body { font-size: 16.5px; }
}
</style>
</head>
<body>
<div class="wrap">
<p class="eyebrow">Red Clay Atelier</p>
<h1>Six wheels, one kiln, and a list that closes when the pegs are gone.</h1>
<p>Evening classes in a room that still smells like the last firing. Come ready to work: the wheels are not a demonstration, and the person at the next peg will not wait while you decide.</p>
<h2>This term</h2>
<table>
<tbody>
<tr><th>Wednesday 18:30</th><td>Wheel. Six places. If you miss two weeks, the peg goes back on the nail.</td></tr>
<tr><th>Thursday 18:30</th><td>Handbuilding. Coil and slab. Same rule about the peg.</td></tr>
<tr><th>First Monday</th><td>Bisque. No class. Pieces left on the green shelf after noon stay there until the next firing.</td></tr>
<tr><th>Friday</th><td>The kiln room is locked while it cools. The studio door still opens for people picking up work that is already boxed.</td></tr>
</tbody>
</table>
<p class="closed">Clay is sold by the 12&nbsp;kg bag, students first. We started the atelier in __YEAR__. If the cones are down, nobody goes in to check them.</p>
<footer>
<p><strong>Red Clay Atelier</strong> · board __STAMP__<br>__DOMAIN__</p>
</footer>
</div>
</body>
</html>
EOF
}


materialize_templates() {
  if [[ -n "$TEMPLATE_DIR" && -s "$TEMPLATE_DIR/ledger.html" ]]; then
    return 0
  fi
  if [[ -s "$SCRIPT_DIR/share/templates/ledger.html" ]]; then
    TEMPLATE_DIR="$SCRIPT_DIR/share/templates"
    return 0
  fi
  TEMPLATE_DIR=$(mktemp -d)
  embedded_ledger >"$TEMPLATE_DIR/ledger.html"
  embedded_press >"$TEMPLATE_DIR/press.html"
  embedded_kiln >"$TEMPLATE_DIR/kiln.html"
}

template_file() {
  materialize_templates
  printf '%s/%s.html\n' "$TEMPLATE_DIR" "$1"
}

require_templates() {
  local name
  materialize_templates
  for name in ledger press kiln; do
    [[ -s "$(template_file "$name")" ]] || die "нет шаблона $name"
  done
}

state_file() { root_path /usr/local/etc/selfsite/selfsite.env; }
cert_dir() { root_path /usr/local/etc/selfsite/cert; }
cert_file() { root_path /usr/local/etc/selfsite/cert/fullchain.pem; }
key_file() { root_path /usr/local/etc/selfsite/cert/privkey.pem; }
site_dir() { root_path /var/www/selfsite/site; }
acme_dir() { root_path /var/www/selfsite/acme; }
nginx_site() { root_path /etc/nginx/sites-available/selfsite.conf; }
nginx_access_log() { root_path /var/log/nginx/selfsite.access.log; }

load_state() {
  local file line key val
  file=$(state_file)
  [[ -f "$file" ]] || die "selfsite ещё не установлен ($file)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "битая строка в $file"
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      DOMAIN)
        valid_domain "$val" || die "битый домен в $file"
        [[ -z "$DOMAIN" ]] && DOMAIN=$val
        ;;
      EMAIL)
        valid_email "$val" || die "битый email в $file"
        [[ -z "$EMAIL" ]] && EMAIL=$val
        ;;
      TEMPLATE)
        valid_template "$val" || die "битый шаблон в $file"
        [[ -z "$TEMPLATE" ]] && TEMPLATE=$val
        ;;
      DISABLED_DEFAULT)
        [[ "$val" == 0 || "$val" == 1 ]] || die "битый DISABLED_DEFAULT в $file"
        DISABLED_DEFAULT=$val
        ;;
      PUBLIC_IP)
        [[ -z "$val" ]] && continue
        valid_ipv4 "$val" || die "битый PUBLIC_IP в $file"
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$val
        ;;
      *)
        die "неизвестное поле $key в $file"
        ;;
    esac
  done <"$file"
  [[ -n "$DOMAIN" && -n "$EMAIL" && -n "$TEMPLATE" ]] || die "в $file не хватает полей"
}

save_state() {
  local file dir
  file=$(state_file)
  dir=$(dirname "$file")
  mkdir -p "$dir"
  cat >"$file" <<EOF
# selfsite ${VERSION}
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
TEMPLATE=${TEMPLATE}
DISABLED_DEFAULT=${DISABLED_DEFAULT}
PUBLIC_IP=${PUBLIC_IP}
EOF
  chmod 600 "$file"
}

hash_bytes() {
  printf '%s' "$DOMAIN" | sha256sum | awk '{print $1}'
}

accent_for() {
  local hex idx
  hex=$(hash_bytes)
  idx=$((16#${hex:0:2} % 5))
  case "$idx" in
    0) printf '%s\n' '#1f4d3a' ;;
    1) printf '%s\n' '#8c3a2f' ;;
    2) printf '%s\n' '#1e3a5f' ;;
    3) printf '%s\n' '#6b4a2a' ;;
    *) printf '%s\n' '#0f5f6b' ;;
  esac
}

year_for() {
  local hex
  hex=$(hash_bytes)
  printf '%s\n' "$((1994 + 16#${hex:2:2} % 26))"
}

stamp_for() {
  local hex
  hex=$(hash_bytes)
  printf '%s\n' "${hex:4:8}"
}

mark_letter() {
  case "$TEMPLATE" in
    ledger) printf '%s\n' H ;;
    press) printf '%s\n' L ;;
    kiln) printf '%s\n' R ;;
    *) die "шаблон" ;;
  esac
}

apply_template() {
  local src=$1 dest=$2 accent year stamp content
  accent=$(accent_for)
  year=$(year_for)
  stamp=$(stamp_for)
  content=$(<"$src")
  content=${content//__ACCENT__/$accent}
  content=${content//__YEAR__/$year}
  content=${content//__DOMAIN__/$DOMAIN}
  content=${content//__STAMP__/$stamp}
  printf '%s\n' "$content" >"$dest"
}

write_favicon() {
  local dest=$1 accent letter
  accent=$(accent_for)
  letter=$(mark_letter)
  cat >"$dest" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
<rect width="32" height="32" fill="${accent}"/>
<text x="16" y="22" text-anchor="middle" font-family="Georgia, serif" font-size="18" fill="#f3efe4">${letter}</text>
</svg>
EOF
}

write_404() {
  local dest=$1 accent
  accent=$(accent_for)
  cat >"$dest" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Not on the board</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
body { margin: 0; background: #f3efe4; color: #1c1915; font: 18px/1.45 Georgia, serif; }
main { max-width: 36rem; margin: 0 auto; padding: 4rem 1.25rem; }
a { color: ${accent}; }
</style>
</head>
<body>
<main>
<h1>That page is not on the board.</h1>
<p><a href="/">Back to the front</a></p>
</main>
</body>
</html>
EOF
}

write_site() {
  local dir src
  valid_template "$TEMPLATE" || die "шаблон: ledger, press или kiln"
  src=$(template_file "$TEMPLATE")
  [[ -f "$src" ]] || die "нет файла шаблона $src"
  dir=$(site_dir)
  mkdir -p "$dir"
  apply_template "$src" "$dir/index.html"
  write_favicon "$dir/favicon.svg"
  write_404 "$dir/404.html"
  printf 'User-agent: *\nAllow: /\n' >"$dir/robots.txt"
  chmod -R a+rX "$dir"
}

has_ipv6() {
  local disabled
  [[ -f /proc/net/if_inet6 ]] || return 1
  disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
  [[ "$disabled" == 0 ]]
}

choose_http2_style() {
  local ver
  if [[ -n "$HTTP2_STYLE" ]]; then
    case "$HTTP2_STYLE" in
      classic|modern) return 0 ;;
      *) die "--http2-style: classic или modern" ;;
    esac
  fi
  if [[ -n "$PREFIX" ]] || ! command -v nginx >/dev/null 2>&1; then
    HTTP2_STYLE=classic
    return 0
  fi
  ver=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
  if [[ -n "$ver" ]] && printf '%s\n' "1.25.1" "$ver" | sort -C -V; then
    HTTP2_STYLE=modern
  else
    HTTP2_STYLE=classic
  fi
}

detect_h2() {
  if [[ "$USE_H2" -eq 0 ]]; then
    return 0
  fi
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  if command -v nginx >/dev/null 2>&1 && ! nginx -V 2>&1 | grep -q 'http_v2_module'; then
    USE_H2=0
    say "В этом nginx нет http_v2. Сайт откроется по HTTP/1.1."
  fi
}

write_nginx() {
  local file root_dir acme access listen4 listen6
  file=$(nginx_site)
  root_dir=$(site_dir)
  acme=$(acme_dir)
  access=$(nginx_access_log)
  mkdir -p "$(dirname "$file")" "$(dirname "$access")" "$acme" "$root_dir"
  choose_http2_style
  detect_h2
  {
    cat <<EOF
log_format selfsite '\$remote_addr [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent';

server {
    listen 80 default_server;
EOF
    if has_ipv6; then
      printf '    listen [::]:80 default_server;\n'
    fi
    # shellcheck disable=SC2016
    cat <<EOF
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        root ${acme};
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF
    if [[ -s "$(cert_file)" && -s "$(key_file)" ]]; then
      listen4="listen 443 ssl default_server;"
      listen6="listen [::]:443 ssl default_server;"
      if [[ "$USE_H2" -eq 1 && "$HTTP2_STYLE" == classic ]]; then
        listen4="listen 443 ssl http2 default_server;"
        listen6="listen [::]:443 ssl http2 default_server;"
      fi
      cat <<EOF

server {
    ${listen4}
EOF
      if has_ipv6; then
        printf '    %s\n' "$listen6"
      fi
      cat <<EOF
    server_name ${DOMAIN};
    ssl_certificate $(cert_file);
    ssl_certificate_key $(key_file);
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log ${access} selfsite;
EOF
      if [[ "$USE_H2" -eq 1 && "$HTTP2_STYLE" == modern ]]; then
        printf '    http2 on;\n'
      fi
      cat <<EOF
    root ${root_dir};
    index index.html;
    client_max_body_size 1m;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Strict-Transport-Security "max-age=15552000" always;

    location ~ /\\. {
        deny all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
EOF
    fi
  } >"$file"
}

public_ipv4() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4fsS --max-time 6 "$url" 2>/dev/null || true)
    ip=${ip//$'\r'/}
    ip=${ip//$'\n'/}
    if valid_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

local_ipv4s() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    return 0
  fi
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

dns_v4() {
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u
}

check_dns() {
  local ip candidate egress matched=0
  local -a records=() ours=()
  [[ "$FORCE" -eq 1 ]] && return 0
  if [[ -n "$PUBLIC_IP" ]]; then
    valid_ipv4 "$PUBLIC_IP" || die "--ip не похож на IPv4: $PUBLIC_IP"
  fi
  mapfile -t records < <(dns_v4 || true)
  if [[ ${#records[@]} -eq 0 ]]; then
    die "у $DOMAIN нет A-записи. Поставьте её на адрес сервера или повторите с --force"
  fi
  mapfile -t ours < <(local_ipv4s || true)
  [[ -n "$PUBLIC_IP" ]] && ours+=("$PUBLIC_IP")
  if egress=$(public_ipv4); then
    ours+=("$egress")
  fi
  if [[ ${#ours[@]} -eq 0 ]]; then
    say "Адреса сервера не узнались. A-запись $DOMAIN: ${records[*]}. Сверку пропускаю."
    return 0
  fi
  for candidate in "${records[@]}"; do
    for ip in "${ours[@]}"; do
      if [[ "$candidate" == "$ip" ]]; then
        matched=1
        break 2
      fi
    done
  done
  if [[ "$matched" -ne 1 ]]; then
    die "A-запись $DOMAIN указывает на ${records[*]}, а адреса этого сервера: ${ours[*]}. Дополнительный адрес, которого не видно внутри ВМ, передай как --ip АДРЕС или повтори с --force"
  fi
}

listeners() {
  local port=$1
  ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

refuse_if_stream_proxy() {
  local conf=/etc/nginx/nginx.conf
  [[ -f "$conf" ]] || return 0
  if grep -q '^[[:space:]]*stream[[:space:]]*{' "$conf" && ! grep -q '^[[:space:]]*http[[:space:]]*{' "$conf"; then
    die "На этом хосте nginx только проксирует TCP. Сайт сюда не ставится."
  fi
}

assert_ports_free() {
  local row port
  for port in 80 443; do
    row=$(listeners "$port")
    if [[ -n "$row" ]] && ! grep -q 'nginx' <<<"$row"; then
      if [[ "$port" == 443 ]]; then
        die "порт 443 занят не nginx: $row. Сайт туда не встанет. Сначала перенеси инбаунд на другой порт и освободи 443."
      fi
      die "порт 80 занят не nginx: $row. Его занимает выпуск сертификата. Останови службу, которая его держит."
    fi
  done
  if systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
    die "Apache уже слушает веб. Остановите его сами: selfsite его не трогает."
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx curl socat openssl ca-certificates cron
}

issue_cert() {
  local acme web rc=0 reload
  acme=/root/.acme.sh/acme.sh
  web=$(acme_dir)
  mkdir -p "$web"
  chmod 755 "$web"
  if [[ ! -x "$acme" ]]; then
    local installer
    installer=$(mktemp)
    curl -fsSL -o "$installer" https://get.acme.sh
    sh "$installer" email="$EMAIL"
    rm -f "$installer"
  fi
  [[ -x "$acme" ]] || die "acme.sh не установился"
  force_acme_email
  "$acme" --set-default-ca --server letsencrypt
  "$acme" --issue -d "$DOMAIN" -w "$web" --keylength ec-256 --accountemail "$EMAIL" --server letsencrypt || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    die "Let's Encrypt не выдал сертификат для $DOMAIN (код $rc). Почта $EMAIL должна быть настоящей, и порт 80 этого сервера должен открываться снаружи."
  fi
  install -d -m 755 -o root -g root "$(cert_dir)"
  reload="chmod 644 $(cert_file) && chmod 640 $(key_file) && systemctl reload nginx"
  "$acme" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$(cert_file)" \
    --key-file "$(key_file)" \
    --reloadcmd "$reload"
  fix_cert_perms
  [[ -s "$(cert_file)" && -s "$(key_file)" ]] || die "файлы сертификата пустые"
}

force_acme_email() {
  local conf=/root/.acme.sh/account.conf tmp
  [[ -f "$conf" ]] || return 0
  tmp=$(mktemp)
  grep -v '^ACCOUNT_EMAIL=' "$conf" >"$tmp" || true
  printf "ACCOUNT_EMAIL='%s'\n" "$EMAIL" >>"$tmp"
  cat "$tmp" >"$conf"
  rm -f "$tmp"
}

fix_cert_perms() {
  [[ -n "$PREFIX" ]] && return 0
  [[ -s "$(cert_file)" && -s "$(key_file)" ]] || return 0
  chown root:root "$(cert_file)" "$(key_file)"
  chmod 644 "$(cert_file)"
  chmod 640 "$(key_file)"
}

enable_nginx_site() {
  local avail enabled
  avail=$(nginx_site)
  if [[ -d /etc/nginx/sites-enabled ]]; then
    enabled=/etc/nginx/sites-enabled/selfsite.conf
    ln -sfn "$avail" "$enabled"
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
      rm -f /etc/nginx/sites-enabled/default
      DISABLED_DEFAULT=1
    fi
  elif [[ -d /etc/nginx/conf.d ]]; then
    install -m 644 "$avail" /etc/nginx/conf.d/selfsite.conf
  else
    die "не нашёл sites-enabled и conf.d у nginx"
  fi
}

explain_port80() {
  local line
  line=$(ss -H -ltnp 'sport = :80' 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    say "Порт 80 занят:" >&2
    printf '%s\n' "$line" >&2
  fi
}

stop_unmanaged_nginx() {
  local pid
  systemctl is-active --quiet nginx && return 0
  if [[ -s /run/nginx.pid ]]; then
    pid=$(cat /run/nginx.pid)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" == nginx ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(ss -H -ltnp 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  sleep 1
}

reload_nginx() {
  nginx -t
  stop_unmanaged_nginx
  systemctl enable nginx
  if systemctl reload nginx 2>/dev/null; then
    return 0
  fi
  stop_unmanaged_nginx
  if systemctl restart nginx; then
    return 0
  fi
  explain_port80
  die "nginx не запустился: порт 80 занят. Если это nginx без systemd, останови его. Если это squid или другой прокси, сними его с 80."
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
  fi
}

script_source() {
  local src=${BASH_SOURCE[0]}
  if [[ -f "$SCRIPT_DIR/selfsite.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR/selfsite.sh"
    return 0
  fi
  if [[ -f "$src" && "$src" != /dev/fd/* ]]; then
    printf '%s\n' "$src"
    return 0
  fi
  return 1
}

install_command() {
  local dest=/usr/local/lib/selfsite
  local tmp src
  if ! src=$(script_source); then
    say "Скрипт пришёл потоком из curl. Установка продолжится, а команда selfsite появится, если запустить файл с диска."
    return 0
  fi
  tmp=$(mktemp -d)
  cp -a "$src" "$tmp/selfsite.sh"
  materialize_templates
  mkdir -p "$tmp/share/templates"
  cp -a "$TEMPLATE_DIR/." "$tmp/share/templates/"
  install -d -m 755 "$dest"
  install -m 755 "$tmp/selfsite.sh" "$dest/selfsite.sh"
  rm -rf "$dest/share"
  cp -a "$tmp/share" "$dest/share"
  ln -sfn "$dest/selfsite.sh" /usr/local/bin/selfsite
  rm -rf "$tmp"
}

apply_configs() {
  write_site
  write_nginx
  save_state
}

require_debian() {
  [[ -f /etc/debian_version ]] || die "скрипт ставится на Debian и Ubuntu"
  command -v apt-get >/dev/null 2>&1 || die "нет apt-get"
}

prompt_missing() {
  local answer
  if [[ -z "$DOMAIN" ]]; then
    [[ -t 0 ]] || die "укажите --domain"
    PROMPTED=1
    read -r -p "Домен (A-запись на этот сервер): " DOMAIN
    DOMAIN=${DOMAIN,,}
  fi
  valid_domain "$DOMAIN" || die "домен не похож на имя: $DOMAIN"
  if [[ -z "$EMAIL" ]]; then
    if [[ -t 0 ]]; then
      PROMPTED=1
      read -r -p "Email для Let's Encrypt [admin@${DOMAIN}]: " EMAIL
      EMAIL=${EMAIL:-admin@${DOMAIN}}
    else
      die "укажите --email"
    fi
  fi
  valid_email "$EMAIL" || die "email не похож на адрес: $EMAIL"
  if [[ -z "$TEMPLATE" ]]; then
    if [[ -t 0 ]]; then
      PROMPTED=1
      say "Шаблон сайта:"
      say "  1) ledger — верфь Harbor & Holt"
      say "  2) press  — типография Lumen & Co."
      say "  3) kiln   — керамика Red Clay Atelier"
      read -r -p "Номер [1]: " answer
      case "${answer:-1}" in
        1|ledger) TEMPLATE=ledger ;;
        2|press) TEMPLATE=press ;;
        3|kiln) TEMPLATE=kiln ;;
        *) die "номер шаблона: 1, 2 или 3" ;;
      esac
    else
      TEMPLATE=ledger
    fi
  fi
  valid_template "$TEMPLATE" || die "шаблон: ledger, press или kiln"
  if [[ "$PROMPTED" -eq 1 && -t 0 ]]; then
    say "Домен:  $DOMAIN"
    say "Email:  $EMAIL"
    say "Шаблон: $TEMPLATE"
    say "Xray и чужой порт скрипт не трогает."
    read -r -p "Ставить? [y/N] " answer
    case "$answer" in
      y|Y|yes|Yes) ;;
      *) die "отмена" ;;
    esac
  fi
}

make_self_signed() {
  local dir
  dir=$(cert_dir)
  mkdir -p "$dir"
  if [[ -s "$(cert_file)" && -s "$(key_file)" ]]; then
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$(key_file)" \
    -out "$(cert_file)" \
    -days 2 \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  chmod 644 "$(cert_file)" "$(key_file)"
}

cmd_render() {
  [[ -n "$PREFIX" ]] || die "render пишет только в --prefix, чтобы не задеть систему"
  require_templates
  valid_domain "${DOMAIN:-}" || die "render: нужен --domain"
  valid_email "${EMAIL:-}" || die "render: нужен --email"
  TEMPLATE=${TEMPLATE:-ledger}
  valid_template "$TEMPLATE" || die "шаблон: ledger, press или kiln"
  PREFIX=$(mkdir -p "$PREFIX" && cd "$PREFIX" && pwd)
  if [[ -f "$(state_file)" ]]; then
    load_state
  fi
  make_self_signed
  apply_configs
  say "Собрано в $PREFIX"
  say "Это не выпуск Let's Encrypt и не установка. Сертификат в prefix самоподписанный."
}

cmd_install() {
  [[ -z "$PREFIX" ]] || die "install не принимает --prefix"
  need_root
  require_debian
  require_templates
  if [[ -f "$(state_file)" ]]; then
    load_state
  fi
  prompt_missing
  say "Домен $DOMAIN, шаблон $TEMPLATE. Сайт на 443. Xray скрипт не трогает."
  refuse_if_stream_proxy
  apt_install
  assert_ports_free
  check_dns
  install_command
  mkdir -p "$(acme_dir)" "$(site_dir)"
  chmod 755 /var/www/selfsite "$(acme_dir)" || true
  write_site
  write_nginx
  enable_nginx_site
  reload_nginx
  open_firewall
  issue_cert
  detect_h2
  choose_http2_style
  apply_configs
  enable_nginx_site
  reload_nginx
  say
  say "Готово. Браузер на https://${DOMAIN} показывает сайт."
  say "Инбаунд на другом порту скрипт не менял. Этот порт снаружи оставь закрытым для всех, кроме адреса входа."
}

cmd_status() {
  load_state
  say "selfsite ${VERSION}"
  say "домен:    $DOMAIN"
  say "email:    $EMAIL"
  say "шаблон:   $TEMPLATE"
  say "сайт:     https://${DOMAIN}"
  if [[ -z "$PREFIX" ]]; then
    say "nginx:    $(systemctl is-active nginx 2>/dev/null || echo unknown)"
  else
    say "проверка: каталог $PREFIX, службы не смотрел"
  fi
  if [[ -s "$(cert_file)" ]]; then
    say "сертификат: $(openssl x509 -in "$(cert_file)" -noout -enddate 2>/dev/null | sed 's/notAfter=/до /')"
    say "издатель: $(openssl x509 -in "$(cert_file)" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  else
    say "сертификат: нет файла"
  fi
}

cmd_template() {
  local action next
  action=${1:-list}
  case "$action" in
    list)
      say "ledger  верфь Harbor & Holt"
      say "press   типография Lumen & Co."
      say "kiln    керамика Red Clay Atelier"
      if [[ -f "$(state_file)" ]]; then
        load_state
        say "сейчас: $TEMPLATE"
      fi
      ;;
    use)
      next=${2:-}
      load_state
      if [[ -n "$next" ]]; then
        TEMPLATE=$next
      fi
      valid_template "${TEMPLATE:-}" || die "selfsite template use ledger|press|kiln"
      write_site
      save_state
      if [[ -z "$PREFIX" ]]; then
        systemctl reload nginx || systemctl restart nginx
      fi
      say "Сайт переключён на $TEMPLATE. Каталог: $(site_dir)"
      ;;
    *)
      die "selfsite template list|use"
      ;;
  esac
}

cmd_renew() {
  local acme rc=0
  need_root
  [[ -z "$PREFIX" ]] || die "renew только на установленной системе"
  load_state
  acme=/root/.acme.sh/acme.sh
  [[ -x "$acme" ]] || die "нет acme.sh"
  if [[ "$FORCE" -eq 1 ]]; then
    "$acme" --renew -d "$DOMAIN" --ecc --force || rc=$?
  else
    "$acme" --renew -d "$DOMAIN" --ecc || rc=$?
  fi
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    die "обновление сертификата не удалось (код $rc)"
  fi
  fix_cert_perms
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx || true
  fi
  if [[ "$rc" -eq 2 ]]; then
    say "Срок ещё не подошёл, acme.sh оставил текущий сертификат. Для выпуска сейчас: selfsite renew --force"
  else
    say "Сертификат обновлён."
  fi
  openssl x509 -in "$(cert_file)" -noout -enddate
}

cmd_logs() {
  need_root
  journalctl -u nginx -n 120 --no-pager
}

read_state_loose() {
  local file=$1 line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      DOMAIN)
        if valid_domain "$val"; then
          DOMAIN=$val
        fi
        ;;
      DISABLED_DEFAULT)
        if [[ "$val" == 0 || "$val" == 1 ]]; then
          DISABLED_DEFAULT=$val
        fi
        ;;
    esac
  done <"$file"
}

cmd_uninstall() {
  local acme
  need_root
  [[ -z "$PREFIX" ]] || die "uninstall не принимает --prefix"
  DOMAIN=
  DISABLED_DEFAULT=0
  read_state_loose "$(state_file)"
  if [[ -n "${DOMAIN:-}" && -x /root/.acme.sh/acme.sh ]]; then
    acme=/root/.acme.sh/acme.sh
    "$acme" --remove -d "$DOMAIN" --ecc || true
    rm -rf "/root/.acme.sh/${DOMAIN}_ecc"
  fi
  rm -f /etc/nginx/sites-enabled/selfsite.conf /etc/nginx/sites-available/selfsite.conf /etc/nginx/conf.d/selfsite.conf
  if [[ "${DISABLED_DEFAULT:-0}" == 1 && -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi
  rm -rf /var/www/selfsite /usr/local/etc/selfsite /usr/local/lib/selfsite /usr/local/bin/selfsite
  if command -v nginx >/dev/null 2>&1 && nginx -t; then
    systemctl reload nginx || true
  fi
  say "Сайт selfsite снят. Xray и чужой инбаунд не трогал."
}

cmd_guide() {
  cat <<EOF
Сайт на 443, инбаунд на другом порту

selfsite ставит только страницу. 443 слушает nginx, сертификат Let's Encrypt
на ваш домен. Xray скрипт не устанавливает и его конфиг не открывает.

Порядок, если вход BGS сейчас смотрит на этот сервер в порт 443:

  1. В панели поставь адрес выхода с портом 8443.
  2. В конфиге Xray на сервере смени порт 443 на 8443 и перезапусти Xray.
     443 должен освободиться.
  3. 8443 открой только для адреса, с которого приходит их трафик.
     Остальным этот порт закрой.
  4. Освободи порт 80, если его занимает squid или другая служба.
  5. Поставь сайт:

     sudo bash selfsite.sh @ install --domain exit.example.com --email you@example.com

A-запись домена должна смотреть на этот сервер. Кто открывает домен, видит
страницу. Инбаунд на 8443 живёт отдельно, со своим сертификатом и своим путём.
EOF
}

cmd_menu() {
  local answer name
  need_root
  while true; do
    say
    say "selfsite"
    say "  1  установка / переустановка"
    say "  2  статус"
    say "  3  сменить шаблон"
    say "  4  обновить сертификат"
    say "  5  логи"
    say "  6  удалить"
    say "  0  выход"
    read -r -p "> " answer
    case "$answer" in
      1) cmd_install ;;
      2)
        if [[ ! -f "$(state_file)" ]]; then
          say "Сначала установка."
        else
          cmd_status
        fi
        ;;
      3)
        cmd_template list
        read -r -p "Шаблон (ledger|press|kiln): " name
        cmd_template use "$name"
        ;;
      4) cmd_renew ;;
      5) cmd_logs ;;
      6) cmd_uninstall; exit 0 ;;
      0|q) exit 0 ;;
      *) say "нет такого пункта" ;;
    esac
  done
}

parse_args() {
  local extras=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      @)
        shift
        ;;
      install|uninstall|status|renew|logs|template|menu|render|guide|update|help|-h|--help)
        COMMAND=$1
        shift
        break
        ;;
      *)
        die "неизвестная команда: $1 (selfsite help)"
        ;;
    esac
  done
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain нуждается в значении"
        DOMAIN=${2,,}
        shift 2
        ;;
      --email)
        [[ $# -ge 2 ]] || die "--email нуждается в значении"
        EMAIL=$2
        shift 2
        ;;
      --template)
        [[ $# -ge 2 ]] || die "--template нуждается в значении"
        TEMPLATE=$2
        shift 2
        ;;
      --prefix)
        [[ $# -ge 2 ]] || die "--prefix нуждается в значении"
        PREFIX=$2
        shift 2
        ;;
      --http2-style)
        [[ $# -ge 2 ]] || die "--http2-style нуждается в значении"
        HTTP2_STYLE=$2
        shift 2
        ;;
      --ip)
        [[ $# -ge 2 ]] || die "--ip нуждается в значении"
        PUBLIC_IP=$2
        shift 2
        ;;
      --force) FORCE=1; shift ;;
      --no-h2) USE_H2=0; shift ;;
      --) shift; break ;;
      -*)
        die "неизвестный флаг: $1"
        ;;
      *)
        extras+=("$1")
        shift
        ;;
    esac
  done
  if [[ $# -gt 0 ]]; then
    extras+=("$@")
  fi
  EXTRA=("${extras[@]+"${extras[@]}"}")
}

main() {
  parse_args "$@"
  case "${COMMAND:-}" in
    ""|menu)
      if [[ -t 0 ]]; then
        cmd_menu
      else
        usage
      fi
      ;;
    help|-h|--help) usage ;;
    guide) cmd_guide ;;
    render) cmd_render ;;
    install) cmd_install ;;
    update)
      [[ -z "$PREFIX" ]] || die "update не принимает --prefix"
      need_root
      [[ -f "$(state_file)" ]] || die "сначала install"
      cmd_install
      ;;
    status)
      [[ -n "$PREFIX" ]] || need_root
      cmd_status
      ;;
    renew) cmd_renew ;;
    logs) cmd_logs ;;
    uninstall) cmd_uninstall ;;
    template)
      [[ -n "$PREFIX" ]] || need_root
      cmd_template "${EXTRA[@]+"${EXTRA[@]}"}"
      ;;
    *) die "команда" ;;
  esac
}

main "$@"
