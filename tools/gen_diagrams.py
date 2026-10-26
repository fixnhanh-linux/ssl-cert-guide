#!/usr/bin/env python3
"""Sinh hai sơ đồ SVG động cho repo ssl-cert-guide.

Vì sao có script này
--------------------
GitHub render Mermaid thành ảnh tĩnh và xoá thẻ <script> trong markdown. Muốn
"mũi tên di chuyển" thì phải là file SVG có CSS @keyframes và SMIL animateMotion
— trình duyệt chạy animation ngay cả khi SVG được nhúng qua <img>.

Sửa sơ đồ bằng cách sửa toạ độ/nội dung trong file này rồi chạy lại, đừng sửa
tay file .svg (lần chạy sau sẽ ghi đè).

Cách dùng
---------
    python3 tools/gen_diagrams.py            # ghi lại file vào docs/img/
    python3 tools/gen_diagrams.py --check    # chỉ kiểm tra, exit 1 nếu lệch
    python3 tools/gen_diagrams.py --out DIR  # ghi ra thư mục khác

Script chỉ ghi vào thư mục đích, không sửa gì khác. Không cần thư viện ngoài.
"""
import argparse
import os
import sys
import xml.dom.minidom
from html import escape

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_OUT = os.path.join(REPO, "docs", "img")

OUT = DEFAULT_OUT
_PENDING = {}

FONT = '"Segoe UI","Helvetica Neue",Arial,"Noto Sans",sans-serif'
MONO = '"SFMono-Regular",Consolas,"Liberation Mono",Menlo,monospace'

# Màu theo vai trò — giữ đồng bộ với các repo khác của cùng bộ tài liệu.
PALETTE = {
    "client":  ("#FFF7ED", "#F59E0B", "#7C2D12"),
    "web":     ("#EFF6FF", "#3B82F6", "#1E3A8A"),
    "php":     ("#F5F3FF", "#8B5CF6", "#4C1D95"),
    "data":    ("#ECFDF5", "#10B981", "#064E3B"),
    "cache":   ("#FEFCE8", "#EAB308", "#713F12"),
    "danger":  ("#FEF2F2", "#EF4444", "#7F1D1D"),
    "ok":      ("#F0FDF4", "#22C55E", "#14532D"),
    "neutral": ("#F8FAFC", "#94A3B8", "#0F172A"),
    "cmd":     ("#ECFEFF", "#0891B2", "#164E63"),
}

ARROW_COLORS = {
    "client": "#F59E0B",
    "web": "#3B82F6",
    "php": "#8B5CF6",
    "data": "#10B981",
    "cache": "#EAB308",
    "danger": "#EF4444",
    "ok": "#22C55E",
    "neutral": "#94A3B8",
    "cmd": "#0891B2",
}


def emit(name, parts):
    """Gom nội dung một sơ đồ lại; main() quyết định ghi hay chỉ so sánh."""
    body = "\n".join(parts)
    if not body.rstrip().endswith("</svg>"):
        body = body.rstrip() + "\n</svg>"
    _PENDING[name] = body


def defs():
    marks = "".join(
        f'<marker id="ar-{k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        f'markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" '
        f'fill="{v}"/></marker>\n'
        for k, v in ARROW_COLORS.items()
    )
    return f"""  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#f3f7fc"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="2" stdDeviation="3.5" flood-color="#0f172a" flood-opacity="0.10"/>
    </filter>
    <filter id="glow" x="-90%" y="-90%" width="280%" height="280%">
      <feGaussianBlur stdDeviation="3" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
{marks}  </defs>
"""


STYLE = """
  <style>
    text { font-family: %(font)s; }
    .title { font-size: 22px; font-weight: 700; fill: #0b1220; }
    .sub   { font-size: 13.5px; fill: #64748b; }
    .n     { font-size: 16px; font-weight: 650; }
    .s     { font-size: 12.5px; fill: #64748b; }
    .mono  { font-family: %(mono)s; font-size: 12.5px; }
    .band  { font-size: 13px; font-weight: 700; letter-spacing: .2px; }

    .flow {
      fill: none; stroke-width: 2.8; stroke-linecap: round;
      stroke-dasharray: 2 12;
      animation: flow 1.15s linear infinite;
    }
    @keyframes flow { to { stroke-dashoffset: -28; } }

    .dashflow {
      fill: none; stroke-width: 2.2; stroke-dasharray: 8 7;
      animation: dashflow 1.7s linear infinite;
    }
    @keyframes dashflow { to { stroke-dashoffset: -30; } }

    .pulse { animation: pulse 2.8s ease-in-out infinite; }
    @keyframes pulse { 0%%,100%% { opacity: .35 } 50%% { opacity: .95 } }

    @media (prefers-reduced-motion: reduce) {
      .flow, .dashflow, .pulse { animation: none; }
    }
  </style>
""" % {"font": FONT, "mono": MONO}


def head(w, h, title, desc):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="t d">
  <title id="t">{escape(title)}</title>
  <desc id="d">{escape(desc)}</desc>
{defs()}{STYLE}
  <rect x="0" y="0" width="{w}" height="{h}" rx="18" fill="url(#bg)"/>
  <rect x="0.5" y="0.5" width="{w-1}" height="{h-1}" rx="18" fill="none" stroke="#e2e8f0"/>
'''


def card(x, y, w, h, kind, lines, fs=16, rx=13, shadow=True, dash=False):
    fill, stroke, text = PALETTE[kind]
    cx = x + w / 2
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
           f'stroke="{stroke}" stroke-width="1.8"'
           + (' stroke-dasharray="7 5"' if dash else '')
           + (' filter="url(#shadow)"' if shadow else '') + '/>']
    n = len(lines)
    base = y + h / 2 - (n - 1) * 10 + 4
    for i, ln in enumerate(lines):
        cls = "mono" if (ln.startswith(("/", "s", "S", "T", "e", "c")) and " " not in ln) else \
              ("n" if i == 0 else "s")
        size = fs if i == 0 else 12.5
        out.append(f'<text x="{cx}" y="{base + i * (size + 7):.1f}" text-anchor="middle" '
                   f'class="{cls}" fill="{text}"'
                   + (f' style="font-size:{size}px"' if i == 0 else '') +
                   f'>{escape(ln)}</text>')
    return "\n".join(out)


def conn(d, kind, dots=1, dur=2.6, begin=0.0, delay=0.0, dash=False, opacity=0.35):
    color = ARROW_COLORS[kind]
    base = (f'<path d="{d}" fill="none" stroke="{color}" stroke-opacity="{opacity}" '
            f'stroke-width="2" stroke-dasharray="7 6" marker-end="url(#ar-{kind})"/>'
            if dash else
            f'<path d="{d}" fill="none" stroke="{color}" stroke-opacity="{opacity}" '
            f'stroke-width="2" marker-end="url(#ar-{kind})"/>')
    parts = [base]
    if not dash:
        parts.append(f'<path d="{d}" class="flow" stroke="{color}" '
                     f'style="animation-delay:-{delay}s"/>')
    else:
        parts.append(f'<path d="{d}" class="dashflow" stroke="{color}" opacity="0.85"/>')
    for k in range(dots):
        b = begin + k * (dur / max(dots, 1))
        parts.append(f'<circle r="4.4" fill="{color}" filter="url(#glow)">'
                     f'<animateMotion dur="{dur}s" begin="{b:.2f}s" repeatCount="indefinite" '
                     f'path="{d}"/></circle>')
    return "\n".join(parts)


def label(x, y, text, anchor="middle", fill="#475569", size=12, weight=600):
    return (f'<text x="{x}" y="{y}" text-anchor="{anchor}" fill="{fill}" '
            f'style="font-size:{size}px;font-weight:{weight}">{escape(text)}</text>')


def pill(x, y, w, text, kind):
    fill, stroke, colour = PALETTE[kind]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="26" rx="13" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="1.4"/>'
            f'<text x="{x + w / 2}" y="{y + 17.5}" text-anchor="middle" class="band" '
            f'fill="{colour}">{escape(text)}</text>')


def legend(x, y, items):
    """items: list of (kind, text). kind == "dash" ve net dut thay vi cham mau."""
    out = []
    cx = x
    for kind, text in items:
        if kind == "dash":
            out.append(f'<line x1="{cx}" y1="{y - 4}" x2="{cx + 34}" y2="{y - 4}" '
                       f'stroke="#94A3B8" stroke-width="2" stroke-dasharray="7 6"/>')
            cx += 46
        else:
            colour = ARROW_COLORS[kind]
            out.append(f'<circle cx="{cx}" cy="{y - 4}" r="4.4" fill="{colour}" '
                       f'filter="url(#glow)"/>')
            cx += 12
        out.append(label(cx, y, text, anchor="start", size=12))
        cx += len(text) * 6.6 + 30
    return "\n".join(out)


# ---------------------------------------------------------------------------
# 1. CHAIN OF TRUST
# ---------------------------------------------------------------------------
W, H = 1180, 572
s = [head(W, H, "Chain of trust",
          "Trình duyệt chỉ tin root CA có sẵn trong hệ điều hành; server phải gửi kèm "
          "intermediate thì chain mới đủ.")]
s.append('<text x="36" y="52" class="title">Chain of trust: vì sao thiếu intermediate lại lỗi</text>')
s.append('<text x="36" y="80" class="sub">Máy bạn test bằng Chrome có thể vẫn xanh — client thật thì không</text>')

cy, chh = 142, 100
s.append(card(36, cy, 150, chh, "client", ["Trình duyệt", "trust store của HĐH"]))
s.append(card(268, cy, 170, chh, "web", ["Web server", "example.com:443"]))
s.append(card(518, cy, 150, chh, "php", ["Leaf cert", "example.com"]))
s.append(card(748, cy, 160, chh, "data", ["Intermediate", "R11 / YE2"]))
s.append(card(984, cy, 160, chh, "neutral", ["Root CA", "ISRG Root X1"]))

# handshake hai chiều: ① sang phải, ② trả về
s.append(conn("M186 176 L262 176", "client", dur=2.0))
s.append(label(258, 166, "① SNI", anchor="end", fill="#b45309", size=11.5))
s.append(conn("M262 212 L194 212", "web", dur=2.0, begin=0.6))
s.append(label(196, 234, "② chain", anchor="start", fill="#1d4ed8", size=11.5))

# server dùng leaf; leaf được intermediate ký; intermediate được root ký
s.append(conn("M438 194 L514 194", "web", dur=2.2, begin=0.3))
s.append(conn("M668 194 L744 194", "data", dur=2.2, begin=0.7))
s.append(conn("M908 194 L980 194", "data", dur=2.2, begin=1.0))

# U: trình duyệt đối chiếu root trong trust store
s.append(conn("M111 242 L111 306 L1064 306 L1064 246", "ok", dots=1, dur=4.2, dash=True))
s.append(label(560, 298, "③ đối chiếu root trong trust store của máy",
               fill="#15803d", size=12))

# khối cảnh báo
s.append('<rect x="36" y="342" width="1108" height="164" rx="14" fill="#FEF2F2" '
         'fill-opacity="0.55" stroke="#FCA5A5" stroke-dasharray="7 5"/>')
s.append(label(56, 368, "Khi server chỉ gửi leaf (thiếu intermediate)", anchor="start",
               fill="#B91C1C", size=13))
s.append(card(56, 384, 200, 72, "danger", ["Chỉ gửi leaf", "chain = 1 cert"], fs=15))
s.append(card(330, 384, 350, 72, "ok", ["Chrome desktop", "tự tải intermediate (AIA) → vẫn xanh"], fs=15))
s.append(card(742, 384, 380, 72, "danger", ["Android cũ · Java · curl", "không tải bù → lỗi chain"], fs=15))
s.append(conn("M256 420 L326 420", "ok", dur=2.4, begin=0.2))
# đi vòng dưới card Chrome để không cắt qua nó
s.append(conn("M156 456 L156 484 L932 484 L932 460", "danger", dots=1, dur=3.6, begin=0.9))

s.append(legend(56, 546, [("ok", "gói tin di chuyển theo chiều xác thực"),
                          ("dash", "nét đứt = đối chiếu nội bộ / phản hồi")]))
emit("chain-of-trust.svg", s)


# ---------------------------------------------------------------------------
# 2. ACME FLOW
# ---------------------------------------------------------------------------
W, H = 1180, 624
s = [head(W, H, "Luồng ACME: HTTP-01 và DNS-01",
          "certbot tạo order với Let's Encrypt, CA xác thực qua file trên cổng 80 hoặc bản ghi "
          "TXT DNS, rồi trả cert về.")]
s.append('<text x="36" y="52" class="title">Hai cách xác thực: HTTP-01 và DNS-01</text>')
s.append('<text x="36" y="80" class="sub">Mũi tên chuyển động theo chiều thông điệp — nét đứt là phản hồi</text>')

# cột
X1, X2, X3 = 180, 580, 990
s.append(card(80, 112, 200, 64, "cmd", ["certbot", "trên server"], fs=15))
s.append(card(480, 112, 200, 64, "php", ["Let's Encrypt", "ACME server"], fs=15))
s.append(card(876, 112, 228, 64, "web", ["Web server :80", "hoặc DNS (bản ghi TXT)"], fs=15))

# lifeline
for x in (X1, X2, X3):
    s.append(f'<line x1="{x}" y1="180" x2="{x}" y2="556" stroke="#94A3B8" '
             f'stroke-width="1.8" stroke-dasharray="3 5"/>')

# dải HTTP-01
s.append('<rect x="36" y="206" width="1108" height="176" rx="13" fill="#EFF6FF" '
         'fill-opacity="0.45" stroke="#BFDBFE" stroke-dasharray="7 5"/>')
s.append(pill(46, 216, 104, "HTTP-01", "web"))

rows1 = [
    (256, "①", X1, X2, "tạo order + nhận token", "client", False),
    (288, "②", X2, X3, "GET /.well-known/acme-challenge/token", "web", False),
    (320, "③", X3, X2, "200 + nội dung token", "web", True),
    (352, "④", X2, X1, "ký cert → trả fullchain", "php", True),
]
for y, num, xa, xb, text, kind, dash in rows1:
    d = f"M{xa} {y} L{xb - 6 if xb > xa else xb + 6} {y}"
    s.append(conn(d, kind, dur=2.4, begin=(y % 7) / 10, dash=dash))
    s.append(label((xa + xb) / 2, y - 8, f"{num} {text}", fill="#1e3a8a", size=12))

# dải DNS-01
s.append('<rect x="36" y="400" width="1108" height="156" rx="13" fill="#ECFDF5" '
         'fill-opacity="0.5" stroke="#A7F3D0" stroke-dasharray="7 5"/>')
s.append(pill(46, 410, 96, "DNS-01", "data"))

rows2 = [
    (448, "①", X1, X2, "tạo order (kể cả wildcard)", "client", False),
    (480, "②", X2, X3, "query TXT _acme-challenge", "data", False),
    (512, "③", X3, X2, "trả giá trị TXT", "data", True),
    (540, "④", X2, X1, "ký cert → trả fullchain", "php", True),
]
for y, num, xa, xb, text, kind, dash in rows2:
    d = f"M{xa} {y} L{xb - 6 if xb > xa else xb + 6} {y}"
    s.append(conn(d, kind, dur=2.4, begin=(y % 5) / 10, dash=dash))
    s.append(label((xa + xb) / 2, y - 8, f"{num} {text}", fill="#065f46", size=12))

# ghi chú
s.append('<rect x="36" y="572" width="1108" height="38" rx="10" fill="#FFFBEB" '
         'stroke="#FCD34D" stroke-dasharray="7 5"/>')
s.append(label(56, 596, "certbot KHÔNG tự reload web server — dùng --deploy-hook",
               anchor="start", fill="#92400E", size=12))
s.append(label(700, 596, "· DNS-01 là cách duy nhất cấp wildcard",
               anchor="start", fill="#92400E", size=12))
emit("acme-flow.svg", s)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sinh / kiểm tra sơ đồ SVG động.")
    ap.add_argument("--out", default=DEFAULT_OUT, help="thư mục đích (mặc định: docs/img/)")
    ap.add_argument("--check", action="store_true",
                    help="không ghi file; exit 1 nếu file đã commit khác bản sinh ra")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    # Sinh xong mới ghi: sai XML thì không làm hỏng file đang có.
    for name, body in _PENDING.items():
        try:
            xml.dom.minidom.parseString(body)
        except Exception as exc:  # noqa: BLE001
            print(f"lỗi: {name} không phải XML hợp lệ: {exc}", file=sys.stderr)
            return 2

    if args.check:
        drift = []
        for name in sorted(_PENDING):
            path = os.path.join(args.out, name)
            if not os.path.exists(path):
                drift.append(f"thiếu file: {path}")
                continue
            with open(path, encoding="utf-8") as fh:
                if fh.read() != _PENDING[name]:
                    drift.append(f"lệch nội dung: {path}")
        if drift:
            print("Sơ đồ chưa đồng bộ với script:", file=sys.stderr)
            for line in drift:
                print("  - " + line, file=sys.stderr)
            print("Chạy: python3 tools/gen_diagrams.py", file=sys.stderr)
            return 1
        if not args.quiet:
            print(f"OK: {len(_PENDING)} sơ đồ khớp với script")
        return 0

    os.makedirs(args.out, exist_ok=True)
    for name in sorted(_PENDING):
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(_PENDING[name])
        if not args.quiet:
            print(f"ghi {path} ({os.path.getsize(path)} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
