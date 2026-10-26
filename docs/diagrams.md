# Sơ đồ: SSL/TLS từ xin cert đến gia hạn

Bộ sơ đồ cho playbook [Cài SSL/TLS](../README.md). Tất cả vẽ bằng **Mermaid** — GitHub render
thành hình ngay trong trang, không cần cài gì. Muốn sửa thì sửa text, không phải sửa ảnh.

> [!TIP]
> Hai sơ đồ quan trọng nhất có thêm **bản động SVG** (mũi tên chảy, gói tin di chuyển):
> [chain-of-trust.svg](img/chain-of-trust.svg) · [acme-flow.svg](img/acme-flow.svg).
> Sinh lại bằng `python3 tools/gen_diagrams.py` — sửa script, đừng sửa tay `.svg`.

| # | Sơ đồ | Trả lời câu hỏi |
|---|---|---|
| 1 | [Chain of trust](#1-chain-of-trust) | Vì sao thiếu intermediate lại lỗi? |
| 2 | [ACME HTTP-01](#2-acme-http-01) | Certbot làm gì khi xác thực qua cổng 80? |
| 3 | [ACME DNS-01](#3-acme-dns-01) | Wildcard hoạt động thế nào? |
| 4 | [File nào đi vào đâu](#4-file-nào-đi-vào-đâu) | `fullchain` hay `cert`, `pfx` hay `pem`? |
| 5 | [Chọn cách xác thực](#5-chọn-cách-xác-thực) | HTTP-01, DNS-01 hay TLS-ALPN? |
| 6 | [TLS handshake](#6-tls-handshake) | SNI, cert, key exchange xảy ra lúc nào? |
| 7 | [Vòng đời 90 ngày](#7-vòng-đời-90-ngày) | Khi nào certbot thật sự gia hạn? |
| 8 | [Redirect và mixed content](#8-redirect-và-mixed-content) | Ổ khoá xanh nhưng vẫn "not secure"? |
| 9 | [Chẩn đoán sự cố](#9-chẩn-đoán-sự-cố) | Cert lỗi thì kiểm tra theo thứ tự nào? |
| 10 | [Bản đồ nền tảng](#10-bản-đồ-nền-tảng) | Cùng một cert, mỗi server cần gì? |

---

## 1. Chain of trust

```mermaid
flowchart LR
    B["Trình duyệt<br/>trust store của HĐH"]:::client
    L["Leaf cert<br/>example.com"]:::leaf
    I["Intermediate<br/>R11 / YE2"]:::inter
    R["Root CA<br/>ISRG Root X1"]:::root

    B -- "① gửi ClientHello + SNI" --> S["Web server"]:::web
    S -- "② gửi leaf + intermediate" --> B
    B -. "③ tự tìm root trong trust store" .-> R
    R -. "④ ký intermediate" .-> I
    I -. "⑤ ký leaf" .-> L
    L --> S

    subgraph loi["Khi thiếu intermediate"]
        L2["Leaf only"]:::bad --> B2["Chrome desktop:<br/>tự tải intermediate (AIA)<br/>→ vẫn xanh"]:::ok
        L2 --> B3["Android / Java / curl:<br/>không tải bù<br/>→ LỖI"]:::bad
    end

    classDef client fill:#FFF7ED,stroke:#F59E0B,color:#7C2D12
    classDef web fill:#EFF6FF,stroke:#3B82F6,color:#1E3A8A
    classDef leaf fill:#F5F3FF,stroke:#8B5CF6,color:#4C1D95
    classDef inter fill:#ECFDF5,stroke:#10B981,color:#064E3B
    classDef root fill:#F8FAFC,stroke:#94A3B8,color:#0F172A
    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef bad fill:#FEF2F2,stroke:#EF4444,color:#7F1D1D
```

**Điều cần nhớ:** máy bạn test bằng Chrome **không đại diện** cho client thật. Luôn đếm chain bằng
`openssl s_client -showcerts | grep -c 'BEGIN CERTIFICATE'` — phải bằng 2.

---

## 2. ACME HTTP-01

```mermaid
sequenceDiagram
    autonumber
    participant C as certbot (client)
    participant W as Web server (:80)
    participant CA as Let's Encrypt (ACME)

    C->>CA: Đăng ký account + tạo order cho example.com
    CA-->>C: Trả về token + challenge HTTP-01
    C->>C: Ghi token vào<br/>.well-known/acme-challenge/token
    C->>CA: "Đã sẵn sàng, mời kiểm tra"
    CA->>W: GET http://example.com/.well-known/acme-challenge/token
    W-->>CA: 200 + nội dung token
    CA->>CA: So khớp token
    CA-->>C: 200 OK — xác thực thành công
    C->>CA: Gửi CSR
    CA-->>C: Trả cert (fullchain + chain)
    C->>C: Lưu vào /etc/letsencrypt/live/example.com/
    Note over C,W: certbot KHÔNG tự reload server<br/>trừ khi dùng --nginx / --apache / deploy hook
```

**Ba điều kiện để bước 6 thành công:** DNS đúng, cổng 80 mở, và không có gì chặn
`/.well-known/` (rewrite, `.htaccess`, WAF, Cloudflare proxy).

---

## 3. ACME DNS-01

```mermaid
sequenceDiagram
    autonumber
    participant C as certbot
    participant API as DNS API (Cloudflare...)
    participant DNS as Hệ thống DNS
    participant CA as Let's Encrypt

    C->>CA: Tạo order cho *.example.com
    CA-->>C: Trả về token DNS-01
    C->>API: Tạo TXT _acme-challenge.example.com = hash(token)
    API-->>DNS: Ghi bản ghi, lan truyền (có thể 30-120s)
    C->>C: Chờ TXT xuất hiện ở resolver công cộng
    C->>CA: "Đã sẵn sàng"
    CA->>DNS: Truy vấn TXT _acme-challenge.example.com
    DNS-->>CA: Giá trị hash
    CA-->>C: Xác thực thành công → trả cert
    C->>API: Xoá bản ghi TXT tạm
```

**Vì sao cần cách này:** cổng 80 có thể đóng, server có thể không có IP công cộng, và **chỉ DNS-01
cấp được wildcard**.

---

## 4. File nào đi vào đâu

```mermaid
flowchart TD
    CA["CA gửi về"]:::neutral

    CA --> PEM["cert.pem<br/>chain.pem<br/>privkey.pem"]:::ok
    CA --> PFX[".pfx / .p12<br/>có mật khẩu"]:::cache
    CA --> P7B[".p7b<br/>chỉ cert + chain"]:::neutral

    PEM --> FC["fullchain.pem<br/>= cat cert.pem chain.pem"]:::ok

    FC --> NG["nginx<br/>ssl_certificate"]:::web
    FC --> AP["Apache 2.4.8+<br/>SSLCertificateFile"]:::web
    FC --> XA["XAMPP<br/>SSLCertificateFile"]:::web
    PEM --> DA["DirectAdmin<br/>dán vào 3 ô"]:::web

    PFX --> IIS["IIS<br/>import vào Local Computer\Personal"]:::web
    PFX --> WIN["WinRM / Java keystore"]:::neutral
    P7B --> IIS

    classDef web fill:#EFF6FF,stroke:#3B82F6,color:#1E3A8A
    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef cache fill:#FEFCE8,stroke:#EAB308,color:#713F12
    classDef neutral fill:#F8FAFC,stroke:#94A3B8,color:#0F172A
```

Quy tắc một dòng: **web server nhận `fullchain` + `privkey`; Windows nhận `.pfx`.**

---

## 5. Chọn cách xác thực

```mermaid
flowchart TD
    S["Cần cấp cert"]:::start
    S --> Q1{"Có wildcard<br/>hoặc subdomain<br/>nhiều cấp?"}:::q

    Q1 -- Có --> DNS["DNS-01<br/>bắt buộc"]:::dns
    Q1 -- Không --> Q2{"Cổng 80<br/>mở từ Internet?"}:::q

    Q2 -- Có --> Q3{"Có CDN/proxy<br/>che phía trước?"}:::q
    Q2 -- Không --> Q4{"Có quyền API<br/>của DNS?"}:::q

    Q3 -- Không --> HTTP["HTTP-01<br/>đơn giản nhất"]:::http
    Q3 -- Có --> DNS
    Q4 -- Có --> DNS
    Q4 -- Không --> ALPN["TLS-ALPN-01<br/>hoặc nhờ hỗ trợ mở cổng 80"]:::warn

    classDef start fill:#F5F3FF,stroke:#8B5CF6,color:#4C1D95
    classDef q fill:#FFFFFF,stroke:#94A3B8,color:#0F172A
    classDef dns fill:#ECFDF5,stroke:#10B981,color:#064E3B
    classDef http fill:#EFF6FF,stroke:#3B82F6,color:#1E3A8A
    classDef warn fill:#FFF7ED,stroke:#F59E0B,color:#7C2D12
```

---

## 6. TLS handshake

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant S as Server

    C->>S: ClientHello<br/>TLS 1.3 + cipher list + SNI=example.com
    S-->>C: ServerHello + cert chain + key share
    C->>C: Kiểm tra: hạn dùng, SAN, chain, chữ ký
    C->>C: Có tin root trong trust store?
    alt Tin cậy
        C->>S: Finished
        S-->>C: Finished — kênh mã hoá
        Note over C,S: Từ đây HTTP đi trong TLS
    else Không tin cậy
        C-->>S: Alert: unknown CA / bad certificate
        Note over C: ERR_CERT_AUTHORITY_INVALID
    end
```

`SNI` là lý do một IP có thể phục vụ nhiều cert. Nếu client không gửi SNI (hoặc gửi sai hostname),
server trả cert mặc định — và trình duyệt báo `COMMON_NAME_INVALID` dù cert hoàn toàn hợp lệ.

---

## 7. Vòng đời 90 ngày

```mermaid
flowchart LR
    D0["Ngày 0<br/>cert cấp mới"]:::ok
    D30["Ngày 30<br/>certbot bắt đầu thử gia hạn"]:::cache
    D60["Ngày 60<br/>vẫn thử, vẫn thành công"]:::cache
    D70["Ngày 70<br/>cảnh báo của ta: còn 20 ngày"]:::warn
    D90["Ngày 90<br/>HẾT HẠN"]:::bad

    D0 --> D30 --> D60 --> D70 --> D90

    D30 -. "gia hạn OK" .-> D0
    D60 -. "gia hạn OK" .-> D0

    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef cache fill:#FEFCE8,stroke:#EAB308,color:#713F12
    classDef warn fill:#FFF7ED,stroke:#F59E0B,color:#7C2D12
    classDef bad fill:#FEF2F2,stroke:#EF4444,color:#7F1D1D
```

**Đọc sơ đồ này đúng cách:** certbot thử gia hạn từ ngày 30, không phải ngày 89. Nếu tới ngày 70 mà
cert vẫn chưa đổi, nghĩa là **đã thất bại 40 ngày** — đó là lúc cảnh báo phải nổ, không phải lúc
cert hết hạn.

---

## 8. Redirect và mixed content

```mermaid
flowchart TD
    U["Người dùng gõ<br/>example.com"]:::client
    U --> H["HTTP :80"]:::warn

    H --> R{"Có rule<br/>redirect?"}:::q
    R -- "301" --> T["HTTPS :443<br/>cert + chain"]:::ok
    R -- "Không" --> P["Phục vụ HTTP<br/>KHÔNG mã hoá"]:::bad

    T --> M{"HTML có tài nguyên<br/>http:// ?"}:::q
    M -- "Không" --> GOOD["Ổ khoá xanh<br/>hoàn toàn an toàn"]:::ok
    M -- "Có" --> MIX["Mixed content<br/>script bị chặn<br/>ổ khoá có cảnh báo"]:::bad

    MIX --> FIX["Sửa URL tuyệt đối<br/>trong HTML/CSS/DB"]:::cache
    FIX --> GOOD

    classDef client fill:#FFF7ED,stroke:#F59E0B,color:#7C2D12
    classDef warn fill:#FFF7ED,stroke:#F59E0B,color:#7C2D12
    classDef q fill:#FFFFFF,stroke:#94A3B8,color:#0F172A
    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef bad fill:#FEF2F2,stroke:#EF4444,color:#7F1D1D
    classDef cache fill:#FEFCE8,stroke:#EAB308,color:#713F12
```

---

## 9. Chẩn đoán sự cố

```mermaid
flowchart TD
    E["Trình duyệt báo lỗi cert"]:::bad
    E --> Q1{"Lỗi gì?"}:::q

    Q1 -- "COMMON_NAME_INVALID" --> A1["Kiểm SAN<br/>thiếu www?"]:::act
    Q1 -- "AUTHORITY_INVALID" --> A2["Đếm chain<br/>= 1 → thiếu intermediate"]:::act
    Q1 -- "DATE_INVALID" --> A3["date -u trên server<br/>và trên client"]:::act
    Q1 -- "PROTOCOL_ERROR" --> A4["ss -lntp :443<br/>có đúng TLS không?"]:::act
    Q1 -- "TOO_MANY_REDIRECTS" --> A5["curl -sSIL<br/>xem chuỗi redirect"]:::act

    A1 --> F1["Cấp lại cert đủ tên"]:::ok
    A2 --> F2["cat cert chain > fullchain<br/>reload"]:::ok
    A3 --> F3["Đồng bộ NTP<br/>hoặc gia hạn"]:::ok
    A4 --> F4["Sửa Listen / port<br/>kiểm tra service"]:::ok
    A5 --> F5["Sửa rule ở đúng một tầng"]:::ok

    F1 --> V["Kiểm lại bằng openssl s_client<br/>từ máy KHÁC"]:::cache
    F2 --> V
    F3 --> V
    F4 --> V
    F5 --> V

    classDef bad fill:#FEF2F2,stroke:#EF4444,color:#7F1D1D
    classDef q fill:#FFFFFF,stroke:#94A3B8,color:#0F172A
    classDef act fill:#EFF6FF,stroke:#3B82F6,color:#1E3A8A
    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef cache fill:#FEFCE8,stroke:#EAB308,color:#713F12
```

---

## 10. Bản đồ nền tảng

```mermaid
flowchart LR
    CERT["fullchain.pem<br/>privkey.pem"]:::ok

    CERT --> NG["nginx<br/>/etc/nginx/sites-available/"]:::web
    CERT --> AP["Apache<br/>/etc/apache2 hoặc /etc/httpd"]:::web
    CERT --> XA["XAMPP<br/>conf/extra/httpd-ssl.conf"]:::web
    CERT --> DA["DirectAdmin<br/>UI → SSL Certificates"]:::web
    CERT --> PFX[".pfx"]:::cache
    PFX --> IIS["IIS<br/>Bindings → 443"]:::web

    NG --> R1["reload nginx"]:::act
    AP --> R2["reload apache2/httpd"]:::act
    XA --> R3["httpd -k restart"]:::act
    DA --> R4["DA tự reload"]:::act
    IIS --> R5["binding tự áp, cache có thể cần reset"]:::act

    classDef web fill:#EFF6FF,stroke:#3B82F6,color:#1E3A8A
    classDef ok fill:#F0FDF4,stroke:#22C55E,color:#14532D
    classDef cache fill:#FEFCE8,stroke:#EAB308,color:#713F12
    classDef act fill:#ECFEFF,stroke:#0891B2,color:#164E63
```

---

## Bản ASCII (đọc offline, không cần Mermaid)

### Chain of trust

```text
  Trình duyệt                Web server                 CA
  ───────────                ──────────                 ──
  ClientHello  ──────────────▶
  (SNI=example.com)
                              ◀──── leaf + intermediate
  kiểm tra hạn/SAN/chain
  tìm root trong trust store
        │
        └── root (ISRG Root X1) ký ──▶ intermediate (R11) ký ──▶ leaf

  Thiếu intermediate:
    Chrome desktop → tự tải bù (AIA)  → vẫn xanh
    Android/Java   → không tải bù     → LỖI
```

### Chọn cách xác thực

```text
  wildcard / subdomain 2 cấp? ── có ──▶ DNS-01
           │ không
           ▼
  cổng 80 mở? ── không ──▶ có quyền API DNS? ── có ──▶ DNS-01
           │ có                              └ không ─▶ TLS-ALPN-01
           ▼
  sau CDN/proxy? ── có ──▶ DNS-01
           │ không
           ▼
       HTTP-01
```

### Một cert đi vào đâu

```text
  CA ──▶ cert.pem ─┐
        chain.pem ─┴──▶ fullchain.pem ──┬──▶ nginx:    ssl_certificate
                                        ├──▶ Apache:   SSLCertificateFile
                                        ├──▶ XAMPP:    SSLCertificateFile
                                        └──▶ DA:       dán 3 ô trong UI

  CA ──▶ cert.key ─────────────────────────▶ privkey.pem (chmod 600)

  CA ──▶ .pfx ──▶ IIS: import Local Computer\Personal ──▶ Binding 443
```
