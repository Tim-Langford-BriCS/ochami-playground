import http.server, sys
AZ = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_PUT(self): self.send_error(404)          # no IMDSv2 token, as OpenStack behaves
    def do_GET(self):
        if "availability-zone" in self.path:
            b = AZ.encode(); self.send_response(200)
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else: self.send_error(404)
http.server.HTTPServer(("169.254.169.254", 80), H).serve_forever()
