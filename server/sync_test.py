"""The sync test of pond_node (docs/store.md): 3 nodes on this machine, with a
proxy on each link between two nodes, so that the test can cut the links of
a node (a partition) while the node runs. It saves signed entries with
pond_save on each node, and checks that the nodes converge to the same
index hash within 60 s, with the highest rev of each entry, after
partitions, a node that sleeps (SIGSTOP), clock skew, kills with SIGKILL
and 100 writers at the same time. It needs openssl, and the built
server/pond_node and server/pond_save.

Usage: python3 server/sync_test.py [kills]   (100 kills if not given)"""
import json, os, random, shutil, signal, socket, subprocess, sys, tempfile, threading, time

here = os.path.dirname(os.path.abspath(__file__))
kills_wanted = int(sys.argv[1]) if len(sys.argv) > 1 else 100
work = tempfile.mkdtemp()
fails = 0
names = ["server", "desktop", "mac"]
random.seed(20261028)


def expect(name, ok):
    global fails
    print(("pass: " if ok else "FAIL: ") + name, flush=True)
    if not ok:
        fails += 1


def run(*args, data=None):
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


def new_key(path):
    """A P-256 private key in PEM at path, and the base64 DER of its public key."""
    run("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", path)
    return run("openssl", "base64", "-A", data=run("openssl", "pkey", "-in", path, "-pubout", "-outform", "DER"))


def sign(key, data):
    return run("openssl", "base64", "-A", data=run("openssl", "dgst", "-sha256", "-sign", key, data=data)).decode()


# FastCGI, as httpd and the peers send it.

def record(kind, content):
    return bytes([1, kind, 0, 1, len(content) >> 8, len(content) & 255, 0, 0]) + content


def param(name, value):
    out = b""
    for n in (len(name), len(value)):
        out += bytes([n]) if n < 128 else (n | 1 << 31).to_bytes(4, "big")
    return out + name + value


def fcgi(port, method, uri, body=b"", signature=None):
    """The CGI reply of pond_node, or None."""
    params = param(b"REQUEST_METHOD", method.encode()) + param(b"REQUEST_URI", uri.encode())
    if signature is not None:
        params += param(b"HTTP_SIGNATURE", signature.encode())
    req = record(1, bytes([0, 1, 0, 0, 0, 0, 0, 0])) + record(4, params) + record(4, b"")
    req += (record(5, body) if body else b"") + record(5, b"")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            s.sendall(req)
            reply = b""
            while chunk := s.recv(1 << 16):
                reply += chunk
    except OSError:
        return None
    out, at = b"", 0
    while at + 8 <= len(reply):
        n = reply[at + 4] << 8 | reply[at + 5]
        if reply[at + 1] == 6:
            out += reply[at + 8:at + 8 + n]
        at += 8 + n + reply[at + 6]
    return out


class Node:
    def __init__(self, name):
        self.name = name
        self.dir = f"{work}/{name}"
        self.pond = f"{self.dir}/pond"
        for d in ("keys", "entries", "nodes"):
            os.makedirs(f"{self.pond}/{d}")
        self.key = f"{work}/{name}.pem"
        self.pub = new_key(self.key)
        self.proc = None
        self.port = 0

    def start(self, peers):
        log = open(f"{self.dir}/node.log", "ab")
        args = [f"{here}/pond_node", "--pond", self.pond, "--store", f"{self.dir}/store",
                "--template", f"{self.dir}/template.html", "--port", "0",
                "--node", self.name, "--node-key", self.key]
        for p in peers:
            args += ["--peer", f"127.0.0.1:{p}"]
        self.peers = peers
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=log)
        line = self.proc.stdout.readline().decode()
        self.port = int(line.rsplit(" ", 1)[1])

    def restart(self):
        self.start(self.peers)

    def kill(self):
        self.proc.kill()
        self.proc.wait()

    def get(self, uri):
        reply = fcgi(self.port, "GET", uri)
        if reply is None or not reply.startswith(b"Status: 200"):
            return None
        return json.loads(reply.split(b"\r\n\r\n", 1)[1])

    def status(self):
        return self.get("/pond/node")

    def revs(self):
        """id: (rev, title) of each listed entry, or None."""
        got = self.get("/pond/entries.json")
        return None if got is None else {e["id"]: (e["rev"], e["entry"]["title"]) for e in got["entries"]}

    def log(self):
        with open(f"{self.dir}/node.log", "rb") as f:
            return f.read().decode(errors="replace")


class Proxy:
    """A listening port for each link from one node to another. A link with
    a node in cut takes the connection and closes it at once."""

    def __init__(self, nodes):
        self.nodes, self.cut = nodes, set()
        self.ports = {}
        for a in nodes:
            for b in nodes:
                if a != b:
                    s = socket.socket()
                    s.bind(("127.0.0.1", 0))
                    s.listen(64)
                    self.ports[a, b] = s.getsockname()[1]
                    threading.Thread(target=self.serve, args=(s, a, b), daemon=True).start()

    def serve(self, listener, a, b):
        while True:
            c, _ = listener.accept()
            if a in self.cut or b in self.cut:
                c.close()
                continue
            threading.Thread(target=self.link, args=(c, b), daemon=True).start()

    def link(self, c, b):
        try:
            d = socket.create_connection(("127.0.0.1", self.nodes[b].port), timeout=10)
        except OSError:
            c.close()
            return
        def pipe(x, y):
            try:
                while data := x.recv(1 << 16):
                    y.sendall(data)
            except OSError:
                pass
            for s in (x, y):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        threading.Thread(target=pipe, args=(d, c), daemon=True).start()
        pipe(c, d)


# The saves, and the model: the winner of each entry over all the saves that
# a node accepted, by the rule of a merge (the higher rev, then at the same
# rev the body that sorts later).
model = {}
model_lock = threading.Lock()


def save(node, id, rev, title, key="d1", times=None):
    """pond_save on node: the status code, and the rev of the server in a 409."""
    body = json.dumps({"entry": {"date": "2026-10-28", "title": title}, "id": id, "key": key,
                       "op": "put", "rev": rev, "v": 1}, sort_keys=True, separators=(",", ":")).encode()
    env = {"REQUEST_METHOD": "POST", "CONTENT_LENGTH": str(len(body)), "POND_DIR": node.pond,
           "HTTP_SIGNATURE": sign(f"{work}/{key}.pem", body)}
    out = subprocess.run([f"{here}/pond_save"], input=body, env=env, capture_output=True).stdout.decode()
    code = int(out.split()[1])
    if code == 201:
        if times is not None:
            for ext in ("json", "sig"):
                os.utime(f"{node.pond}/entries/{id}.{ext}", (times, times))
        with model_lock:
            if key != "rogue" and (id not in model or (rev, body) > model[id][:2]):
                model[id] = (rev, body, title)
    return code, int(out.rsplit(" ", 1)[1]) if code == 409 else 0


def converge(nodes, limit=60):
    """Seconds until all the nodes have the same index hash and list the
    winner of the model for each entry, or None. A node takes a save into
    its store at its next scan of the entry files, up to 1 s later."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < limit:
        hashes = [n.status() for n in nodes]
        if all(hashes) and len({h["hash"] for h in hashes}) == 1 and matches_model(nodes[:1], quiet=True):
            return time.monotonic() - t0
        time.sleep(0.1)
    return None


def matches_model(nodes, quiet=False):
    """True if each node lists the winner of the model for each entry."""
    want = {id: (m[0], m[2]) for id, m in model.items()}
    ok = True
    for n in nodes:
        got = n.revs()
        if got != want:
            ok = False
            if quiet:
                continue
            diff = sorted(k for k in set(want) | set(got or {}) if (got or {}).get(k) != want.get(k))
            print(f"  {n.name} differs from the model at {diff[:5]}")
    return ok


class Watch:
    """Reads the entries of each node each 50 ms, and counts each rev of an
    entry that is lower than a rev that the node listed before."""

    def __init__(self, nodes):
        self.nodes, self.seen, self.back, self.reads, self.stop = nodes, {}, [], 0, False
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()

    def watch(self):
        while not self.stop:
            for n in self.nodes:
                got = n.revs()
                if got is None:
                    continue
                self.reads += 1
                for id, (rev, _) in got.items():
                    was = self.seen.get((n.name, id), 0)
                    if rev < was:
                        self.back.append(f"{n.name} {id} rev {rev} after rev {was}")
                    self.seen[n.name, id] = max(was, rev)
            time.sleep(0.05)

    def end(self):
        self.stop = True
        self.thread.join()
        return self.back


def main():
    nodes = {name: Node(name) for name in names}
    for key in ("d1", "d2", "d3", "rogue"):
        pub = new_key(f"{work}/{key}.pem")
        for n in nodes.values():
            if key != "rogue" or n.name == "server":
                with open(f"{n.pond}/keys/{key}.pub", "wb") as f:
                    f.write(pub)
    for n in nodes.values():
        for m in nodes.values():
            with open(f"{n.pond}/nodes/{m.name}.pub", "wb") as f:
                f.write(m.pub)
    proxy = Proxy(nodes)
    for n in nodes.values():
        n.start([proxy.ports[n.name, m] for m in names if m != n.name])
    server, desktop, mac = (nodes[n] for n in names)
    all3 = list(nodes.values())
    results = []

    for k in range(20):
        save(server, f"e{k}", 1, f"entry {k}")
    t = converge(all3)
    expect(f"3 nodes converge after 20 saves on the server ({t and round(t, 1)} s)", t is not None and matches_model(all3))
    expect("each node has the 20 entries", all(n.status()["entries"] == 20 for n in all3))
    expect("the desktop logs the revisions that it took", "revisions from" in desktop.log())

    # A sync request needs a good signature from a node key.
    body = b"index\nserver\nx\n"
    expect("a sync request with no signature gets 403", fcgi(desktop.port, "POST", "/pond/sync", body).startswith(b"Status: 403"))
    expect("a sync request signed by a phone key gets 403",
           fcgi(desktop.port, "POST", "/pond/sync", body, sign(f"{work}/d1.pem", body)).startswith(b"Status: 403"))
    expect("a sync request signed by the node key gets the index",
           fcgi(desktop.port, "POST", "/pond/sync", body, sign(server.key, body)).startswith(b"Status: 200"))
    expect("a GET of /pond/sync gets 405", fcgi(desktop.port, "GET", "/pond/sync").startswith(b"Status: 405"))

    # A body signed by a key that only the server has: the other nodes refuse it.
    save(server, "forged", 1, "forged", key="rogue")
    time.sleep(12)
    expect("the server has the body of a key that the others do not have", "forged" in server.revs())
    expect("the desktop and the Mac refuse a body with no good phone signature",
           all("forged" not in n.revs() and "refused forged rev 1 from" in n.log() for n in (desktop, mac)))
    expect("the desktop asks for a refused body once", desktop.log().count("refused forged rev 1") == 1)
    save(server, "forged", 2, "forged, signed again")
    t = converge(all3)
    expect(f"a higher rev with a good signature replaces it on all nodes ({t and round(t, 1)} s)", t is not None and matches_model(all3))

    # A partition of each node: both sides save, also the same entry at the
    # same rev with other bodies. After the heal, the nodes converge.
    for k, name in enumerate(names):
        cut, other = nodes[name], nodes[names[(k + 1) % 3]]
        proxy.cut = {name}
        for i in range(5):
            save(cut, f"p{k}-{name}-{i}", 1, f"in partition {i}")
            save(other, f"p{k}-{other.name}-{i}", 1, f"outside {i}")
        rev = model.get("shared", (0,))[0] + 1
        save(cut, "shared", rev, f"{name} side of partition {k}")
        save(other, "shared", rev, f"{other.name} side of partition {k}")
        time.sleep(12)
        hashes = {n.status()["hash"] for n in all3}
        expect(f"while {name} is cut off, its hash differs", cut.status()["hash"] != other.status()["hash"] and len(hashes) >= 2)
        proxy.cut = set()
        t = converge(all3)
        results.append(t)
        expect(f"after the partition of {name} heals, the 3 index hashes are the same in {t and round(t, 1)} s (limit 60 s)",
               t is not None and matches_model(all3))

    # The Mac sleeps: its process stops, and its peers wait for replies.
    os.kill(mac.proc.pid, signal.SIGSTOP)
    for i in range(10):
        save(server, f"sleep-{i}", 1, f"while the Mac sleeps {i}")
    time.sleep(15)
    os.kill(mac.proc.pid, signal.SIGCONT)
    t = converge(all3)
    results.append(t)
    expect(f"after the Mac wakes, the nodes converge in {t and round(t, 1)} s", t is not None and matches_model(all3))

    # Clock skew: the server's clock is a day ahead, the desktop's a day
    # behind. Rev 1 has the later file time, but rev 2 wins.
    now = time.time()
    save(server, "skew", 1, "a day ahead", times=now + 86400)
    save(desktop, "skew", 2, "a day behind", times=now - 86400)
    save(desktop, "skew2", 1, "a day behind", times=now - 86400)
    save(server, "skew2", 2, "a day ahead", times=now + 86400)
    t = converge(all3)
    expect(f"with a clock a day ahead and one a day behind, the higher rev wins ({t and round(t, 1)} s)",
           t is not None and matches_model(all3) and server.revs()["skew"][0] == 2 and mac.revs()["skew2"][0] == 2)

    # Kills: SIGKILL of a node at a random time, while the others save and pull.
    watch = Watch(all3)
    count = 0
    while count < kills_wanted:
        victim = random.choice(all3)
        for i in range(3):
            n = random.choice(all3)
            id = f"k{random.randrange(30)}"
            rev = model.get(id, (0,))[0] + 1
            save(n, id, rev, f"kill {count} save {i} on {n.name}")
        time.sleep(random.uniform(0, 1.0))
        victim.kill()
        count += 1
        victim.restart()
    t = converge(all3)
    results.append(t)
    back = watch.end()
    expect(f"{count} kills with SIGKILL at a random time: the nodes converge in {t and round(t, 1)} s, with each saved winner",
           t is not None and matches_model(all3))
    expect(f"after the kills, no node listed a rev that goes back ({watch.reads} reads)", not back)
    for line in back[:5]:
        print("  " + line)

    # 100 writers at the same time on 3 devices: each device saves to its
    # own node, each writer with the rev after the one that it saw last, as
    # the outbox of the phone does after a 409.
    watch = Watch(all3)
    created = []

    def writer(w):
        n = all3[w % 3]
        seen = {}
        for k in range(3):
            id = f"w{random.randrange(10)}"
            for attempt in range(5):
                code, rev = save(n, id, seen.get(id, 0) + 1, f"writer {w} change {k}", key=f"d{w % 3 + 1}")
                if code == 409:
                    seen[id] = rev
                    continue
                if code == 201:
                    seen[id] = seen.get(id, 0) + 1
                    created.append(1)
                break

    threads = [threading.Thread(target=writer, args=(w,)) for w in range(100)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    t = converge(all3)
    results.append(t)
    back = watch.end()
    expect(f"100 writers on 3 devices ({len(created)} saves): the nodes converge in {t and round(t, 1)} s, with the winner of each entry",
           t is not None and matches_model(all3))
    expect(f"100 writers: no node listed a rev that goes back ({watch.reads} reads)", not back)
    for line in back[:5]:
        print("  " + line)

    good = [r for r in results if r is not None]
    if good:
        print(f"note: convergence after a heal: max {max(good):.1f} s, {len(good)} measures", flush=True)
    for n in all3:
        n.kill()


try:
    main()
finally:
    shutil.rmtree(work, ignore_errors=True)
print("all pass" if fails == 0 else f"{fails} failed")
sys.exit(1 if fails else 0)
