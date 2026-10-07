#!/usr/bin/env python3
"""
dl_helper.py - bantu download ROM dari link "halaman web" (Google Drive, SourceForge,
Pixeldrain, MediaFire) yang kalau diunduh mentah menghasilkan HTML, bukan file.

  dl_helper.py normalize <url>        -> URL unduh langsung (atau URL asal kalau tidak dikenal)
  dl_helper.py host <url>             -> gdrive | sourceforge | pixeldrain | mediafire | other
  dl_helper.py gdrive-form <html>     -> URL lanjutan dari halaman konfirmasi Google Drive
                                         ("can't scan for viruses"); exit 1 kalau tidak ada form
  dl_helper.py mediafire <html>       -> URL file asli dari halaman MediaFire; exit 1 kalau tidak ada
  dl_helper.py sniff <file>           -> html | zip | payload | gzip | xz | zstd | android | sparse | unknown
  dl_helper.py html-reason <html>     -> alasan singkat kalau HTML berisi pesan error yang dikenali
  dl_helper.py signed <url>           -> link bertanda tangan sementara (S3/Spaces/R2, X-Amz-Date +
                                         X-Amz-Expires): "<detik_sisa> <kedaluwarsa_UTC> <masa_berlaku>",
                                         kosong kalau bukan link seperti itu
"""
import html as htmlmod
import re
import sys
from urllib.parse import parse_qs, urlencode, urlparse


def gdrive_id(url):
    u = urlparse(url)
    if not u.netloc.endswith(("drive.google.com", "docs.google.com", "drive.usercontent.google.com")):
        return None
    m = re.search(r"/(?:file/)?d/([A-Za-z0-9_-]{10,})", u.path)
    if m:
        return m.group(1)
    q = parse_qs(u.query)
    if "id" in q:
        return q["id"][0]
    return None


def host(url):
    n = urlparse(url).netloc.lower()
    if gdrive_id(url):
        return "gdrive"
    if "sourceforge.net" in n:
        return "sourceforge"
    if "pixeldrain" in n:
        return "pixeldrain"
    if "mediafire.com" in n:
        return "mediafire"
    return "other"


def normalize(url):
    gid = gdrive_id(url)
    if gid:
        return "https://drive.usercontent.google.com/download?id=%s&export=download&confirm=t" % gid
    u = urlparse(url)
    n = u.netloc.lower()
    # SourceForge: link mirror bertoken (?ts=...) kedaluwarsa -> bentuk stabil .../files/<path>/download
    if n == "downloads.sourceforge.net" or n.endswith(".dl.sourceforge.net"):
        m = re.match(r"/project/([^/]+)/(.+)", u.path)
        if m:
            return "https://sourceforge.net/projects/%s/files/%s/download" % (m.group(1), m.group(2))
    if n.endswith("sourceforge.net"):
        m = re.match(r"/projects/([^/]+)/files/(.+?)(/download)?/?$", u.path)
        if m:
            return "https://sourceforge.net/projects/%s/files/%s/download" % (m.group(1), m.group(2))
    # Pixeldrain: /u/<id> (halaman) -> /api/file/<id>?download
    if "pixeldrain" in n:
        m = re.match(r"/(?:u|l|api/file)/([A-Za-z0-9]+)", u.path)
        if m:
            return "https://%s/api/file/%s?download" % (u.netloc, m.group(1))
    return url


def gdrive_form(page):
    m = re.search(r'<form[^>]*id="download-form"[^>]*action="([^"]+)"(.*?)</form>', page, re.S)
    if not m:
        m = re.search(r'<form[^>]*action="([^"]*download[^"]*)"(.*?)</form>', page, re.S)
    if not m:
        return None
    action = htmlmod.unescape(m.group(1))
    fields = re.findall(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"', m.group(2))
    if not fields:
        return None
    return action + ("&" if "?" in action else "?") + urlencode([(k, htmlmod.unescape(v)) for k, v in fields])


def mediafire(page):
    m = re.search(r'href="(https?://download[0-9]*\.mediafire\.com/[^"]+)"', page)
    return htmlmod.unescape(m.group(1)) if m else None


def sniff(path):
    with open(path, "rb") as f:
        head = f.read(512)
    if head[:4] == b"PK\x03\x04":
        return "zip"
    if head[:4] == b"CrAU":
        return "payload"
    if head[:2] == b"\x1f\x8b":
        return "gzip"
    if head[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    if head[:8] == b"ANDROID!" or head[:8] == b"VNDRBOOT":
        return "android"
    if head[:4] == b"\x3a\xff\x26\xed":
        return "sparse"
    t = head.lstrip().lower()
    if t.startswith((b"<!doctype", b"<html", b"<head", b"<?xml", b"<body", b"<script", b"{")):
        return "html"
    return "unknown"


def html_reason(page):
    p = page.lower()
    if "too many users have viewed or downloaded" in p or "quota" in p and "exceeded" in p:
        return "kuota download Google Drive file ini habis (coba lagi 24 jam, atau upload ulang / pakai host lain)"
    if "accounts.google.com" in p and ("sign in" in p or "servicelogin" in p):
        return "file Google Drive butuh login: ubah share ke 'Anyone with the link'"
    if "you need access" in p or "request access" in p:
        return "file Google Drive private: ubah share ke 'Anyone with the link'"
    if "file not found" in p or "not found" in p and "404" in p:
        return "file tidak ditemukan / sudah dihapus"
    return "server mengirim halaman HTML, bukan file ROM (link halaman web, bukan link unduh langsung)"


def signed(url, now=None):
    """(sisa_detik, waktu_kedaluwarsa_UTC, masa_berlaku_detik) untuk presigned URL AWS SigV4, atau None"""
    import calendar
    import time
    q = {k.lower(): v[0] for k, v in parse_qs(urlparse(url).query).items()}
    d, e = q.get("x-amz-date"), q.get("x-amz-expires")
    if not d or not e or not e.isdigit():
        return None
    try:
        t0 = calendar.timegm(time.strptime(d, "%Y%m%dT%H%M%SZ"))
    except ValueError:
        return None
    end = t0 + int(e)
    now = time.time() if now is None else now
    return int(end - now), time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(end)), int(e)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    cmd, arg = sys.argv[1], sys.argv[2]
    if cmd == "normalize":
        print(normalize(arg))
    elif cmd == "host":
        print(host(arg))
    elif cmd in ("gdrive-form", "mediafire", "html-reason"):
        page = open(arg, encoding="utf-8", errors="replace").read()
        if cmd == "html-reason":
            print(html_reason(page))
            return 0
        out = gdrive_form(page) if cmd == "gdrive-form" else mediafire(page)
        if not out:
            return 1
        print(out)
    elif cmd == "sniff":
        print(sniff(arg))
    elif cmd == "signed":
        r = signed(arg)
        if r:
            print("%d %s %d" % (r[0], r[1].replace(" ", "_"), r[2]))
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
