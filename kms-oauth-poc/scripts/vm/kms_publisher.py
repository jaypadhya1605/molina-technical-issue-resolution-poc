#!/usr/bin/env python3
"""KMS publisher - stand-in for the on-prem KMS app (runs on vm-kms-app, no public IP).

Every call uses an OAuth 2.0 access token from the VM's managed identity (Azure IMDS). No keys, no secrets.
  publish   : write article JSON to ADLS Gen2 (Entra token) -> send a tiny pointer to APIM -> APIM starts the AI Search indexer
  republish : same, with a new article version (fewer chunks) -> AI Search removes the orphaned chunks
  unpublish : soft-delete the blob -> pointer -> the indexer's deletion detection removes the article's chunks
  agent     : support-center agent app identity (user-assigned MI, role KMS.Search) queries through APIM
  posture   : negative tests (keys disabled, direct access denied, role checks)
  payload   : the old "push vectors through the gateway" pattern -> 413 at the gateway
On-prem equivalent: an Azure Arc-enabled server also has a managed identity. Production code should use azure-identity
(ManagedIdentityCredential), which handles the Azure VM, Azure Arc and AKS identity endpoints. This PoC calls the Azure VM
IMDS endpoint directly only so the VM needs no package installs.
"""
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, "config.json"), encoding="utf-8"))
APIM = CFG["apimGateway"].rstrip("/")
AUD = CFG["gatewayAudience"]
BLOB = f"https://{CFG['storageAccount']}.blob.core.windows.net/{CFG['container']}"
_tokens = {}


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def token(resource, client_id=None):
    key = (resource, client_id)
    if key in _tokens:
        return _tokens[key]
    q = {"api-version": "2018-02-01", "resource": resource}
    if client_id:
        q["client_id"] = client_id
    req = urllib.request.Request(
        "http://169.254.169.254/metadata/identity/oauth2/token?" + urllib.parse.urlencode(q),
        headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=15) as r:
        tok = json.load(r)["access_token"]
    _tokens[key] = tok
    return tok


def http(method, url, tok=None, body=None, headers=None, timeout=60):
    h = dict(headers or {})
    if tok:
        h["Authorization"] = "Bearer " + tok
    data = None
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body, separators=(",", ":")).encode()
            h.setdefault("Content-Type", "application/json")
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = body
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except Exception as e:  # network errors are part of the posture story
        return 0, {}, str(e).encode()


def j(b):
    try:
        return json.loads(b or b"{}")
    except Exception:
        return {"raw": (b or b"")[:200].decode(errors="replace")}


def short(b, n=160):
    return (b or b"").decode(errors="replace").replace("\n", " ")[:n]


def gw_token():
    return token(AUD)


def agent_token():
    return token(AUD, CFG["agentClientId"])


def put_article(aid, folder="articles"):
    art = json.load(open(os.path.join(HERE, folder, aid + ".json"), encoding="utf-8"))
    art["publishedAt"] = iso_now()
    data = json.dumps(art, indent=1).encode()
    s, _, b = http("PUT", f"{BLOB}/published/{aid}.json", token("https://storage.azure.com/"), data,
                   {"x-ms-blob-type": "BlockBlob", "x-ms-version": "2023-11-03", "Content-Type": "application/json"})
    if s != 201:
        raise SystemExit(f"  ADLS write failed for {aid}: HTTP {s} {short(b)}")
    return len(data), art["version"], len(art["chunks"])


def delete_article(aid):
    s, _, b = http("DELETE", f"{BLOB}/published/{aid}.json", token("https://storage.azure.com/"), None,
                   {"x-ms-version": "2023-11-03"})
    if s not in (202, 404):
        raise SystemExit(f"  ADLS delete failed for {aid}: HTTP {s} {short(b)}")
    return s


def latest_run_start():
    s, _, b = http("GET", f"{APIM}/kms/ingest/status", gw_token())
    runs = j(b).get("recentRuns") or [] if s == 200 else []
    return runs[0].get("startTime") if runs else ""


def send_pointer(action, ids):
    pointer = {"source": "kms-publisher@vm-kms-app", "action": action, "articleIds": ids,
               "correlationId": str(uuid.uuid4())}
    raw = json.dumps(pointer, separators=(",", ":"))
    for attempt in range(30):
        s, _, b = http("POST", f"{APIM}/kms/ingest/run", gw_token(), raw, {"Content-Type": "application/json"})
        if s != 409:
            break
        if attempt == 0:
            print("  gateway: indexer already running - retrying every 10s ...")
        time.sleep(10)
    print(f"  pointer -> POST /kms/ingest/run  {len(raw.encode())} bytes  => HTTP {s}")
    print(f"     {raw}")
    if s != 202:
        print("  " + short(b, 400))
        raise SystemExit(1)


def wait_for_indexer(before, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)
        s, _, b = http("GET", f"{APIM}/kms/ingest/status", gw_token())
        runs = (j(b).get("recentRuns") or []) if s == 200 else []
        if runs and runs[0].get("startTime") != before and runs[0].get("status") != "inProgress":
            r = runs[0]
            print(f"  indexer run: {r.get('status')}  processed={r.get('itemsProcessed')} failed={r.get('itemsFailed')}"
                  f"  {(r.get('startTime') or '')[11:19]} -> {(r.get('endTime') or '')[11:19]} UTC")
            for e in r.get("errors") or []:
                print(f"    error: {short(json.dumps(e).encode(), 300)}")
            return
    print("  indexer: still running (check later with: status)")


def cmd_publish(ids, folder="articles", action="publish"):
    if ids == ["all"]:
        ids = sorted(f[:-5] for f in os.listdir(os.path.join(HERE, folder)) if f.endswith(".json"))
    print(f"[{action}] identity: VM managed identity (system-assigned) via IMDS - no keys, no secrets")
    total = 0
    for aid in ids:
        n, ver, chunks = put_article(aid, folder)
        total += n
        print(f"  ADLS PUT published/{aid}.json  v{ver}  {chunks} chunks  {n} bytes")
    print(f"  {total} article bytes went to ADLS over its private endpoint - none through the gateway")
    before = latest_run_start()
    send_pointer(action, ids)
    wait_for_indexer(before)


def cmd_unpublish(ids):
    print("[unpublish] identity: VM managed identity via IMDS")
    for aid in ids:
        s = delete_article(aid)
        print(f"  ADLS DELETE published/{aid}.json => HTTP {s} (soft delete; indexer deletion detection removes the chunks)")
    before = latest_run_start()
    send_pointer("unpublish", ids)
    wait_for_indexer(before)


def cmd_status():
    s, _, b = http("GET", f"{APIM}/kms/ingest/status", gw_token())
    st = j(b)
    print(f"GET /kms/ingest/status => HTTP {s}  indexer={st.get('indexer')} status={st.get('indexerStatus')} lastRun={st.get('lastRunStatus')}")
    for r in (st.get("recentRuns") or [])[:4]:
        print(f"  {(r.get('startTime') or '')[:19]}  {r.get('status'):<16} processed={r.get('itemsProcessed')} failed={r.get('itemsFailed')}")
        for e in r.get("errors") or []:
            print(f"    error: {short(json.dumps(e).encode(), 300)}")


def cmd_dns():
    names = [f"{CFG['storageAccount']}.blob.core.windows.net", f"{CFG['storageAccount']}.dfs.core.windows.net",
             urllib.parse.urlparse(CFG["searchEndpoint"]).hostname, urllib.parse.urlparse(CFG["aoaiEndpoint"]).hostname,
             urllib.parse.urlparse(APIM).hostname]
    print("DNS from inside the VNet (private DNS zones -> private endpoints):")
    for n in names:
        try:
            ip = socket.gethostbyname(n)
        except Exception as e:
            ip = f"unresolved ({e})"
        print(f"  {n:<46} {ip:<15} {'PRIVATE' if ip.startswith('10.') else 'public'}")


def check(label, ok, detail):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label:<58} {detail}")


def cmd_posture():
    print("Posture checks from vm-kms-app (stand-in for the on-prem KMS server):")
    search = CFG["searchEndpoint"].rstrip("/")
    idx = CFG["indexName"]
    q = {"search": "*", "top": 1}
    s, _, _ = http("POST", f"{search}/indexes/{idx}/docs/search?api-version=2024-07-01", None, q, {"api-key": "not-a-real-key"})
    check("AI Search direct with an API key is rejected", s in (401, 403), f"HTTP {s}")
    s, _, _ = http("POST", f"{search}/indexes/{idx}/docs/search?api-version=2024-07-01", token("https://search.azure.com"), q)
    check("AI Search direct, VM token without data RBAC, rejected", s in (401, 403), f"HTTP {s}")
    aoai = CFG["aoaiEndpoint"].rstrip("/")
    emb = {"input": "test"}
    url = f"{aoai}/openai/deployments/{CFG['embeddingDeployment']}/embeddings?api-version=2024-10-21"
    s, _, _ = http("POST", url, None, emb, {"api-key": "not-a-real-key"})
    check("Azure OpenAI direct with an API key is rejected", s in (401, 403), f"HTTP {s}")
    s, _, _ = http("POST", url, token("https://cognitiveservices.azure.com"), emb)
    check("Azure OpenAI direct, VM token without RBAC, rejected", s in (401, 403), f"HTTP {s}")
    s, _, _ = http("POST", f"{APIM}/openai/deployments/{CFG['embeddingDeployment']}/embeddings?api-version=2024-10-21",
                   token("https://cognitiveservices.azure.com"), emb)
    check("APIM embedding API rejects any caller but AI Search", s == 401, f"HTTP {s}")
    s, _, b = http("GET", f"{BLOB}?restype=container&comp=list&prefix=published/&maxresults=100",
                   token("https://storage.azure.com/"), None, {"x-ms-version": "2023-11-03"})
    check("ADLS list with VM managed identity (OAuth) succeeds", s == 200, f"HTTP {s}, {(b or b'').count(b'<Blob>')} blobs")
    s, _, b = http("GET", f"{APIM}/kms/whoami", gw_token())
    w = j(b)
    check("APIM accepts the VM's OAuth token (whoami)", s == 200, f"HTTP {s} roles={w.get('appRoles')}")
    check("VM reaches APIM through its private endpoint", w.get("viaPrivateEndpoint") is True,
          f"viaPrivateEndpoint={w.get('viaPrivateEndpoint')} clientIp={w.get('clientIp')}")
    s, _, b = http("POST", f"{APIM}/kms/search", gw_token(), {"search": "ride to dialysis", "top": 1})
    check("Publisher identity cannot query (needs KMS.Search)", s == 403, f"HTTP {s} {j(b).get('error', '')}")
    s, _, _ = http("GET", f"{APIM}/kms/whoami", None)
    check("APIM rejects calls with no token", s == 401, f"HTTP {s}")


def cmd_agent(question):
    print("[agent] identity: support-center agent app (user-assigned managed identity, role KMS.Search)")
    tok = agent_token()
    body = {"search": question, "queryType": "semantic", "semanticConfiguration": "kms-semantic",
            "vectorQueries": [{"kind": "text", "text": question, "fields": "content_vector", "k": 10}],
            "select": "article_id,title,heading,version", "top": 3}
    s, h, b = http("POST", f"{APIM}/kms/search", tok, body)
    print(f"  Q: {question}")
    print(f"  POST /kms/search => HTTP {s}  (APIM -> AI Search with APIM's managed identity)")
    for d in j(b).get("value", []):
        print(f"   {d.get('@search.rerankerScore') or 0:.2f}  {d['article_id']} v{d['version']}  {d['title']} :: {d['heading']}")
    if s != 200:
        print("  " + short(b, 300))
    s, _, b = http("POST", f"{APIM}/kms/ingest/run", tok, {"action": "publish", "articleIds": ["KA-1001"]})
    print(f"  agent tries to trigger ingestion => HTTP {s} {j(b).get('error', '')} (no KMS.Ingest role)")


def cmd_payload():
    print("[payload] legacy pattern: push chunk vectors through the gateway")
    vec = [round((i % 97) / 97.0 - 0.5, 8) for i in range(3072)]
    compact = (",", ":")
    one = len(json.dumps(vec, separators=compact))
    raw = json.dumps({"value": [{"@search.action": "mergeOrUpload", "chunk_id": f"KA-1003_{i}", "content_vector": vec}
                                for i in range(1, 5)]}, separators=compact)
    print(f"  one 3072-dim embedding as JSON = {one:,} bytes; a 4-chunk article = {len(raw):,} bytes")
    print(f"  12,000 chunks x {one:,} bytes = ~{round(12000 * one / 1048576):,} MB of vectors per full reindex")
    s, _, b = http("POST", f"{APIM}/kms/ingest/run", gw_token(), raw, {"Content-Type": "application/json"})
    r = j(b)
    print(f"  POST /kms/ingest/run with vectors => HTTP {s} {r.get('error', '')} (gateway max {r.get('maxBytes')} bytes)")
    ptr = json.dumps({"source": "kms-publisher@vm-kms-app", "action": "publish", "articleIds": ["KA-1003"]},
                     separators=(",", ":"))
    print(f"  the pointer for the same article = {len(ptr)} bytes ({len(raw) // len(ptr):,}x smaller)")


def main():
    c, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("help", [])
    if c == "publish":
        cmd_publish(args or ["all"])
    elif c == "republish":
        cmd_publish(args or ["KA-1003"], folder="republish", action="republish")
    elif c == "unpublish":
        cmd_unpublish(args or ["KA-1012"])
    elif c == "status":
        cmd_status()
    elif c == "dns":
        cmd_dns()
    elif c == "posture":
        cmd_posture()
    elif c == "agent":
        cmd_agent(" ".join(args) or "member needs a ride to dialysis")
    elif c == "payload":
        cmd_payload()
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
