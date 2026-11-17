# Copyright (c) 2026 Jed Brown
# SPDX-License-Identifier: GPL-3.0-only
# Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live
"""Serves the probe page and appends its POSTed samples to the file given as argv[1]."""
import http.server,sys,time
out=open(sys.argv[1],'a')
class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(s):
        n=int(s.headers['Content-Length']);out.write(s.rfile.read(n).decode()+"\n");out.flush()
        s.send_response(204);s.end_headers()
    def log_message(s,*a):pass
http.server.ThreadingHTTPServer(('127.0.0.1',8765),H).serve_forever()
