#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mobile-friendly noVNC form login with an HttpOnly cookie session."""
import os
import time
import hmac
import hashlib
import urllib.parse
import http.cookies as cookies_mod
from websockify import websocketproxy
from websockify import auth_plugins as auth

WEB_DIR = os.environ.get("VNC_WEB_DIR", "/usr/share/novnc")
RFB_PORT = int(os.environ.get("RFB_PORT", "5900"))
USERNAME = os.environ.get("VNC_AUTH_USER", "qwenpaw")
PASSWORD = os.environ.get("VNC_AUTH_PASS", "qwenpaw")
AUTH_SECRET = os.environ.get("VNC_AUTH_SECRET", PASSWORD)
COOKIE_NAME = "QWENPAW_VNC_SESSION"
COOKIE_TTL = 24 * 3600
PUBLIC_PATHS = {"/", "/index.html", "/login", "/favicon.ico"}


def signature(timestamp):
    payload = "%d:%s:%s" % (timestamp, USERNAME, PASSWORD)
    return hmac.new(AUTH_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()


def valid_session(value):
    try:
        timestamp_text, received = value.split(".", 1)
        timestamp = int(timestamp_text)
    except (ValueError, AttributeError):
        return False
    now = int(time.time())
    if timestamp > now + 300 or now - timestamp > COOKIE_TTL:
        return False
    return hmac.compare_digest(received, signature(timestamp))


def request_cookie(headers):
    jar = cookies_mod.SimpleCookie()
    try:
        jar.load(headers.get("Cookie", ""))
    except Exception:
        return None
    item = jar.get(COOKIE_NAME)
    return item.value if item else None


class LoginError(auth.AuthenticationError):
    pass


class CookieAuth(auth.BasePlugin):
    def authenticate(self, headers, target_host, target_port):
        if not valid_session(request_cookie(headers)):
            raise LoginError(
                response_code=302,
                response_headers={"Location": "/", "Content-Length": "0"},
                response_msg="Login required",
            )


class LoginHandler(websocketproxy.ProxyRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            encoded = LOGIN_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)
            return
        super().do_GET()

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/login":
            self.send_error(404)
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
        except ValueError:
            length = 0
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        user = (form.get("username") or [""])[0]
        password = (form.get("password") or [""])[0]
        if hmac.compare_digest(user, USERNAME) and hmac.compare_digest(password, PASSWORD):
            timestamp = int(time.time())
            token = "%d.%s" % (timestamp, signature(timestamp))
            self.send_response(302)
            self.send_header("Location", "/vnc.html?autoconnect=1&resize=scale&show_dot=0")
            self.send_header(
                "Set-Cookie",
                "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax" %
                (COOKIE_NAME, token, COOKIE_TTL),
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(302)
            self.send_header("Location", "/?error=1")
            self.send_header("Content-Length", "0")
            self.end_headers()

    def auth_connection(self):
        if self.path.split("?", 1)[0] in PUBLIC_PATHS:
            return
        super().auth_connection()


LOGIN_PAGE = r'''<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>Chromium 云端浏览器</title>
<style>
:root{--bg1:#0f2027;--bg2:#203a43;--bg3:#2c5364;--accent:#00d4ff}
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
html,body{width:100%;height:100%;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
body{display:flex;align-items:center;justify-content:center;padding:16px;background:linear-gradient(135deg,var(--bg1),var(--bg2),var(--bg3))}
.card{width:min(92vw,400px);padding:36px 30px 28px;border-radius:22px;background:rgba(255,255,255,.94);box-shadow:0 24px 60px rgba(0,0,0,.45);text-align:center}
.logo{width:64px;height:64px;margin:0 auto 12px;border-radius:18px;background:linear-gradient(135deg,#00d4ff,#7b2ff7);display:flex;align-items:center;justify-content:center;font-size:28px}
h1{font-size:20px;color:#1b2a38;margin-bottom:4px}.sub{font-size:13px;color:#7a8a99;margin-bottom:22px}.field{margin-bottom:12px}
label{display:block;text-align:left;font-size:12px;color:#5a6b7a;margin-bottom:5px;font-weight:600}
input{width:100%;padding:13px 16px;border-radius:12px;border:1.5px solid #dde5ec;font-size:15px;outline:none;background:#f6f9fc;color:#1b2a38}
input:focus{border-color:var(--accent);background:#fff;box-shadow:0 0 0 3px rgba(0,212,255,.18)}
button{width:100%;margin-top:8px;padding:13px;border:0;border-radius:12px;background:linear-gradient(135deg,#00b4d8,#4b7bec);color:#fff;font-size:16px;font-weight:600}
.error{display:none;margin-top:14px;padding:10px;border-radius:10px;background:#fff0f0;color:#d64040;font-size:13px}.error.show{display:block}
.note{margin-top:16px;font-size:11px;color:#9aa8b5}
</style></head><body><main class="card">
<div class="logo">🌐</div><h1>Chromium 云端浏览器</h1><div class="sub">登录后进入远程桌面</div>
<form method="post" action="/login" autocomplete="on">
<div class="field"><label for="u">账号</label><input id="u" name="username" autocomplete="username" required autofocus></div>
<div class="field"><label for="p">密码</label><input id="p" name="password" type="password" autocomplete="current-password" required></div>
<button type="submit">进 入</button></form>
<div id="error" class="error">账号或密码不正确，请重试</div><div class="note">🔒 安全登录 · 单页面 · 移动端适配</div>
</main><script>if(location.search.includes('error=1'))document.getElementById('error').className='error show';</script>
</body></html>'''


def main():
    server = websocketproxy.WebSocketProxy(
        listen_port=int(os.environ.get("VNC_PORT", "18080")),
        listen_host="127.0.0.1",
        web=WEB_DIR,
        RequestHandlerClass=LoginHandler,
        auth_plugin=CookieAuth(),
        target_host="127.0.0.1",
        target_port=RFB_PORT,
        web_auth=True,
    )
    server.start_server()


if __name__ == "__main__":
    main()
