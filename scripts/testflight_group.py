"""Waits until App Store Connect processes a Waldenlog build, then puts it in a TestFlight group.

Usage: testflight_group.py <build number> <group name>
Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID. Signs the API token with openssl.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

APP_ID = "6827944050"
TIMEOUT = 60 * 60  # seconds
API = "https://api.appstoreconnect.apple.com/v1"


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } -> r || s, 32 bytes each.
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


def token():
    head = b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200,
                           "aud": "appstoreconnect-v1"}).encode())
    msg = head + b"." + body
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=msg, capture_output=True, check=True).stdout
    return (msg + b"." + b64(der_to_raw(der))).decode()


def call(path, data=None):
    req = urllib.request.Request(API + path, method="POST" if data else "GET",
                                 data=json.dumps(data).encode() if data else None,
                                 headers={"Authorization": "Bearer " + token(),
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{req.method} {path}: {e.code} {e.read().decode()}")
    return json.loads(raw) if raw else {}


def main(build, group):
    query = urllib.parse.urlencode({"filter[app]": APP_ID, "filter[version]": build,
                                    "include": "preReleaseVersion,buildBetaDetail"})
    deadline = time.time() + TIMEOUT
    while True:
        res = call("/builds?" + query)
        state = res["data"][0]["attributes"]["processingState"] if res["data"] else "NOT FOUND"
        print(f"build {build}: {state}", flush=True)
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID") or time.time() > deadline:
            sys.exit(f"build {build} is {state}")
        time.sleep(30)
    b = res["data"][0]
    included = {i["type"]: i["attributes"] for i in res["included"]}
    version = included["preReleaseVersions"]["version"]
    groups = call("/betaGroups?" + urllib.parse.urlencode({"filter[app]": APP_ID, "filter[name]": group}))
    g = groups["data"][0]
    # A group with access to all builds gets each build itself, and the API refuses the add.
    if not g["attributes"]["hasAccessToAllBuilds"]:
        call(f"/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
    # Just after VALID, the response can still omit the beta detail.
    beta = included.get("buildBetaDetails", {}).get("internalBuildState", "UNKNOWN")
    print(f"version {version} build {build}: {state}, group {group}: {beta}")

if __name__ == "__main__":
    main(*sys.argv[1:3])
