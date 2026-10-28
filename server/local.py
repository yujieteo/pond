"""A local test server: runs the built server/pond_save and server/pond_read as slowcgi does.
Usage: python3 server/local.py <data dir> [port]. The data dir needs keys/ and entries/."""
import http.server, os, subprocess, sys

bin_dir = os.path.dirname(os.path.abspath(__file__))
data, port = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 8787

class Handler(http.server.BaseHTTPRequestHandler):
    def run(self):
        path = self.path.split("?")[0]
        program = "pond_save" if path == "/pond/entry" else "pond_read"
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))) if self.command == "POST" else b""
        env = {"REQUEST_METHOD": self.command, "REQUEST_URI": self.path, "POND_DIR": data,
               "POND_TEMPLATE": data + "/no-template.html"}
        if self.command == "POST":
            env["CONTENT_LENGTH"] = str(len(body))
        if self.headers.get("Signature"):
            env["HTTP_SIGNATURE"] = self.headers["Signature"]
        out = subprocess.run([f"{bin_dir}/{program}"], input=body, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode().split("\r\n"):
            name, _, value = line.partition(": ")
            if name == "Status":
                status = int(value.split()[0])
            elif name:
                headers.append((name, value))
        self.send_response(status)
        for h in headers:
            self.send_header(*h)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)
    do_GET = do_POST = run

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
