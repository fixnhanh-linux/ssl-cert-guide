# Checklist SSL/TLS

Dùng cho mỗi lần cài cert mới, gia hạn thủ công, hoặc migrate server. Copy vào ticket và tick.

Tài liệu đầy đủ: [README](../README.md) · Bảng tra lỗi: [mục 11](../README.md#11-bảng-tra-lỗi-triệu-chứng--nguyên-nhân--cách-sửa)

---

## A. Trước khi làm

| # | Việc | Xong |
|---|---|---|
| A1 | Biết cert dùng cho những hostname nào (apex, www, subdomain, wildcard) | ☐ |
| A2 | Biết cert miễn phí hay trả phí, và ai chịu trách nhiệm gia hạn | ☐ |
| A3 | Có quyền truy cập DNS (cần cho DNS-01 và để kiểm tra) | ☐ |
| A4 | Có quyền root/admin trên server | ☐ |
| A5 | Biết cách quay lui (backup config trước khi sửa) | ☐ |
| A6 | Đã thông báo cho người liên quan nếu phải restart service | ☐ |

## B. DNS và mạng

| # | Việc | Lệnh | Xong |
|---|---|---|---|
| B1 | Bản ghi A/AAAA trỏ đúng IP | `dig +short @1.1.1.1 example.com` | ☐ |
| B2 | `www` cũng trỏ đúng (nếu cert có `www`) | `dig +short @1.1.1.1 www.example.com` | ☐ |
| B3 | Không còn bản ghi A thừa trỏ server khác | `dig example.com A +short` | ☐ |
| B4 | CDN đã tắt proxy trong lúc xin cert (nếu dùng HTTP-01) | bảng điều khiển DNS | ☐ |
| B5 | Cổng 80 mở từ Internet | `curl` từ máy ngoài | ☐ |
| B6 | Cổng 443 mở từ Internet | `ss -lntp \| grep 443` + `curl` ngoài | ☐ |
| B7 | Firewall cloud (Security Group) đã mở, không chỉ firewall trên máy | bảng điều khiển | ☐ |

## C. Cài đặt

| # | Việc | Xong |
|---|---|---|
| C1 | Đã thử ở **staging** trước (`--staging` với certbot) | ☐ |
| C2 | Cert có đủ mọi hostname (kiểm SAN, không chỉ CN) | ☐ |
| C3 | Web server trỏ vào `fullchain.pem`, **không** phải `cert.pem` | ☐ |
| C4 | Private key `600` hoặc `640`, chủ sở hữu `root` | ☐ |
| C5 | Không có key/cert nào nằm trong Git | ☐ |
| C6 | `nginx -t` / `httpd -t` / `apache2ctl configtest` báo OK | ☐ |
| C7 | Đã `reload` (không phải `restart`) nếu không cần downtime | ☐ |
| C8 | IIS: binding 443 có SNI đúng hostname | ☐ |
| C9 | XAMPP: cổng 443 không bị IIS/Skype/VMware chiếm | ☐ |

## D. Kiểm tra sau khi cài

| # | Việc | Lệnh | Xong |
|---|---|---|---|
| D1 | Cert đúng là cert mới | `openssl s_client ... \| openssl x509 -dates` | ☐ |
| D2 | SAN đủ hostname | `... -ext subjectAltName` | ☐ |
| D3 | Chain đủ (2 cert) | `... -showcerts \| grep -c BEGIN` → 2 | ☐ |
| D4 | Key khớp cert | so sánh pubkey hash | ☐ |
| D5 | HTTP redirect 301 sang HTTPS | `curl -sSI http://example.com` | ☐ |
| D6 | Không redirect vòng | `curl -sSIL https://example.com` | ☐ |
| D7 | Không còn mixed content | `grep -oE '(src\|href)="http://'` | ☐ |
| D8 | Test bằng `curl` (không chỉ trình duyệt) | `curl -vI https://example.com` | ☐ |
| D9 | Test bằng điện thoại Android cũ nếu có app/API | thiết bị thật | ☐ |
| D10 | SSL Labs hạng A trở lên | ssllabs.com/ssltest | ☐ |
| D11 | Toàn bộ luồng nghiệp vụ chạy được (đăng nhập, thanh toán, upload) | test tay | ☐ |

## E. Hardening

| # | Việc | Xong |
|---|---|---|
| E1 | Chỉ bật TLS 1.2 và 1.3 | ☐ |
| E2 | Không còn cipher yếu (RC4, 3DES, export) | ☐ |
| E3 | HSTS bật với `max-age=300` trước, tăng dần | ☐ |
| E4 | Đã kiểm tra **mọi** subdomain trước khi thêm `includeSubDomains` | ☐ |
| E5 | OCSP stapling bật và trả `successful` | ☐ |
| E6 | Header `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` | ☐ |

## F. Gia hạn và giám sát

| # | Việc | Lệnh | Xong |
|---|---|---|---|
| F1 | Timer/task gia hạn đang chạy | `systemctl list-timers \| grep certbot` | ☐ |
| F2 | Deploy hook reload web server | `ls /etc/letsencrypt/renewal-hooks/deploy` | ☐ |
| F3 | `certbot renew --dry-run` xanh | chạy thật | ☐ |
| F4 | Có cảnh báo khi cert < 21 ngày | script/Zabbix + test gửi mail | ☐ |
| F5 | Đã ghi ngày hết hạn vào lịch/ticket | | ☐ |
| F6 | Backup cert + key ở nơi an toàn (vault, không phải Git) | | ☐ |
| F7 | Người trực biết phải làm gì khi cert hết hạn | | ☐ |

---

## Checklist nhanh cho sự cố "cert hết hạn"

Khi đang cháy, làm đúng thứ tự này:

1. `sudo certbot renew --force-renewal` — thử ngay, 80% trường hợp xong trong 30 giây.
2. Nếu lỗi: đọc thông báo, tra [bảng lỗi](../README.md#112-lỗi-khi-cấp-cert).
3. Nếu vẫn lỗi và cần thời gian: cấp cert **self-signed** tạm để có HTTPS (người dùng thấy cảnh
   báo, nhưng dữ liệu vẫn mã hoá) — nhớ ghi ticket để thay lại.
4. Sửa nguyên nhân gốc, rồi `--dry-run` để chắc chắn lần sau tự động chạy được.
5. Viết lại: tại sao giám sát không phát hiện? Sửa ngưỡng cảnh báo.
