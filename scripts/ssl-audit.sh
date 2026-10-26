#!/usr/bin/env bash
# ============================================================================
# ssl-audit.sh — kiểm tra SSL/TLS ở chế độ CHỈ-ĐỌC
#
# Mục đích:
#   - Phát hiện web server đang chạy (nginx, Apache, Caddy, DirectAdmin).
#   - Tìm cert đang được cấu hình và kiểm tra hạn dùng, SAN, chain, key.
#   - Kiểm tra quyền file private key, protocol, HSTS, OCSP stapling.
#   - Kiểm tra cơ chế gia hạn tự động (certbot timer/cron, DA).
#
# An toàn:
#   - Không ghi file, không sửa cấu hình, không restart service.
#   - Không gửi dữ liệu ra ngoài (trừ khi dùng --host, chỉ mở kết nối TLS).
#
# Cách dùng:
#   sudo ./scripts/ssl-audit.sh
#   sudo ./scripts/ssl-audit.sh --host example.com
#
# Exit code:
#   0 — không có cảnh báo
#   1 — có cảnh báo hoặc lỗi cần xem
# ============================================================================

set -u
set -o pipefail

# Tên biến tránh trùng VERSION của /etc/os-release (file đó set VERSION=24.04...)
readonly SCRIPT_VERSION="1.0.0"

WARN_COUNT=0
BAD_COUNT=0
HOST=""

# --- Màu (chỉ khi stdout là terminal) ----------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_BAD=$'\033[31m'; C_INFO=$'\033[36m'; C_HEAD=$'\033[1m'
else
  C_RESET=""; C_OK=""; C_WARN=""; C_BAD=""; C_INFO=""; C_HEAD=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_RESET"; }
ok()      { printf '  %sOK%s   %s\n'   "$C_OK"   "$C_RESET" "$1"; }
warn()    { printf '  %sWARN%s %s\n'   "$C_WARN" "$C_RESET" "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
bad()     { printf '  %sFAIL%s %s\n'   "$C_BAD"  "$C_RESET" "$1"; BAD_COUNT=$((BAD_COUNT + 1)); }
info()    { printf '  %s--%s   %s\n'   "$C_INFO" "$C_RESET" "$1"; }
note()    { printf '        %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
ssl-audit.sh — kiểm tra SSL/TLS chỉ-đọc

  Cách dùng:
    sudo ./scripts/ssl-audit.sh                 # kiểm tra cấu hình trên máy này
    sudo ./scripts/ssl-audit.sh --host DOMAIN   # thêm kiểm tra cert đang phục vụ
    ./scripts/ssl-audit.sh --help

  Không sửa gì. Exit 1 nếu có cảnh báo.
EOF
}

# --- Tham số -----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --host)  HOST="${2:-}"; shift 2 ;;
    --host=*) HOST="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "tham số không hiểu: $1" >&2; usage; exit 2 ;;
  esac
done

printf '%sssl-audit.sh %s%s — chỉ đọc, không sửa gì\n' "$C_HEAD" "$SCRIPT_VERSION" "$C_RESET"

# ============================================================================
# 0. Môi trường
# ============================================================================
section "Môi trường"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-không rõ}"
else
  info "OS: $(uname -s) $(uname -r)"
fi
info "Hostname: $(uname -n 2>/dev/null || echo '?')"

if [ "$(id -u)" -ne 0 ]; then
  warn "không chạy bằng root — một số file cấu hình có thể không đọc được"
fi

if have openssl; then
  info "OpenSSL: $(openssl version 2>/dev/null)"
else
  bad "không có lệnh openssl — không thể kiểm tra cert"
fi

# --- Đồng hồ server: lệch giờ làm cert 'chưa hiệu lực' ----------------------
if have timedatectl; then
  sync_state=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "")
  if [ "$sync_state" = "yes" ]; then
    ok "đồng hồ đã đồng bộ NTP ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
  elif [ -n "$sync_state" ]; then
    warn "NTP chưa đồng bộ — cert có thể báo sai hạn"
  fi
fi

# ============================================================================
# 1. Phát hiện web server
# ============================================================================
section "Web server"

HAS_NGINX=0; HAS_APACHE=0; HAS_CADDY=0; HAS_DA=0
CONF_ROOTS=""

# Phát hiện theo cả binary lẫn thư mục cấu hình: có trường hợp chạy script
# trong container không có binary, hoặc audit bộ config copy từ server khác.
if have nginx; then
  HAS_NGINX=1
  info "nginx: $(nginx -v 2>&1 | sed 's/^nginx version: //')"
elif [ -d /etc/nginx ]; then
  HAS_NGINX=1
  info "nginx: có cấu hình tại /etc/nginx (không có binary trong PATH)"
fi
[ "$HAS_NGINX" -eq 1 ] && [ -d /etc/nginx ] && CONF_ROOTS="$CONF_ROOTS /etc/nginx"

if have apache2ctl; then
  HAS_APACHE=1
  info "Apache: $(apache2ctl -v 2>/dev/null | head -1)"
elif have httpd; then
  HAS_APACHE=1
  info "Apache/httpd: $(httpd -v 2>/dev/null | head -1)"
elif [ -d /etc/apache2 ] || [ -d /etc/httpd ]; then
  HAS_APACHE=1
  info "Apache: có cấu hình tại /etc/apache2 hoặc /etc/httpd (không có binary)"
fi
[ "$HAS_APACHE" -eq 1 ] && [ -d /etc/apache2 ] && CONF_ROOTS="$CONF_ROOTS /etc/apache2"
[ "$HAS_APACHE" -eq 1 ] && [ -d /etc/httpd ] && CONF_ROOTS="$CONF_ROOTS /etc/httpd"

if have caddy; then
  HAS_CADDY=1
  info "Caddy: $(caddy version 2>/dev/null | head -1)"
fi

if [ -d /usr/local/directadmin ]; then
  HAS_DA=1
  info "DirectAdmin: có ($(cat /usr/local/directadmin/custombuild/options.conf 2>/dev/null | grep -E '^(php1_release|webserver)=' | tr '\n' ' '))"
fi

if [ "$HAS_NGINX" -eq 0 ] && [ "$HAS_APACHE" -eq 0 ] && [ "$HAS_CADDY" -eq 0 ] && [ "$HAS_DA" -eq 0 ]; then
  warn "không phát hiện web server quen thuộc — chỉ kiểm tra được cert trong thư mục chuẩn"
fi

# --- Cổng đang nghe ---------------------------------------------------------
if have ss; then
  listen_80=$(ss -lntp 2>/dev/null | grep -cE ':(80)\s' || true)
  listen_443=$(ss -lntp 2>/dev/null | grep -cE ':(443)\s' || true)
  if [ "$listen_443" -gt 0 ]; then
    ok "có tiến trình nghe cổng 443"
  else
    warn "không có gì nghe cổng 443 — HTTPS chưa bật"
  fi
  if [ "$listen_80" -eq 0 ]; then
    info "không có gì nghe cổng 80 (HTTP-01 của Let's Encrypt sẽ thất bại)"
  fi
fi

# ============================================================================
# 2. Cert đang được cấu hình
# ============================================================================
section "Cert đang cấu hình"

CERT_FILES=""

collect_cert_files() {
  # nginx: ssl_certificate <path>;
  if [ "$HAS_NGINX" -eq 1 ]; then
    grep -rhoE '^[^#]*ssl_certificate[[:space:]]+[^;]+;' \
      /etc/nginx 2>/dev/null \
      | sed -E 's/.*ssl_certificate[[:space:]]+//; s/;//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -v '^ssl_' \
      || true
  fi
  # Apache: SSLCertificateFile <path>
  if [ "$HAS_APACHE" -eq 1 ]; then
    for root in /etc/apache2 /etc/httpd; do
      [ -d "$root" ] || continue
      grep -rhoE '^[^#]*SSLCertificateFile[[:space:]]+[^[:space:]]+' "$root" 2>/dev/null \
        | sed -E 's/.*SSLCertificateFile[[:space:]]+//; s/"//g' \
        || true
    done
  fi
}

if [ -n "$CONF_ROOTS" ]; then
  CERT_FILES=$(collect_cert_files | sort -u)
fi

if [ -z "$CERT_FILES" ]; then
  warn "không tìm thấy cert nào được khai báo trong cấu hình"
  note "Nếu vừa cài cert, kiểm tra lại đường dẫn trong block 443."
else
  # shellcheck disable=SC2086
  for c in $CERT_FILES; do
    if [ ! -f "$c" ]; then
      bad "khai báo nhưng không tồn tại: $c"
      continue
    fi
    if [ ! -r "$c" ]; then
      warn "không đọc được (cần root): $c"
      continue
    fi

    info "file: $c"

    # Hạn dùng
    if have openssl; then
      enddate=$(openssl x509 -in "$c" -noout -enddate 2>/dev/null | cut -d= -f2)
      if [ -z "$enddate" ]; then
        bad "  không parse được cert (file lỗi hoặc không phải PEM)"
        continue
      fi
      end_epoch=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if [ "$end_epoch" -gt 0 ]; then
        days=$(( (end_epoch - now_epoch) / 86400 ))
        if [ "$days" -lt 0 ]; then
          bad "  ĐÃ HẾT HẠN $(( -days )) ngày ($enddate)"
        elif [ "$days" -lt 14 ]; then
          bad "  còn $days ngày ($enddate) — gia hạn đang hỏng"
        elif [ "$days" -lt 30 ]; then
          warn "  còn $days ngày ($enddate) — certbot nên đã gia hạn"
        else
          ok "  còn $days ngày ($enddate)"
        fi
      fi

      subj=$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject=//')
      iss=$(openssl x509 -in "$c" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
      note "subject: $subj"
      note "issuer : $iss"

      if [ -n "$subj" ] && [ "$subj" = "$iss" ]; then
        bad "  self-signed (subject = issuer) — trình duyệt sẽ cảnh báo"
      fi

      sans=$(openssl x509 -in "$c" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')
      if [ -n "$sans" ]; then
        note "SAN    : $sans"
      else
        warn "  không có subjectAltName — trình duyệt hiện đại sẽ từ chối"
      fi

      # Số cert trong file = chain
      ncert=$(grep -c 'BEGIN CERTIFICATE' "$c" 2>/dev/null || true)
      if [ "${ncert:-0}" -ge 2 ]; then
        ok "  chain: $ncert cert (leaf + intermediate)"
      elif [ "${ncert:-0}" -eq 1 ]; then
        warn "  chain: chỉ có 1 cert — THIẾU intermediate"
        note "Android/Java/curl sẽ báo lỗi. Ghép: cat cert.pem chain.pem > fullchain.pem"
      fi
    fi
  done
fi

# ============================================================================
# 3. Private key: quyền và khớp cert
# ============================================================================
section "Private key"

KEY_FILES=""
if [ "$HAS_NGINX" -eq 1 ] && [ -d /etc/nginx ]; then
  KEY_FILES=$(grep -rhoE '^[^#]*ssl_certificate_key[[:space:]]+[^;]+;' /etc/nginx 2>/dev/null \
    | sed -E 's/.*ssl_certificate_key[[:space:]]+//; s/;//; s/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true)
fi
if [ "$HAS_APACHE" -eq 1 ]; then
  for root in /etc/apache2 /etc/httpd; do
    [ -d "$root" ] || continue
    KEY_FILES="$KEY_FILES
$(grep -rhoE '^[^#]*SSLCertificateKeyFile[[:space:]]+[^[:space:]]+' "$root" 2>/dev/null \
      | sed -E 's/.*SSLCertificateKeyFile[[:space:]]+//; s/"//g' | sort -u || true)"
  done
fi
KEY_FILES=$(printf '%s\n' "$KEY_FILES" | sed '/^$/d' | sort -u)

if [ -z "$KEY_FILES" ]; then
  info "không tìm thấy khai báo SSLCertificateKeyFile/ssl_certificate_key"
else
  # shellcheck disable=SC2086
  for k in $KEY_FILES; do
    if [ ! -e "$k" ]; then
      bad "key được khai báo nhưng không tồn tại: $k"
      continue
    fi
    info "file: $k"

    # Quyền: owner phải đọc được; group chỉ được đọc (4); other phải = 0.
    if have stat; then
      perm=$(stat -c '%a %U:%G' "$k" 2>/dev/null || echo "000 ?:?")
      mode=${perm%% *}
      case "$mode" in
        ''|*[!0-9]*) info "  không đọc được quyền của $k" ;;
        *)
          p_user=$(( mode / 100 ))
          p_group=$(( (mode / 10) % 10 ))
          p_other=$(( mode % 10 ))
          if [ "$p_other" -ne 0 ]; then
            bad "  quyền $perm — 'other' vẫn đọc được key, phải chmod 600 hoặc 640"
          elif [ "$p_group" -gt 4 ]; then
            bad "  quyền $perm — 'group' có quyền ghi/thực thi, phải chmod 600 hoặc 640"
          elif [ "$p_user" -lt 4 ]; then
            bad "  quyền $perm — chủ sở hữu không đọc được key (server sẽ không khởi động)"
          elif [ "$p_group" -eq 4 ]; then
            ok "  quyền $perm (group được đọc — chỉ chấp nhận nếu group là user của web server)"
          else
            ok "  quyền $perm"
          fi
          ;;
      esac
    fi

    # Khớp với cert cùng thư mục
    dir=$(dirname "$k")
    cand=$(ls "$dir"/*.pem "$dir"/*.crt 2>/dev/null | head -1 || true)
    if [ -n "$cand" ] && have openssl; then
      h1=$(openssl x509 -in "$cand" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
      h2=$(openssl pkey -in "$k" -pubout -outform der 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')
      if [ -n "$h1" ] && [ -n "$h2" ]; then
        if [ "$h1" = "$h2" ]; then
          ok "  key khớp cert ($(basename "$cand"))"
        else
          bad "  key KHÔNG khớp cert ($(basename "$cand"))"
        fi
      fi
    fi
  done
fi

# ============================================================================
# 4. Cấu hình TLS
# ============================================================================
section "Cấu hình TLS"

if [ "$HAS_NGINX" -eq 1 ] && [ -d /etc/nginx ]; then
  if grep -rqsE 'ssl_protocols.*TLSv1(\.1)?[^.]' /etc/nginx; then
    bad "nginx: còn bật TLS 1.0/1.1 trong ssl_protocols"
  elif grep -rqs 'ssl_protocols' /etc/nginx; then
    ok "nginx: ssl_protocols đã khai báo (kiểm tra không còn TLSv1/TLSv1.1)"
  else
    warn "nginx: không thấy ssl_protocols — đang dùng mặc định của bản nginx"
  fi

  if grep -rqs 'ssl_stapling[[:space:]]\+on' /etc/nginx; then
    ok "nginx: OCSP stapling bật"
  else
    warn "nginx: OCSP stapling chưa bật"
  fi

  if grep -rqs 'Strict-Transport-Security' /etc/nginx; then
    hsts=$(grep -rhs 'Strict-Transport-Security' /etc/nginx | head -1 | sed 's/^[[:space:]]*//')
    ok "nginx: có HSTS"
    note "$hsts"
    if printf '%s' "$hsts" | grep -q 'includeSubDomains'; then
      warn "  HSTS có includeSubDomains — chỉ đúng nếu MỌI subdomain đã có HTTPS"
    fi
  else
    warn "nginx: chưa có HSTS (thiếu để lên A+)"
  fi
fi

if [ "$HAS_NGINX" -eq 0 ] && [ "$HAS_APACHE" -eq 0 ]; then
  info "không có cấu hình nginx/Apache để kiểm tra protocol, HSTS, OCSP"
fi

if [ "$HAS_APACHE" -eq 1 ]; then
  found_proto=0
  for root in /etc/apache2 /etc/httpd; do
    [ -d "$root" ] || continue
    if grep -rqs 'SSLProtocol' "$root"; then
      found_proto=1
      line=$(grep -rhs '^[[:space:]]*SSLProtocol' "$root" | head -1 | sed 's/^[[:space:]]*//')
      note "$line"
      if printf '%s' "$line" | grep -qE '\-TLSv1[[:space:]]|\-TLSv1\.1[[:space:]]|\-TLSv1$|\-TLSv1\.1$'; then
        ok "Apache: đã tắt TLS 1.0/1.1"
      else
        warn "Apache: SSLProtocol chưa loại bỏ TLS 1.0/1.1"
      fi
    fi
  done
  [ "$found_proto" -eq 0 ] && warn "Apache: không thấy SSLProtocol — có thể đang bật TLS 1.0"

  if grep -rqs 'SSLUseStapling[[:space:]]\+on' /etc/apache2 /etc/httpd 2>/dev/null; then
    ok "Apache: OCSP stapling bật"
  else
    warn "Apache: OCSP stapling chưa bật"
  fi

  if grep -rqs 'Strict-Transport-Security' /etc/apache2 /etc/httpd 2>/dev/null; then
    ok "Apache: có HSTS"
  else
    warn "Apache: chưa có HSTS"
  fi

  # Cảnh báo SSLCertificateChainFile (deprecated từ 2.4.8)
  if grep -rqs 'SSLCertificateChainFile' /etc/apache2 /etc/httpd 2>/dev/null; then
    warn "Apache: đang dùng SSLCertificateChainFile (deprecated từ 2.4.8)"
    note "Ghép chain vào SSLCertificateFile, bỏ directive cũ để tránh gửi trùng."
  fi
fi

# ============================================================================
# 5. Gia hạn tự động
# ============================================================================
section "Gia hạn tự động"

RENEW_FOUND=0

if have systemctl; then
  if systemctl list-timers --all 2>/dev/null | grep -q 'certbot'; then
    RENEW_FOUND=1
    ok "có systemd timer cho certbot"
    systemctl list-timers --all 2>/dev/null | grep 'certbot' | sed 's/^/        /' | head -2
  fi
fi

if [ -d /etc/cron.d ] || [ -d /var/spool/cron ]; then
  if grep -rqs 'certbot' /etc/cron.d /etc/cron.daily /etc/cron.weekly /var/spool/cron/crontabs 2>/dev/null; then
    RENEW_FOUND=1
    ok "có cron chạy certbot"
  fi
fi

if [ "$HAS_DA" -eq 1 ]; then
  RENEW_FOUND=1
  info "DirectAdmin: DA tự gia hạn Let's Encrypt, không cần cron riêng"
fi

if [ "$RENEW_FOUND" -eq 0 ]; then
  warn "không tìm thấy cơ chế gia hạn tự động nào"
  note "Cert 90 ngày. Thiếu gia hạn = sự cố hẹn giờ."
fi

if have certbot; then
  info "certbot: $(certbot --version 2>&1 | head -1)"
  if [ -d /etc/letsencrypt/renewal-hooks/deploy ]; then
    hooks=$(ls /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null | wc -l)
    if [ "$hooks" -gt 0 ]; then
      ok "có deploy hook ($hooks file) — sẽ reload sau khi gia hạn"
    else
      warn "deploy-hooks rỗng — cert gia hạn xong nhưng server có thể không reload"
    fi
  else
    warn "không có /etc/letsencrypt/renewal-hooks/deploy — chưa chắc reload sau gia hạn"
  fi
fi

# ============================================================================
# 6. Kiểm tra host từ ngoài (tuỳ chọn)
# ============================================================================
if [ -n "$HOST" ]; then
  section "Cert đang phục vụ: $HOST"
  if ! have openssl; then
    bad "không có openssl"
  else
    # -showcerts là BẮT BUỘC: không có nó, s_client chỉ in PEM của leaf,
    # nên đếm chain sẽ luôn ra 1 và báo thiếu intermediate sai.
    out=$(openssl s_client -connect "${HOST}:443" -servername "$HOST" -showcerts </dev/null 2>/dev/null || true)
    if [ -z "$out" ]; then
      bad "không kết nối được tới ${HOST}:443"
    else
      enddate=$(printf '%s' "$out" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [ -n "$enddate" ]; then
        end_epoch=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
        days=$(( (end_epoch - $(date +%s)) / 86400 ))
        if [ "$days" -lt 0 ]; then
          bad "cert đã hết hạn $(( -days )) ngày"
        elif [ "$days" -lt 20 ]; then
          warn "cert còn $days ngày — gia hạn có vấn đề"
        else
          ok "cert còn $days ngày ($enddate)"
        fi
      fi

      nchain=$(printf '%s' "$out" | grep -c 'BEGIN CERTIFICATE' || true)
      if [ "${nchain:-0}" -ge 2 ]; then
        ok "server gửi $nchain cert (chain đủ)"
        if [ "${nchain:-0}" -gt 3 ]; then
          info "  chain dài bất thường — có thể có cross-sign hoặc root bị nhét vào"
        fi
      elif [ "${nchain:-0}" -eq 1 ]; then
        bad "server chỉ gửi 1 cert — THIẾU intermediate"
        note "Android/Java/curl sẽ báo 'unable to get local issuer certificate'."
      else
        bad "không nhận được cert nào từ ${HOST}:443"
      fi

      proto=$(printf '%s' "$out" | grep -oE '^(TLSv[0-9.]+|SSLv[0-9.]+)' | head -1)
      [ -n "$proto" ] && info "giao thức: $proto"

      printf '%s' "$out" | openssl x509 -noout -subject -issuer 2>/dev/null \
        | sed 's/^/        /'
    fi
  fi
fi

# ============================================================================
# Tổng kết
# ============================================================================
section "Tổng kết"
if [ "$BAD_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  ok "không có vấn đề nào"
  exit 0
fi
printf '  %d lỗi, %d cảnh báo\n' "$BAD_COUNT" "$WARN_COUNT"
printf '  Xem README mục 11 (bảng tra lỗi) để biết cách sửa.\n'
exit 1
