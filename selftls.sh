#!/usr/bin/env bash
# selftls — VLESS over TCP with a real TLS certificate and a fallback site.
# The inbound port belongs to Xray. A browser that is not a client is handed to nginx.
# When that port is not 443, nginx can also serve the same site on 443.
# Reality is not configured. WebSocket, gRPC, and XHTTP are not configured.
#
# Debian and Ubuntu, systemd, root. See README.md.

VERSION=1.3.7

set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "selftls: нужен bash" >&2
  exit 1
fi

trap 'echo "selftls: ошибка на строке $LINENO" >&2' ERR

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
CLIENT_NAME=
PREFIX=
HTTP2_STYLE=
FORCE=0
PURGE=0
USE_H2=1
MODE=
PUBLIC_PORT=
PUBLIC_IP=
PORT_FROM_FLAG=0
STANDALONE=0
PANEL_IP=
NODE_API_PORT=
SITE_443=
SITE_443_EXPLICIT=0
PROMPTED=0
DISABLED_DEFAULT=0
HTTP_PORT=
H2_PORT=

usage() {
  cat <<EOF
selftls ${VERSION}

VLESS TCP + TLS рядом с нодой Remnawave. Порт ноды скрипт спрашивает сам
и не занимает его. Xray панели не перезаписывает. Reality здесь нет.

  sudo bash selftls.sh @ install --domain exit.example.com --email you@example.com

Порт можно передать и флагом, тогда вопрос не задаётся:

  sudo bash selftls.sh @ install --port 9443 --domain exit.example.com --email you@example.com

Скрипт выпускает сертификат и поднимает сайт на localhost. В конце печатает
готовый инбаунд для панели.

Знак @ перед командой игнорируется, как в selfsteal:

  sudo bash selftls.sh @ install --domain example.com --email you@example.com

Шаблоны сайта: ledger (верфь), press (типография), kiln (керамика).

  selftls status
  selftls link
  selftls user add phone
  selftls user rm phone
  selftls user list
  selftls template list
  selftls template use kiln
  selftls renew
  selftls logs
  selftls guide
  sudo ./selftls.sh uninstall
  sudo ./selftls.sh uninstall --purge

Флаги install: --domain --email --port --template --name --ip --force
--ip ставит дополнительный адрес этой ВМ, если A-запись смотрит не на основной.
--force пропускает сверку DNS.
--standalone ставит свой Xray на 443. По умолчанию этого нет: только Remnawave.
Заглушка на порту инбаунда: TCP TLS и flow xtls-rprx-vision, с 80 идёт 301.
Если инбаунд не на 443, скрипт спрашивает, поднять ли тот же сайт на 443.
--site-443 включает его без вопроса, --no-site-443 не ставит.
--panel-ip ограничивает порт API Remnanode этим адресом, остальным отвечает RST.
--node-port задаёт этот порт, если скрипт сам не увидел NODE_PORT.
Нужны Debian или Ubuntu, свободный порт 80 и A-запись домена на этот сервер.
EOF
}

die() {
  printf 'selftls: %s\n' "$*" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "нужен root: sudo ./selftls.sh $COMMAND"
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
  # Let's Encrypt rejects reserved names such as example.com.
  case "$domain" in
    example.com|example.org|example.net|example.edu|localhost|*.example.com|*.example.org|*.example.net|*.localhost)
      return 1
      ;;
  esac
  return 0
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

valid_template() {
  case "$1" in
    ledger|press|kiln) return 0 ;;
    *) return 1 ;;
  esac
}

valid_port() {
  [[ "$1" =~ ^[0-9]{2,5}$ ]] || return 1
  ((10#$1 >= 1024 && 10#$1 <= 65535))
}

valid_public_port() {
  [[ "$1" =~ ^[0-9]{2,5}$ ]] || return 1
  ((10#$1 >= 443 && 10#$1 <= 65535))
}

valid_ipv4() {
  local octet
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"$1"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    ((10#$octet <= 255)) || return 1
  done
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

TEMPLATE_DIR=""

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

state_file() { root_path /usr/local/etc/selftls/selftls.env; }
users_file() { root_path /usr/local/etc/selftls/users.json; }
cert_dir() { root_path /usr/local/etc/selftls/cert; }
cert_file() { root_path /usr/local/etc/selftls/cert/fullchain.pem; }
key_file() { root_path /usr/local/etc/selftls/cert/privkey.pem; }
xray_config() { root_path /usr/local/etc/xray/config.json; }
site_dir() { root_path /var/www/selftls/site; }
acme_dir() { root_path /var/www/selftls/acme; }
nginx_site() { root_path /etc/nginx/sites-available/selftls.conf; }
xray_access_log() { root_path /var/log/xray/access.log; }
xray_error_log() { root_path /var/log/xray/error.log; }
nginx_access_log() { root_path /var/log/nginx/selftls.access.log; }
links_file() { root_path /usr/local/etc/selftls/links.txt; }
clients_dir() { root_path /usr/local/etc/selftls/clients; }
inbound_file() { root_path /usr/local/etc/selftls/remnawave-inbound.json; }

load_state() {
  local file line key val
  file=$(state_file)
  [[ -f "$file" ]] || die "selftls ещё не установлен ($file)"
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
      HTTP_PORT)
        valid_port "$val" || die "битый HTTP_PORT в $file"
        [[ -z "$HTTP_PORT" ]] && HTTP_PORT=$val
        ;;
      H2_PORT)
        valid_port "$val" || die "битый H2_PORT в $file"
        [[ -z "$H2_PORT" ]] && H2_PORT=$val
        ;;
      DISABLED_DEFAULT)
        [[ "$val" == 0 || "$val" == 1 ]] || die "битый DISABLED_DEFAULT в $file"
        DISABLED_DEFAULT=$val
        ;;
      MODE)
        [[ "$val" == standalone || "$val" == remnawave ]] || die "битый MODE в $file"
        [[ -z "$MODE" ]] && MODE=$val
        ;;
      PUBLIC_PORT)
        valid_public_port "$val" || die "битый PUBLIC_PORT в $file"
        [[ -z "$PUBLIC_PORT" ]] && PUBLIC_PORT=$val
        ;;
      PUBLIC_IP)
        [[ -z "$val" ]] && continue
        valid_ipv4 "$val" || die "битый PUBLIC_IP в $file"
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$val
        ;;
      PANEL_IP)
        [[ -z "$val" ]] && continue
        valid_ipv4 "$val" || die "битый PANEL_IP в $file"
        [[ -z "$PANEL_IP" ]] && PANEL_IP=$val
        ;;
      NODE_API_PORT)
        [[ -z "$val" ]] && continue
        valid_port "$val" || die "битый NODE_API_PORT в $file"
        [[ -z "$NODE_API_PORT" ]] && NODE_API_PORT=$val
        ;;
      SITE_443)
        [[ "$val" == 0 || "$val" == 1 ]] || die "битый SITE_443 в $file"
        [[ -z "$SITE_443" ]] && SITE_443=$val
        ;;
      *)
        die "неизвестное поле $key в $file"
        ;;
    esac
  done <"$file"
  [[ -n "$DOMAIN" && -n "$EMAIL" && -n "$TEMPLATE" && -n "$HTTP_PORT" && -n "$H2_PORT" ]] || die "в $file не хватает полей"
  normalize_mode
}

normalize_mode() {
  MODE=${MODE:-standalone}
  PUBLIC_PORT=${PUBLIC_PORT:-443}
  case "$MODE" in
    standalone|remnawave) ;;
    *) die "режим: standalone или remnawave" ;;
  esac
  if [[ "$PUBLIC_PORT" == 80 ]]; then
    die "порт 80 занят выпуском сертификата"
  fi
  valid_public_port "$PUBLIC_PORT" || die "порт ноды кривой: $PUBLIC_PORT"
  if [[ -n "$HTTP_PORT" && "$PUBLIC_PORT" == "$HTTP_PORT" ]]; then
    die "порт ноды $PUBLIC_PORT совпал с локальным сайтом"
  fi
  if [[ -n "$H2_PORT" && "$PUBLIC_PORT" == "$H2_PORT" ]]; then
    die "порт ноды $PUBLIC_PORT совпал с локальным h2"
  fi
  if [[ "$PUBLIC_PORT" == 443 ]]; then
    if [[ "$SITE_443" == 1 && "$SITE_443_EXPLICIT" -eq 1 ]]; then
      say "Инбаунд на 443, nginx отдельно на 443 не ставится: заглушка уже на этом порту." >&2
    fi
    SITE_443=0
  elif [[ "$MODE" != remnawave && "$SITE_443" == 1 ]]; then
    die "отдельный сайт на 443 только рядом с Remnawave, когда нода слушает другой порт"
  elif [[ -n "$SITE_443" && "$SITE_443" != 0 && "$SITE_443" != 1 ]]; then
    die "сайт на 443: 0 или 1"
  fi
}

save_state() {
  local file dir
  normalize_mode
  file=$(state_file)
  dir=$(dirname "$file")
  mkdir -p "$dir"
  cat >"$file" <<EOF
# selftls ${VERSION}
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
TEMPLATE=${TEMPLATE}
HTTP_PORT=${HTTP_PORT}
H2_PORT=${H2_PORT}
DISABLED_DEFAULT=${DISABLED_DEFAULT}
MODE=${MODE}
PUBLIC_PORT=${PUBLIC_PORT}
PUBLIC_IP=${PUBLIC_IP}
PANEL_IP=${PANEL_IP}
NODE_API_PORT=${NODE_API_PORT}
SITE_443=${SITE_443:-0}
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
  # The file exists even when the provider turned IPv6 off. Binding [::]:80 then
  # makes nginx fail at start after `nginx -t` already said the config is fine.
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
    say "В этом nginx нет http_v2. Браузер получит HTTP/1.1, клиенту VLESS это не мешает."
  fi
}

nginx_site_locations() {
  local root_dir=$1
  local proxy=${2:-1}
  cat <<EOF
    root ${root_dir};
    index index.html;
    server_tokens off;
    client_max_body_size 1m;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Strict-Transport-Security "max-age=15552000" always;
EOF
  if [[ "$proxy" -eq 1 ]]; then
    cat <<EOF

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
EOF
  fi
  cat <<EOF

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
EOF
}

write_public_443() {
  local root_dir=$1 access=$2
  local listen4 listen6
  [[ "$SITE_443" == 1 ]] || return 0
  [[ "$PUBLIC_PORT" != 443 ]] || return 0
  [[ -s "$(cert_file)" && -s "$(key_file)" ]] || return 0
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
    access_log ${access} selftls;
EOF
  if [[ "$USE_H2" -eq 1 && "$HTTP2_STYLE" == modern ]]; then
    printf '    http2 on;\n'
  fi
  nginx_site_locations "$root_dir" 0
  printf '}\n'
}

write_nginx() {
  local file root_dir acme access h2_listen https_redir
  file=$(nginx_site)
  root_dir=$(site_dir)
  acme=$(acme_dir)
  access=$(nginx_access_log)
  mkdir -p "$(dirname "$file")" "$(dirname "$access")" "$acme"
  choose_http2_style
  detect_h2
  normalize_mode
  if [[ "$PUBLIC_PORT" == 443 || "$SITE_443" == 1 ]]; then
    # shellcheck disable=SC2016
    https_redir="return 301 https://${DOMAIN}"'$request_uri;'
  else
    # shellcheck disable=SC2016
    https_redir="return 301 https://${DOMAIN}:${PUBLIC_PORT}"'$request_uri;'
  fi

  {
    cat <<EOF
log_format selftls '\$proxy_protocol_addr \$remote_addr [\$time_local] "\$request" '
                   '\$status \$body_bytes_sent';

server {
    listen 80 default_server;
EOF
    if has_ipv6; then
      printf '    listen [::]:80 default_server;\n'
    fi
    cat <<EOF
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        root ${acme};
    }

    location / {
        ${https_redir}
    }
}

server {
    listen 127.0.0.1:${HTTP_PORT} proxy_protocol default_server;
    server_name _;
    access_log ${access} selftls;
$(nginx_site_locations "$root_dir")
}
EOF
    if [[ "$USE_H2" -eq 1 ]]; then
      h2_listen="listen 127.0.0.1:${H2_PORT}"
      if [[ "$HTTP2_STYLE" == classic ]]; then
        h2_listen+=" http2"
      fi
      h2_listen+=" proxy_protocol default_server;"
      cat <<EOF

server {
    ${h2_listen}
    server_name _;
    access_log ${access} selftls;
EOF
      if [[ "$HTTP2_STYLE" == modern ]]; then
        printf '    http2 on;\n'
      fi
      nginx_site_locations "$root_dir"
      printf '}\n'
    fi
    write_public_443 "$root_dir" "$access"
  } >"$file"
}

write_xray() {
  local dest clients fallbacks alpn tmp
  dest=$(xray_config)
  mkdir -p "$(dirname "$dest")" "$(dirname "$(xray_access_log)")"
  [[ -f "$(users_file)" ]] || die "нет $(users_file)"
  clients=$(jq -c '[.[] | {id: .id, flow: "xtls-rprx-vision", email: .name}]' "$(users_file)")
  [[ "$clients" != "[]" ]] || die "список клиентов пуст"
  if [[ "$USE_H2" -eq 1 ]]; then
    alpn='["h2","http/1.1"]'
    fallbacks=$(jq -n \
      --arg http "127.0.0.1:${HTTP_PORT}" \
      --arg h2 "127.0.0.1:${H2_PORT}" \
      '[{dest: $http, xver: 1}, {alpn: "h2", dest: $h2, xver: 1}]')
  else
    alpn='["http/1.1"]'
    fallbacks=$(jq -n --arg http "127.0.0.1:${HTTP_PORT}" '[{dest: $http, xver: 1}]')
  fi
  tmp=$(mktemp)
  jq -n \
    --argjson clients "$clients" \
    --argjson fallbacks "$fallbacks" \
    --argjson alpn "$alpn" \
    --arg cert "$(cert_file)" \
    --arg key "$(key_file)" \
    --arg access "$(xray_access_log)" \
    --arg error "$(xray_error_log)" \
    '{
      log: {loglevel: "warning", access: $access, error: $error},
      inbounds: [{
        listen: "0.0.0.0",
        port: 443,
        protocol: "vless",
        tag: "vless-tcp-tls",
        settings: {
          clients: $clients,
          decryption: "none",
          fallbacks: $fallbacks
        },
        streamSettings: {
          method: "raw",
          security: "tls",
          tlsSettings: {
            alpn: $alpn,
            minVersion: "1.2",
            maxVersion: "1.3",
            certificates: [{certificateFile: $cert, keyFile: $key}]
          }
        },
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
      }],
      outbounds: [
        {
          protocol: "freedom",
          tag: "direct",
          streamSettings: {sockopt: {domainStrategy: "UseIPv4"}}
        },
        {protocol: "blackhole", tag: "block"}
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [{type: "field", protocol: ["bittorrent"], outboundTag: "block"}]
      }
    }' >"$tmp"
  mv "$tmp" "$dest"
  if [[ -n "$PREFIX" ]]; then
    chmod 644 "$dest"
  else
    chown root:xray "$dest"
    chmod 640 "$dest"
  fi
}

write_remnawave_inbound() {
  local dest tmp fallbacks alpn
  normalize_mode
  detect_h2
  dest=$(inbound_file)
  mkdir -p "$(dirname "$dest")"
  if [[ "$USE_H2" -eq 1 ]]; then
    alpn='["h2","http/1.1"]'
    fallbacks=$(jq -n \
      --arg http "127.0.0.1:${HTTP_PORT}" \
      --arg h2 "127.0.0.1:${H2_PORT}" \
      '[{dest: $http, xver: 1}, {alpn: "h2", dest: $h2, xver: 1}]')
  else
    alpn='["http/1.1"]'
    fallbacks=$(jq -n --arg http "127.0.0.1:${HTTP_PORT}" '[{dest: $http, xver: 1}]')
  fi
  tmp=$(mktemp)
  jq -n \
    --argjson port "$PUBLIC_PORT" \
    --argjson fallbacks "$fallbacks" \
    --argjson alpn "$alpn" \
    --arg cert "$(cert_file)" \
    --arg key "$(key_file)" \
    --arg serverName "$DOMAIN" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        listen: "0.0.0.0",
        port: $port,
        protocol: "vless",
        tag: "vless-tcp-tls",
        settings: {
          clients: [],
          decryption: "none",
          flow: "xtls-rprx-vision",
          fallbacks: $fallbacks
        },
        streamSettings: {
          network: "tcp",
          security: "tls",
          tlsSettings: {
            serverName: $serverName,
            alpn: $alpn,
            minVersion: "1.2",
            maxVersion: "1.3",
            certificates: [{certificateFile: $cert, keyFile: $key}]
          }
        },
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
      }],
      outbounds: [
        {tag: "DIRECT", protocol: "freedom"},
        {tag: "BLOCK", protocol: "blackhole"}
      ],
      routing: {rules: []}
    }' >"$tmp"
  mv "$tmp" "$dest"
  chmod 644 "$dest"
}

new_uuid() {
  # The fixed UUID is only for the first client of a --prefix render, so tests
  # stay stable and a later `user add` still gets a random id.
  if [[ -n "$PREFIX" && -n "${SELFTLS_TEST_UUID:-}" && ! -f "$(users_file)" ]]; then
    valid_uuid "$SELFTLS_TEST_UUID" || die "SELFTLS_TEST_UUID не похож на UUID"
    printf '%s\n' "$SELFTLS_TEST_UUID"
    return 0
  fi
  cat /proc/sys/kernel/random/uuid
}

ensure_users() {
  local file name id
  file=$(users_file)
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    jq -e 'type == "array" and length > 0' "$file" >/dev/null || die "$file пустой или битый"
    return 0
  fi
  name=${CLIENT_NAME:-main}
  valid_name "$name" || die "имя клиента: буквы, цифры, _ и -, до 32 знаков"
  id=$(new_uuid)
  jq -n --arg name "$name" --arg id "$id" '[{name: $name, id: $id}]' >"$file"
  chmod 600 "$file"
}

vless_link() {
  local id=$1 name=$2
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision#%s\n' \
    "$id" "$DOMAIN" "$DOMAIN" "$name"
}

write_client_files() {
  local dir name id
  dir=$(clients_dir)
  mkdir -p "$dir"
  find "$dir" -mindepth 1 -maxdepth 1 -type f -delete
  while IFS=$'\t' read -r name id; do
    [[ -n "$name" ]] || continue
    jq -n --arg domain "$DOMAIN" --arg id "$id" --arg name "$name" \
      '{
        log: {loglevel: "warning"},
        inbounds: [{
          listen: "127.0.0.1",
          port: 10808,
          protocol: "socks",
          settings: {udp: true}
        }],
        outbounds: [{
          protocol: "vless",
          tag: $name,
          settings: {
            vnext: [{
              address: $domain,
              port: 443,
              users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]
            }]
          },
          streamSettings: {
            network: "tcp",
            security: "tls",
            tlsSettings: {serverName: $domain, fingerprint: "chrome"}
          }
        }]
      }' >"$dir/${name}.xray.json"
    jq -n --arg domain "$DOMAIN" --arg id "$id" --arg name "$name" \
      '{
        type: "vless",
        tag: $name,
        server: $domain,
        server_port: 443,
        uuid: $id,
        flow: "xtls-rprx-vision",
        tls: {
          enabled: true,
          server_name: $domain,
          utls: {enabled: true, fingerprint: "chrome"}
        }
      }' >"$dir/${name}.sing-box.json"
  done < <(jq -r '.[] | [.name, .id] | @tsv' "$(users_file)")
  chmod 600 "$dir"/*.json
}

write_links() {
  local file name id
  file=$(links_file)
  : >"$file"
  while IFS=$'\t' read -r name id; do
    vless_link "$id" "$name" >>"$file"
  done < <(jq -r '.[] | [.name, .id] | @tsv' "$(users_file)")
  chmod 600 "$file"
  write_client_files
}

print_links() {
  cat "$(links_file)"
}

port_busy() {
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

pick_ports() {
  local base
  if [[ -n "$HTTP_PORT" && -n "$H2_PORT" ]]; then
    if ! valid_port "$HTTP_PORT" || ! valid_port "$H2_PORT"; then
      die "порты fallback заданы криво"
    fi
    return 0
  fi
  for base in 8080 18080 28080 38080; do
    if ! port_busy "$base" && ! port_busy "$((base + 1))"; then
      HTTP_PORT=$base
      H2_PORT=$((base + 1))
      return 0
    fi
  done
  die "нет свободной пары портов на localhost для сайта"
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
  if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then
    say "У $DOMAIN есть AAAA. Xray слушает только IPv4. Уберите AAAA, иначе часть клиентов уйдёт мимо."
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
    die "На этом хосте nginx только проксирует TCP. Это вход или мост. Скрипт ставится на выход, рядом с нодой Remnawave."
  fi
}

assert_ports_free() {
  local row
  if [[ "$MODE" != remnawave ]]; then
    row=$(listeners 443)
    if [[ -n "$row" ]] && ! grep -q 'xray' <<<"$row"; then
      die "порт 443 занят не Xray: $row"
    fi
  fi
  row=$(listeners 80)
  if [[ -n "$row" ]] && ! grep -q 'nginx' <<<"$row"; then
    die "порт 80 занят не nginx: $row"
  fi
  if systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
    die "Apache уже слушает веб. Остановите его сами: selftls его не трогает."
  fi
  if [[ "$SITE_443" == 1 ]]; then
    row=$(listeners 443)
    if [[ -n "$row" ]] && ! grep -q 'nginx' <<<"$row"; then
      die "порт 443 занят, сайт туда не ставлю: $row. Освободи его или повтори с --no-site-443"
    fi
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx curl socat openssl jq qrencode ca-certificates unzip cron
}

install_xray_core() {
  local installer
  installer=$(mktemp)
  curl -fsSL -o "$installer" https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  bash "$installer" install
  rm -f "$installer"
  id xray >/dev/null 2>&1 || die "пользователь xray не появился после установки ядра"
  command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray ]] || die "бинарник xray не встал"
}

issue_cert() {
  local acme web
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
  # A failed registration leaves the old contact in account.conf, and a later
  # --accountemail does not replace it. Let's Encrypt then keeps rejecting example.com.
  force_acme_email
  "$acme" --set-default-ca --server letsencrypt
  local rc=0
  "$acme" --issue -d "$DOMAIN" -w "$web" --keylength ec-256 --accountemail "$EMAIL" --server letsencrypt || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    die "Let's Encrypt не выдал сертификат для $DOMAIN (код $rc). Почта $EMAIL должна быть настоящей, и порт 80 этого сервера должен открываться снаружи."
  fi
  local group
  group=$(cert_group)
  install -d -m 750 -o root -g "$group" "$(cert_dir)"
  local reload
  # acme.sh runs this as soon as the files are in place. A failed restart must not abort issuance.
  reload="chown root:${group} $(cert_file) $(key_file) && chmod 644 $(cert_file) && chmod 640 $(key_file) && true"
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

cert_group() {
  if getent group xray >/dev/null 2>&1; then
    printf '%s\n' xray
  elif getent group remnanode >/dev/null 2>&1; then
    printf '%s\n' remnanode
  else
    printf '%s\n' root
  fi
}

fix_cert_perms() {
  local group
  [[ -n "$PREFIX" ]] && return 0
  [[ -s "$(cert_file)" && -s "$(key_file)" ]] || return 0
  group=$(cert_group)
  chown "root:${group}" "$(cert_file)" "$(key_file)"
  chmod 644 "$(cert_file)"
  chmod 640 "$(key_file)"
}

reload_node() {
  if [[ "$MODE" == remnawave ]]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files remnanode.service --no-legend 2>/dev/null | grep -q remnanode; then
      systemctl restart remnanode || say "Не смог перезапустить remnanode. Сделай это в панели, когда сертификат уже на диске."
      return 0
    fi
    if command -v docker >/dev/null 2>&1; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
        docker restart remnanode || true
        return 0
      fi
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnawave-node'; then
        docker restart remnawave-node || true
        return 0
      fi
    fi
    say "Службу ноды не нашёл. Сертификат уже на диске. Перезапусти ноду Remnawave сам."
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart xray || true
  fi
}

test_xray_config() {
  local bin=/usr/local/bin/xray
  [[ -x "$bin" ]] || bin=$(command -v xray || true)
  [[ -n "$bin" ]] || die "нет бинарника xray, конфиг не проверен"
  "$bin" run -test -config "$(xray_config)"
}

enable_nginx_site() {
  local avail enabled
  avail=$(nginx_site)
  if [[ -d /etc/nginx/sites-enabled ]]; then
    enabled=/etc/nginx/sites-enabled/selftls.conf
    ln -sfn "$avail" "$enabled"
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
      rm -f /etc/nginx/sites-enabled/default
      DISABLED_DEFAULT=1
    fi
  elif [[ -d /etc/nginx/conf.d ]]; then
    install -m 644 "$avail" /etc/nginx/conf.d/selftls.conf
  else
    die "не нашёл sites-enabled и conf.d у nginx"
  fi
}

explain_port80() {
  local line names
  line=$(ss -H -ltnp 'sport = :80' 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    say "Порт 80 занят:" >&2
    printf '%s\n' "$line" >&2
  fi
  if command -v docker >/dev/null 2>&1; then
    names=$(docker ps --filter publish=80 --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
    if [[ -n "$names" ]]; then
      say "Порт 80 публикует контейнер: ${names}" >&2
    fi
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
  # ss lists every worker on one line. A pattern that keeps only the last pid
  # leaves the master alive, and the listen socket stays on port 80.
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" == nginx ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(ss -H -ltnp 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  sleep 1
}

cert_mount() {
  printf '%s\n' '/usr/local/etc/selftls/cert:/usr/local/etc/selftls/cert:ro'
}

find_compose_file() {
  local name dir file
  if command -v docker >/dev/null 2>&1; then
    for name in remnanode remnawave-node; do
      dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$name" 2>/dev/null || true)
      file=${dir%%,*}
      if [[ -n "$file" && -f "$file" ]]; then
        printf '%s\n' "$file"
        return 0
      fi
    done
  fi
  for file in /opt/remnanode/docker-compose.yml /opt/remnanode/docker-compose.yaml /opt/remnanode/compose.yml; do
    if [[ -f "$file" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

insert_cert_volume() {
  local file=$1 service=${2:-}
  local mount line indent svc_indent vol_indent item_indent
  local -a lines=()
  local i n svc_at=-1 vol_at=-1 end in_services=0
  [[ -f "$file" ]] || return 1
  mount=$(cert_mount)
  if grep -Fq "$mount" "$file"; then
    return 0
  fi
  mapfile -t lines <"$file"
  n=${#lines[@]}
  if [[ -n "$service" ]]; then
    for ((i = 0; i < n; i++)); do
      line=${lines[$i]}
      if [[ "$line" =~ ^([[:space:]]*)"$service":[[:space:]]*$ ]]; then
        svc_at=$i
        svc_indent=${#BASH_REMATCH[1]}
        break
      fi
    done
  fi
  if [[ "$svc_at" -lt 0 ]]; then
    for ((i = 0; i < n; i++)); do
      line=${lines[$i]}
      if [[ "$line" =~ ^[[:space:]]*services:[[:space:]]*$ ]]; then
        in_services=1
        continue
      fi
      if [[ "$in_services" -eq 1 && "$line" =~ ^([[:space:]]+)([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
        svc_at=$i
        svc_indent=${#BASH_REMATCH[1]}
        break
      fi
    done
  fi
  [[ "$svc_at" -ge 0 ]] || return 1
  end=$n
  for ((i = svc_at + 1; i < n; i++)); do
    line=${lines[$i]}
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([[:space:]]*) ]] || continue
    indent=${#BASH_REMATCH[1]}
    if (( indent <= svc_indent )); then
      end=$i
      break
    fi
    if [[ "$line" =~ ^([[:space:]]*)volumes:[[:space:]]*$ ]]; then
      vol_at=$i
      vol_indent=${#BASH_REMATCH[1]}
    fi
  done
  item_indent=$((svc_indent + 4))
  if [[ "$vol_at" -ge 0 ]]; then
    item_indent=$((vol_indent + 2))
    for ((i = vol_at + 1; i < end; i++)); do
      line=${lines[$i]}
      if [[ "$line" =~ ^([[:space:]]*)-[[:space:]] ]]; then
        item_indent=${#BASH_REMATCH[1]}
        break
      fi
    done
  fi
  local tmp
  tmp=$(mktemp)
  for ((i = 0; i < n; i++)); do
    if [[ "$vol_at" -lt 0 && "$i" -eq "$end" ]]; then
      printf '%*svolumes:\n' $((svc_indent + 2)) '' >>"$tmp"
      printf '%*s- %s\n' "$item_indent" '' "$mount" >>"$tmp"
    fi
    printf '%s\n' "${lines[$i]}" >>"$tmp"
    if [[ "$vol_at" -ge 0 && "$i" -eq "$vol_at" ]]; then
      printf '%*s- %s\n' "$item_indent" '' "$mount" >>"$tmp"
    fi
  done
  if [[ "$vol_at" -lt 0 && "$end" -eq "$n" ]]; then
    printf '%*svolumes:\n' $((svc_indent + 2)) '' >>"$tmp"
    printf '%*s- %s\n' "$item_indent" '' "$mount" >>"$tmp"
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

recreate_compose() {
  local file=$1 dir
  dir=$(dirname "$file")
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$file" --project-directory "$dir" up -d
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$file" up -d
    return
  fi
  return 1
}

mount_cert_in_compose() {
  local file service
  file=$(find_compose_file) || {
    say "docker-compose.yml ноды не нашёл. Том сам не добавил." >&2
    return 0
  }
  service=
  if command -v docker >/dev/null 2>&1; then
    service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' remnanode 2>/dev/null || true)
    [[ -n "$service" ]] || service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' remnawave-node 2>/dev/null || true)
  fi
  if grep -Fq "$(cert_mount)" "$file"; then
    return 0
  fi
  insert_cert_volume "$file" "$service" || {
    say "Не смог дописать том в $file." >&2
    return 0
  }
  say "Том сертификата добавлен в $file" >&2
  recreate_compose "$file" || say "Контейнер сам не пересоздал. В каталоге файла: docker compose up -d" >&2
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
  die "nginx не запустился: порт 80 занят. Если это nginx без systemd, останови его. Если это контейнер, сними с него публикацию 80."
}

detect_node_api_port() {
  local name env port file
  if command -v docker >/dev/null 2>&1; then
    for name in remnanode remnawave-node; do
      env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null || true)
      port=$(printf '%s\n' "$env" | sed -n 's/^NODE_PORT=//p' | head -n 1)
      if valid_port "$port"; then
        printf '%s\n' "$port"
        return 0
      fi
    done
  fi
  for file in /opt/remnanode/.env /opt/remnawave/.env; do
    [[ -f "$file" ]] || continue
    port=$(sed -n 's/^NODE_PORT=//p' "$file" | head -n 1)
    if valid_port "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

prompt_panel_lock() {
  [[ "$MODE" == remnawave ]] || return 0
  if [[ -z "$PANEL_IP" && -t 0 ]]; then
    PROMPTED=1
    read -r -p "IP панели, чтобы закрыть порт Remnanode [пропустить]: " PANEL_IP
  fi
  [[ -n "$PANEL_IP" ]] || return 0
  valid_ipv4 "$PANEL_IP" || die "IP панели кривой: $PANEL_IP"
  if [[ -z "$NODE_API_PORT" ]]; then
    NODE_API_PORT=$(detect_node_api_port || true)
  fi
  if [[ -z "$NODE_API_PORT" && -t 0 ]]; then
    read -r -p "Порт Remnanode, NODE_PORT: " NODE_API_PORT
  fi
  [[ -n "$NODE_API_PORT" ]] || die "укажите --node-port, порт API Remnanode"
  valid_port "$NODE_API_PORT" || die "порт Remnanode кривой: $NODE_API_PORT"
  if [[ "$NODE_API_PORT" == 80 || "$NODE_API_PORT" == "$PUBLIC_PORT" ]]; then
    die "порт Remnanode не должен быть 80 или портом инбаунда"
  fi
}

prompt_site_443() {
  local answer
  if [[ "$MODE" != remnawave || "$PUBLIC_PORT" == 443 ]]; then
    return 0
  fi
  if [[ -z "$SITE_443" ]]; then
    if [[ -t 0 ]]; then
      PROMPTED=1
      read -r -p "На 443 ноды нет. Поднять там тот же сайт? [Y/n] " answer
      case "$answer" in
        n|N|no|No) SITE_443=0 ;;
        *) SITE_443=1 ;;
      esac
    else
      SITE_443=0
    fi
  fi
  [[ "$SITE_443" == 0 || "$SITE_443" == 1 ]] || die "сайт на 443: 0 или 1"
  if [[ "$SITE_443" == 1 && "$NODE_API_PORT" == 443 ]]; then
    die "порт Remnanode 443, на него сайт не поставить"
  fi
}

lock_node_api() {
  [[ "$MODE" == remnawave ]] || return 0
  [[ -n "$PANEL_IP" && -n "$NODE_API_PORT" ]] || return 0
  [[ -z "$PREFIX" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp
    ufw deny "$NODE_API_PORT"/tcp
    say "Порт Remnanode ${NODE_API_PORT}: с ${PANEL_IP} пускает, остальным отказ." >&2
    return 0
  fi
  command -v iptables >/dev/null 2>&1 || {
    say "iptables нет, порт Remnanode сам не закрыл." >&2
    return 0
  }
  iptables -C INPUT -p tcp --dport "$NODE_API_PORT" -s "$PANEL_IP" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p tcp --dport "$NODE_API_PORT" -s "$PANEL_IP" -j ACCEPT
  iptables -C INPUT -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset 2>/dev/null \
      || ip6tables -A INPUT -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset
  fi
  if iptables -S DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -p tcp --dport "$NODE_API_PORT" -s "$PANEL_IP" -j RETURN 2>/dev/null \
      || iptables -I DOCKER-USER -p tcp --dport "$NODE_API_PORT" -s "$PANEL_IP" -j RETURN
    iptables -C DOCKER-USER -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset 2>/dev/null \
      || iptables -A DOCKER-USER -p tcp --dport "$NODE_API_PORT" -j REJECT --reject-with tcp-reset
  fi
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
  say "Порт Remnanode ${NODE_API_PORT}: с ${PANEL_IP} пускает, остальным RST." >&2
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
  if [[ -f "$SCRIPT_DIR/selftls.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR/selftls.sh"
    return 0
  fi
  if [[ -f "$src" && "$src" != /dev/fd/* ]]; then
    printf '%s\n' "$src"
    return 0
  fi
  return 1
}

install_command() {
  local dest=/usr/local/lib/selftls
  local tmp src
  if ! src=$(script_source); then
    say "Скрипт пришёл потоком из curl. Установка продолжится, а команда selftls появится, если запустить файл с диска."
    return 0
  fi
  tmp=$(mktemp -d)
  cp -a "$src" "$tmp/selftls.sh"
  materialize_templates
  mkdir -p "$tmp/share/templates"
  cp -a "$TEMPLATE_DIR/." "$tmp/share/templates/"
  install -d -m 755 "$dest"
  install -m 755 "$tmp/selftls.sh" "$dest/selftls.sh"
  rm -rf "$dest/share"
  cp -a "$tmp/share" "$dest/share"
  ln -sfn "$dest/selftls.sh" /usr/local/bin/selftls
  rm -rf "$tmp"
}

apply_configs() {
  write_site
  write_nginx
  if [[ "$MODE" == remnawave ]]; then
    write_remnawave_inbound
  else
    write_xray
    write_links
  fi
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
  if [[ "$MODE" == remnawave && "$PORT_FROM_FLAG" -eq 0 ]]; then
    if [[ -t 0 ]]; then
      PROMPTED=1
      if [[ -n "$PUBLIC_PORT" ]]; then
        read -r -p "Порт ноды Remnawave [$PUBLIC_PORT]: " answer
        [[ -n "$answer" ]] && PUBLIC_PORT=$answer
      else
        read -r -p "Порт инбаунда, для заглушки это 443: " PUBLIC_PORT
      fi
    elif [[ -z "$PUBLIC_PORT" ]]; then
      die "укажите --port, на котором уже слушает нода"
    fi
  fi
  if [[ "$MODE" == remnawave ]]; then
    if [[ "$PUBLIC_PORT" == 80 ]]; then
      die "порт 80 занят выпуском сертификата"
    fi
    valid_public_port "$PUBLIC_PORT" || die "порт ноды кривой: ${PUBLIC_PORT:-пусто}"
  fi
  prompt_panel_lock
  prompt_site_443
  if [[ "$PROMPTED" -eq 1 && -t 0 ]]; then
    say "Домен:   $DOMAIN"
    say "Email:   $EMAIL"
    say "Шаблон:  $TEMPLATE"
    if [[ "$MODE" == remnawave ]]; then
      say "Порт:    $PUBLIC_PORT"
      if [[ -n "$PANEL_IP" ]]; then
        say "Панель:  $PANEL_IP, порт API $NODE_API_PORT"
      fi
      if [[ "$PUBLIC_PORT" != 443 ]]; then
        if [[ "$SITE_443" == 1 ]]; then
          say "Сайт:    ещё и на 443"
        else
          say "Сайт:    только на порту инбаунда"
        fi
      fi
    fi
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
  HTTP_PORT=${HTTP_PORT:-8080}
  H2_PORT=${H2_PORT:-8081}
  if ! valid_port "$HTTP_PORT" || ! valid_port "$H2_PORT"; then
    die "порты"
  fi
  normalize_mode
  if [[ "$MODE" != remnawave ]]; then
    ensure_users
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
  if [[ "$STANDALONE" -eq 0 ]]; then
    MODE=remnawave
  fi
  prompt_missing
  normalize_mode
  pick_ports
  say "Домен $DOMAIN, шаблон $TEMPLATE, порт ${PUBLIC_PORT}, fallback 127.0.0.1:${HTTP_PORT} и :${H2_PORT}"
  if [[ "$SITE_443" == 1 ]]; then
    say "Сайт на 443 поднимется после выпуска сертификата. Инбаунд остаётся на ${PUBLIC_PORT}."
  fi
  refuse_if_stream_proxy
  apt_install
  assert_ports_free
  check_dns
  install_command
  if [[ "$MODE" != remnawave ]]; then
    install_xray_core
  fi
  mkdir -p "$(acme_dir)" "$(site_dir)"
  chmod 755 /var/www/selftls "$(acme_dir)" || true
  # Port 80 has to answer before Let's Encrypt will issue the certificate.
  write_site
  write_nginx
  enable_nginx_site
  reload_nginx
  open_firewall
  issue_cert
  if [[ "$MODE" != remnawave ]]; then
    ensure_users
  fi
  detect_h2
  choose_http2_style
  apply_configs
  enable_nginx_site
  reload_nginx
  if [[ "$MODE" == remnawave ]]; then
    reload_node
    mount_cert_in_compose
    lock_node_api
    if [[ "$SITE_443" == 1 ]]; then
      say "Сайт открывается на https://${DOMAIN}. VLESS на 443 не слушает, инбаунд на ${PUBLIC_PORT}."
    fi
    cat "$(inbound_file)"
    exit 0
  fi
  test_xray_config
  systemctl enable xray
  systemctl restart xray
  say
  say "Готово. Браузер на https://${DOMAIN} показывает сайт. Клиент — ссылка ниже."
  say "Xray слушает 0.0.0.0:${PUBLIC_PORT}, nginx снаружи только :80."
  print_links
  if [[ -t 1 ]] && command -v qrencode >/dev/null 2>&1; then
    say
    head -n 1 "$(links_file)" | qrencode -t ANSIUTF8 || true
  fi
  say
  say "Файлы клиентов: /usr/local/etc/selftls/clients/"
  say "Свой HTML можно положить в /var/www/selftls/site — template use его затрёт."
}

cmd_link() {
  load_state
  if [[ "$MODE" == remnawave ]]; then
    [[ -f "$(inbound_file)" ]] || write_remnawave_inbound
    cat "$(inbound_file)"
    return 0
  fi
  [[ -f "$(links_file)" ]] || write_links
  print_links
  if [[ -t 2 ]] && command -v qrencode >/dev/null 2>&1; then
    say "QR первой ссылки:" >&2
    head -n 1 "$(links_file)" | qrencode -t ANSIUTF8 >&2 || true
  fi
}

cmd_status() {
  load_state
  say "selftls ${VERSION}"
  say "режим:    $MODE"
  say "домен:    $DOMAIN"
  say "email:    $EMAIL"
  say "шаблон:   $TEMPLATE"
  say "порт:     $PUBLIC_PORT"
  if [[ "$PUBLIC_PORT" == 443 ]]; then
    say "сайт 443: на порту инбаунда"
  elif [[ "$SITE_443" == 1 ]]; then
    say "сайт 443: nginx, тот же шаблон"
  else
    say "сайт 443: нет"
  fi
  say "fallback: 127.0.0.1:${HTTP_PORT} (http/1.1), 127.0.0.1:${H2_PORT} (h2)"
  if [[ "$MODE" == remnawave ]]; then
    say "клиенты:  их ведёт панель Remnawave"
  else
    [[ -f "$(users_file)" ]] || die "нет списка клиентов"
    [[ -f "$(links_file)" ]] || write_links
    say "клиенты:  $(jq 'length' "$(users_file)")"
  fi
  if [[ -z "$PREFIX" ]]; then
    if [[ "$MODE" != remnawave ]]; then
      say "xray:     $(systemctl is-active xray 2>/dev/null || echo unknown)"
    fi
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
  say
  if [[ "$MODE" == remnawave ]]; then
    [[ -f "$(inbound_file)" ]] || write_remnawave_inbound
    cat "$(inbound_file)"
  else
    print_links
  fi
}

cmd_user() {
  local action name id tmp count
  load_state
  if [[ "$MODE" == remnawave ]]; then
    die "в режиме remnawave клиентов добавляет панель, не этот скрипт"
  fi
  action=${1:-}
  name=${2:-${CLIENT_NAME:-}}
  case "$action" in
    list)
      jq -r '.[] | "\(.name)\t\(.id)"' "$(users_file)"
      return 0
      ;;
    add)
      valid_name "${name:-}" || die "selftls user add <имя>"
      if jq -e --arg name "$name" 'any(.[]; .name == $name)' "$(users_file)" >/dev/null; then
        die "клиент $name уже есть"
      fi
      id=$(new_uuid)
      tmp=$(mktemp)
      jq --arg name "$name" --arg id "$id" '. + [{name: $name, id: $id}]' "$(users_file)" >"$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$(users_file)"
      ;;
    rm|remove)
      valid_name "${name:-}" || die "selftls user rm <имя>"
      jq -e --arg name "$name" 'any(.[]; .name == $name)' "$(users_file)" >/dev/null || die "нет клиента $name"
      count=$(jq 'length' "$(users_file)")
      [[ "$count" -gt 1 ]] || die "последнего клиента не удаляю"
      tmp=$(mktemp)
      jq --arg name "$name" 'map(select(.name != $name))' "$(users_file)" >"$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$(users_file)"
      ;;
    *)
      die "selftls user add|rm|list"
      ;;
  esac
  detect_h2
  choose_http2_style
  write_xray
  write_links
  if [[ -z "$PREFIX" ]]; then
    fix_cert_perms
    test_xray_config
    systemctl restart xray
  fi
  say "Клиенты:"
  jq -r '.[].name' "$(users_file)"
  print_links
}

cmd_template() {
  local action
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
      local next=${2:-}
      load_state
      if [[ -n "$next" ]]; then
        TEMPLATE=$next
      fi
      valid_template "${TEMPLATE:-}" || die "selftls template use ledger|press|kiln"
      write_site
      save_state
      if [[ -z "$PREFIX" ]]; then
        systemctl reload nginx || systemctl restart nginx
      fi
      say "Сайт переключён на $TEMPLATE. Каталог: $(site_dir)"
      ;;
    *)
      die "selftls template list|use"
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
  # acme.sh uses 2 when the certificate is not due yet.
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    die "обновление сертификата не удалось (код $rc)"
  fi
  fix_cert_perms
  reload_node
  if [[ "$rc" -eq 2 ]]; then
    say "Срок ещё не подошёл, acme.sh оставил текущий сертификат. Для выпуска сейчас: selftls renew --force"
  else
    say "Сертификат обновлён."
  fi
  openssl x509 -in "$(cert_file)" -noout -enddate
}

cmd_logs() {
  need_root
  journalctl -u xray -u nginx -n 120 --no-pager
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
      MODE)
        if [[ "$val" == standalone || "$val" == remnawave ]]; then
          MODE=$val
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
  MODE=
  read_state_loose "$(state_file)"
  normalize_mode || true
  if [[ -n "${DOMAIN:-}" && -x /root/.acme.sh/acme.sh ]]; then
    acme=/root/.acme.sh/acme.sh
    "$acme" --remove -d "$DOMAIN" --ecc || true
    rm -rf "/root/.acme.sh/${DOMAIN}_ecc"
  fi
  rm -f /etc/nginx/sites-enabled/selftls.conf /etc/nginx/sites-available/selftls.conf /etc/nginx/conf.d/selftls.conf
  if [[ "${DISABLED_DEFAULT:-0}" == 1 && -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi
  rm -rf /var/www/selftls /usr/local/etc/selftls /usr/local/lib/selftls /usr/local/bin/selftls
  if [[ "$MODE" == remnawave ]]; then
    say "Сайт и сертификат сняты. Ноду Remnawave и прокси на входе с мостом не трогал."
  elif [[ "$PURGE" -eq 1 ]]; then
    local installer
    installer=$(mktemp)
    curl -fsSL -o "$installer" https://github.com/XTLS/Xray-install/raw/main/install-release.sh || true
    if [[ -s "$installer" ]]; then
      bash "$installer" remove --purge || true
    fi
    rm -f "$installer"
    say "Xray снят вместе с конфигом. acme.sh как программа остался, сертификат домена удалён."
  else
    if [[ -d /usr/local/etc/xray ]]; then
      printf '%s\n' '{}' > /usr/local/etc/xray/config.json
      chown root:xray /usr/local/etc/xray/config.json 2>/dev/null || true
      chmod 640 /usr/local/etc/xray/config.json 2>/dev/null || true
    fi
    systemctl stop xray 2>/dev/null || true
    say "Конфиг Xray очищен, служба остановлена. Сам Xray на месте. Полное снятие: uninstall --purge"
  fi
  if command -v nginx >/dev/null 2>&1 && nginx -t; then
    systemctl reload nginx || true
  fi
  say "Сайт и сертификат selftls удалены."
}

cmd_guide() {
  cat <<EOF
Как это отличается от selfsteal

selfsteal (DigneZzZ) поднимает Caddy или nginx как приёмник Reality.
Порт 443 у Xray с Reality, а сайт живёт на внутреннем порту. Своего
сертификата у входа нет: рукопожатие Reality уходит на ваш же сайт.

selftls делает другую, более старую схему, только её:

  браузер  --TLS-->  Xray :443  --если это не VLESS-->  nginx 127.0.0.1
  клиент   --VLESS TCP TLS vision-->  Xray :443  --интернет-->

Сертификат настоящий, Let's Encrypt, на ваш домен. Транспорт один:
TCP, в актуальном ядре он называется raw. В ссылке по-прежнему type=tcp.
WebSocket, gRPC, XHTTP, Hysteria и Reality скрипт не включает.

Нужна A-запись домена на этот сервер. Порты 80 и 443 свободны.
80 нужен и для выпуска сертификата, и для редиректа на https.
Ссылку импортируют v2rayN, sing-box, Streisand, Hiddify и другие
клиенты с VLESS и flow xtls-rprx-vision.

Если нужен именно Reality и приёмник как у selfsteal, это другой
скрипт: selfsteal.sh из remnawave-scripts. Старый onekey с TCP TLS
есть у wulabing/Xray_onekey (ветка main), он шире и автор уводит
на Reality.
EOF
}

cmd_menu() {
  local answer name
  need_root
  while true; do
    say
    say "selftls"
    say "  1  установка / переустановка"
    say "  2  статус и ссылки"
    say "  3  добавить клиента"
    say "  4  удалить клиента"
    say "  5  сменить шаблон"
    say "  6  обновить сертификат"
    say "  7  логи"
    say "  8  удалить"
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
        read -r -p "Имя клиента: " name
        CLIENT_NAME=$name
        cmd_user add "$name"
        ;;
      4)
        read -r -p "Кого удалить: " name
        cmd_user rm "$name"
        ;;
      5)
        cmd_template list
        read -r -p "Шаблон (ledger|press|kiln): " name
        cmd_template use "$name"
        ;;
      6) cmd_renew ;;
      7) cmd_logs ;;
      8)
        read -r -p "Писать purge, если снять и Xray. Иначе Enter: " name
        if [[ "$name" == purge ]]; then
          PURGE=1
        fi
        cmd_uninstall
        exit 0
        ;;
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
      install|uninstall|status|link|renew|logs|template|user|menu|render|guide|update|help|-h|--help)
        COMMAND=$1
        shift
        break
        ;;
      *)
        die "неизвестная команда: $1 (selftls help)"
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
      --name)
        [[ $# -ge 2 ]] || die "--name нуждается в значении"
        CLIENT_NAME=$2
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
      --http-port)
        [[ $# -ge 2 ]] || die "--http-port нуждается в значении"
        HTTP_PORT=$2
        shift 2
        ;;
      --h2-port)
        [[ $# -ge 2 ]] || die "--h2-port нуждается в значении"
        H2_PORT=$2
        shift 2
        ;;
      --force) FORCE=1; shift ;;
      --purge) PURGE=1; shift ;;
      --no-h2) USE_H2=0; shift ;;
      --remnawave) MODE=remnawave; shift ;;
      --standalone) STANDALONE=1; MODE=standalone; shift ;;
      --port)
        [[ $# -ge 2 ]] || die "--port нуждается в значении"
        PUBLIC_PORT=$2
        PORT_FROM_FLAG=1
        shift 2
        ;;
      --panel-ip)
        [[ $# -ge 2 ]] || die "--panel-ip нуждается в значении"
        PANEL_IP=$2
        shift 2
        ;;
      --node-port)
        [[ $# -ge 2 ]] || die "--node-port нуждается в значении"
        NODE_API_PORT=$2
        shift 2
        ;;
      --ip)
        [[ $# -ge 2 ]] || die "--ip нуждается в значении"
        PUBLIC_IP=$2
        shift 2
        ;;
      --site-443)
        [[ "$SITE_443" != 0 ]] || die "нельзя одновременно --site-443 и --no-site-443"
        SITE_443=1
        SITE_443_EXPLICIT=1
        shift
        ;;
      --no-site-443)
        [[ "$SITE_443" != 1 ]] || die "нельзя одновременно --site-443 и --no-site-443"
        SITE_443=0
        SITE_443_EXPLICIT=1
        shift
        ;;
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
  if [[ -n "${SELFTLS_TEST_COMPOSE:-}" ]]; then
    insert_cert_volume "$SELFTLS_TEST_COMPOSE" "${SELFTLS_TEST_SERVICE:-}"
    return 0
  fi
  parse_args "$@"
  case "${COMMAND:-}" in
    ""|menu)
      if [[ -t 0 && "${COMMAND:-}" == menu ]]; then
        cmd_menu
      elif [[ -t 0 && -z "${COMMAND:-}" ]]; then
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
    link)
      [[ -n "$PREFIX" ]] || need_root
      cmd_link
      ;;
    renew) cmd_renew ;;
    logs) cmd_logs ;;
    uninstall) cmd_uninstall ;;
    template)
      [[ -n "$PREFIX" ]] || need_root
      cmd_template "${EXTRA[@]+"${EXTRA[@]}"}"
      ;;
    user)
      [[ -n "$PREFIX" ]] || need_root
      cmd_user "${EXTRA[@]+"${EXTRA[@]}"}"
      ;;
    *) die "команда" ;;
  esac
}

main "$@"
