# SSL/TLS — one-page cheat sheet (EN)

Vietnamese playbook: [README](../README.md) · Error table: [§11](../README.md#11-bảng-tra-lỗi-triệu-chứng--nguyên-nhân--cách-sửa)

---

## Get a certificate (Let's Encrypt)

```bash
# Staging first — never burn rate limits on production
sudo certbot certonly --staging --webroot -w /var/www/example.com/public \
  -d example.com -d www.example.com

# Then for real
sudo certbot certonly --webroot -w /var/www/example.com/public \
  -d example.com -d www.example.com

# Wildcard (DNS-01 only)
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d example.com -d '*.example.com'
```

Output: `/etc/letsencrypt/live/<domain>/{fullchain,privkey,chain}.pem`

## Where the files go

| Server | Config file | Certificate directives |
|---|---|---|
| nginx | `/etc/nginx/sites-available/<d>` | `ssl_certificate` → `fullchain.pem`, `ssl_certificate_key` → `privkey.pem` |
| Apache 2.4.8+ | `/etc/apache2/sites-available/<d>.conf` | `SSLCertificateFile` → **fullchain**, `SSLCertificateKeyFile` → privkey |
| Apache < 2.4.8 | same | `+ SSLCertificateChainFile` → chain |
| IIS | IIS Manager → Bindings | import **.pfx** into `Local Computer\Personal` |
| XAMPP | `conf/extra/httpd-ssl.conf` | `SSLCertificateFile` / `SSLCertificateKeyFile`, use `/` in paths |
| DirectAdmin | Domain Setup → SSL Certificates | tick "Use Let's Encrypt" |

## Apply

```bash
sudo nginx -t              && sudo systemctl reload nginx
sudo apache2ctl configtest && sudo systemctl reload apache2
sudo httpd -t              && sudo systemctl reload httpd
```

```cmd
C:\xampp\apache\bin\httpd.exe -t
C:\xampp\apache\bin\httpd.exe -k restart
```

## Verify (run from another machine)

```bash
# What is being served
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# Chain length: must be 2 (leaf + intermediate)
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null 2>/dev/null \
  | grep -c 'BEGIN CERTIFICATE'

# Key matches cert? two hashes must be identical
openssl x509 -in fullchain.pem -noout -pubkey | openssl pkey -pubin -outform der | openssl sha256
openssl pkey -in privkey.pem -pubout -outform der | openssl sha256

# Redirect + mixed content
curl -sSI http://example.com | head -3
curl -sS https://example.com/ | grep -oE '(src|href)="http://[^"]+' | sort -u
```

## Renew

```bash
sudo certbot renew --dry-run          # the single most useful command
sudo certbot renew --deploy-hook "systemctl reload nginx"
systemctl list-timers | grep certbot
```

IIS: `wacs.exe` creates a Scheduled Task. XAMPP: no auto-renew, do it yourself.

## Hardening (nginx)

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
add_header Strict-Transport-Security "max-age=300" always;   # raise gradually
```

## Error → cause → fix (top 8)

| Symptom | Cause | Fix |
|---|---|---|
| `ERR_CERT_COMMON_NAME_INVALID` | SAN missing hostname (usually `www`) | reissue with all names |
| `ERR_CERT_AUTHORITY_INVALID` | missing intermediate | `cat cert chain > fullchain` |
| Works on desktop, fails on Android | missing intermediate (Chrome AIA-fetches, Android doesn't) | same as above |
| `ERR_CERT_DATE_INVALID` | expired **or** clock skew | check `date -u`, renew |
| `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` | old Windows Server, no TLS 1.2 | IIS Crypto → enable TLS 1.2 |
| `Invalid response ... 404` | wrong webroot / rewrite blocks `.well-known` | fix webroot, whitelist path |
| Cloudflare 526 | invalid cert on origin | valid cert on origin, or Origin CA |
| Redirect loop | Cloudflare SSL mode Flexible | switch to Full (strict) |

## Gotchas worth remembering

1. **Apache 2.4.8+**: put the chain in `SSLCertificateFile`. `SSLCertificateChainFile` is deprecated.
2. **fullchain order**: leaf first, intermediate second, root **never**.
3. **`certonly`** doesn't reload the server — add a deploy hook.
4. **`live/`** is a symlink; always point configs there, never at `archive/`.
5. **Wildcard ≠ all subdomains** — only one level, and not the apex.
6. **5 duplicate certs/week** on Let's Encrypt. Use staging while debugging.
7. **HSTS is sticky** — the browser remembers after you remove the header.
8. **Windows**: "Apache won't start" is almost always port 443 taken → `netstat -ano | findstr :443`.
