#!/usr/bin/env python3
"""Live assertion harness for the 0.2 async ingestion backbone.

Drives the REAL deployed stack over HTTPS (no mocks) and asserts behavioral
invariants at every stage of the job lifecycle. This is the pre-rollout gate:

    ./scripts/deploy.sh --from-source            # deploy the 0.2 branch
    ./scripts/deploy.sh --local-env              # refresh .env
    python3 tests/e2e/assert_ingestion.py        # run the gate

Scenarios:
  A. API contract (400s, auth rejection, 404-on-foreign-job semantics)
  B. Async text ingest: submit -> poll -> DONE, transition DAG, timestamps,
     chunks_created, doc_id, then vector-search verification of the content
  C. Dedup: identical resubmit terminates SKIPPED
  D. File ingest via data_base64 -> DONE + searchable
  E. Wait mode: single-call terminal response
  F. Presigned upload: begin_upload -> PUT to S3 -> event-driven resume -> DONE;
     plus metadata-tamper PUT must be rejected by the presign signature
  G. Failure path: corrupt PDF -> FAILED with error_detail, nothing searchable
  J. Real DOCX: valid .docx -> DONE, non-empty chunks searchable, original
     filename preserved (regression for the serverless empty-chunk + tmp-name bugs)
  K. Real PDF: valid .pdf -> DONE + searchable (pypdf extraction path)
  L. Large file (>10MB) via presign -> DONE + searchable (API GW payload bypass)
  M. Concepts: enterprise concept extraction present for an async-ingested doc
  N. Producer S3 drop: object dropped to the originals bucket with x-amz-meta-stache-*
     -> S3 event -> worker creates a Job -> searchable (needs boto3 + bucket env)
  H. Ownership: every job listed belongs to the calling principal
  I. Cleanup: permanent-delete created docs, verify search no longer finds them

Requires only stdlib. Config from stache-serverless/.env (deploy.sh --local-env)
or the environment: STACHE_API_URL, STACHE_COGNITO_TOKEN_URL,
STACHE_COGNITO_CLIENT_ID, STACHE_COGNITO_CLIENT_SECRET, STACHE_COGNITO_SCOPE.

Exit code 0 = all assertions passed; 1 = failures (listed in the summary).
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

TERMINAL = {"done", "skipped", "failed", "cancelled"}
# Allowed forward transitions. Observing anything else is a bug.
TRANSITIONS = {
    "uploading": {"queued", "processing", "done", "skipped", "failed", "cancelled"},
    "queued": {"processing", "done", "skipped", "failed", "cancelled"},
    "processing": {"done", "skipped", "failed", "cancelled", "awaiting_review"},
    "awaiting_review": {"done", "cancelled"},
}

PASS, FAIL, WARN = "PASS", "FAIL", "WARN"
results: list[tuple[str, str, str]] = []


def check(name: str, ok: bool, detail: str = "", warn_only: bool = False):
    verdict = PASS if ok else (WARN if warn_only else FAIL)
    results.append((verdict, name, detail))
    mark = {"PASS": "\033[32m✓\033[0m", "FAIL": "\033[31m✗\033[0m", "WARN": "\033[33m!\033[0m"}[verdict]
    line = f"  {mark} {name}"
    if detail and verdict != PASS:
        line += f" — {detail}"
    print(line, flush=True)
    return ok


def section(title: str):
    print(f"\n\033[1m{title}\033[0m", flush=True)


def load_env(env_file: Path):
    """Load the stack's .env, OVERRIDING inherited shell exports.

    Stale STACHE_* exports in ~/.bashrc (old client ids/secrets) are a known
    gotcha; the freshly generated .env is authoritative for this gate.
    """
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ[k.strip()] = v.strip().strip('"').strip("'")


class Api:
    def __init__(self, base_url: str, token: str | None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def request(self, method: str, path: str, body: dict | None = None,
                auth: bool = True, raw_url: str | None = None,
                raw_body: bytes | None = None, headers: dict | None = None):
        url = raw_url or (self.base_url + path)
        data = raw_body if raw_body is not None else (
            json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method)
        if raw_body is None and body is not None:
            req.add_header("Content-Type", "application/json")
        if auth and self.token and raw_url is None:
            req.add_header("Authorization", f"Bearer {self.token}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        # Retry transient network faults (SSL handshake / connection timeouts) so a
        # single blip mid-poll doesn't crash the whole gate. HTTP responses (incl.
        # 4xx/5xx) return immediately; only connection-level errors are retried, and
        # exhausting them returns code 0 which callers treat as retryable.
        last_err = None
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=90) as resp:
                    payload = resp.read()
                    try:
                        return resp.status, json.loads(payload) if payload else {}
                    except json.JSONDecodeError:
                        return resp.status, {"_raw": payload[:500].decode(errors="replace")}
            except urllib.error.HTTPError as e:
                payload = e.read()
                try:
                    return e.code, json.loads(payload) if payload else {}
                except json.JSONDecodeError:
                    return e.code, {"_raw": payload[:500].decode(errors="replace")}
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last_err = e
                time.sleep(2 * (attempt + 1))
        return 0, {"_neterror": str(last_err)}


def get_token() -> str:
    token_url = os.environ["STACHE_COGNITO_TOKEN_URL"]
    cid = os.environ["STACHE_COGNITO_CLIENT_ID"]
    secret = os.environ["STACHE_COGNITO_CLIENT_SECRET"]
    scope = os.environ.get("STACHE_COGNITO_SCOPE", "").strip()
    fields = {"grant_type": "client_credentials"}
    if scope:
        fields["scope"] = scope  # may contain spaces/slashes -> must be form-encoded
    body = urllib.parse.urlencode(fields).encode()
    basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    req = urllib.request.Request(token_url, data=body, method="POST", headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": f"Basic {basic}",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["access_token"]
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode(errors="replace")
        print(f"Token request failed: HTTP {e.code} from {token_url}\n  {detail}",
              file=sys.stderr)
        raise SystemExit(2)


def jwt_sub(token: str) -> str | None:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("sub")
    except Exception:
        return None


def poll_job(api: Api, job_id: str, timeout: float, interval: float = 3.0):
    """Poll until terminal. Returns (final_job, observed_statuses, invariant_errors)."""
    observed, errors = [], []
    deadline = time.time() + timeout
    job = None
    while time.time() < deadline:
        code, job = api.request("GET", f"/api/jobs/{job_id}")
        if code == 0:
            time.sleep(interval)  # transient network fault (already retried) — not a violation
            continue
        if code != 200:
            errors.append(f"GET job returned {code}: {job}")
            time.sleep(interval)
            continue
        status = job.get("status")
        if not observed or observed[-1] != status:
            if observed:
                prev = observed[-1]
                if status not in TRANSITIONS.get(prev, set()):
                    errors.append(f"illegal transition {prev} -> {status}")
            observed.append(status)
            print(f"      status: {' -> '.join(observed)}", flush=True)
        if status in TERMINAL:
            return job, observed, errors
        time.sleep(interval)
    errors.append(f"timed out after {timeout}s in status {observed[-1] if observed else '?'}")
    return job, observed, errors


def assert_terminal_job(label: str, job: dict, observed: list, errors: list,
                        expect_status: str):
    check(f"{label}: reached terminal state", bool(job) and job.get("status") in TERMINAL,
          f"observed={observed} errors={errors}")
    check(f"{label}: no invariant violations while polling", not errors, "; ".join(errors))
    check(f"{label}: final status == {expect_status}", job.get("status") == expect_status,
          f"got {job.get('status')} error_detail={job.get('error_detail')}")
    ts = [job.get("created_at"), job.get("updated_at")]
    if job.get("completed_at"):
        ts.append(job["completed_at"])
    known = [t for t in ts if t]
    check(f"{label}: timestamps monotonic (created<=updated<=completed)",
          known == sorted(known), str(ts))


def search(api: Api, sentinel: str, namespace: str) -> list:
    # top_k=20 mirrors the API default. All scenarios share one namespace and a
    # common sentinel prefix, so a single-chunk doc (e.g. the one-line PDF) can be
    # out-ranked by another doc's many rich chunks; a small top_k=5 would drop it
    # even though it ingested and is retrievable. This is an existence check
    # (found_sentinel scans the hits), so a wider top_k is strictly correct.
    code, body = api.request("POST", "/api/query", {
        "query": sentinel, "namespace": namespace, "synthesize": False,
        "rerank": False, "top_k": 20,
    })
    if code != 200:
        return []
    return body.get("results") or body.get("sources") or body.get("chunks") or []


def found_sentinel(hits: list, sentinel: str) -> bool:
    return any(sentinel in json.dumps(h) for h in hits)


def search_until(api: Api, sentinel: str, namespace: str,
                 timeout: float = 30.0, interval: float = 3.0) -> list:
    """Search with a bounded retry until the sentinel appears.

    S3 Vectors indexes newly-written vectors asynchronously, so a query issued
    the instant a job reaches ``done`` can miss the just-stored chunk (the vector
    is fetchable by key but not yet ANN-queryable). A single-shot search is
    therefore racy; poll until the sentinel shows up or the deadline passes and
    return the last hits either way.
    """
    deadline = time.time() + timeout
    hits: list = []
    while True:
        hits = search(api, sentinel, namespace)
        if found_sentinel(hits, sentinel) or time.time() >= deadline:
            return hits
        time.sleep(interval)


def make_docx(paragraphs: list[str]) -> bytes:
    """Build a minimal valid .docx (OOXML zip) with stdlib only.

    Regression fixture for the serverless empty-chunk bug: a real binary docx
    that DocxLoader (python-docx) must extract, then chunk into non-empty text.
    """
    import io
    import zipfile
    ctypes = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-'
              'officedocument.wordprocessingml.document.main+xml"/></Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
            'relationships/officeDocument" Target="word/document.xml"/></Relationships>')
    ps = "".join(f'<w:p><w:r><w:t xml:space="preserve">{p}</w:t></w:r></w:p>' for p in paragraphs)
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                f'<w:body>{ps}</w:body></w:document>')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ctypes)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", document)
    return buf.getvalue()


def make_pdf(text: str) -> bytes:
    """Build a minimal valid single-page PDF with extractable text (correct xref)."""
    content = f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode()
    bodies = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
         b"/Resources << /Font << /F1 5 0 R >> >> >>"),
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(bodies, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref_pos = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(bodies) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(bodies) + 1, xref_pos))
    return bytes(out)


def get_document(api: Api, doc_id: str, namespace: str):
    return api.request(
        "GET", f"/api/documents/id/{doc_id}?namespace={urllib.parse.quote(namespace)}")


def poll_concepts(api: Api, namespace: str, doc_id: str, timeout: float = 30.0) -> list:
    """Concept extraction is a post-ingest step; allow brief eventual consistency."""
    deadline = time.time() + timeout
    path = f"/api/documents/{urllib.parse.quote(namespace)}/{doc_id}/concepts"
    while time.time() < deadline:
        code, body = api.request("GET", path)
        if code == 404:
            return []  # endpoint absent (enterprise not deployed)
        concepts = (body.get("concepts") if isinstance(body, dict) else None) or []
        if concepts:
            return concepts
        time.sleep(3.0)
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file", default=str(Path(__file__).resolve().parents[2] / ".env"))
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--timeout", type=float, default=180.0, help="per-job poll timeout (s)")
    ap.add_argument("--skip-presign", action="store_true")
    ap.add_argument("--keep", action="store_true", help="skip cleanup (leave e2e docs behind)")
    args = ap.parse_args()

    load_env(Path(args.env_file))
    base_url = args.base_url or os.environ.get("STACHE_API_URL")
    if not base_url:
        print("STACHE_API_URL not set (run ./scripts/deploy.sh --local-env)", file=sys.stderr)
        return 2

    run_id = uuid.uuid4().hex[:8]
    ns = f"e2e-{run_id}"
    sentinel = f"zebra-quasar-{run_id}"
    print(f"Target: {base_url}   namespace: {ns}   run: {run_id}")

    section("Auth")
    token = get_token()
    sub = jwt_sub(token)
    check("obtained OAuth token via client_credentials", bool(token))
    api = Api(base_url, token)
    created_docs: list[tuple[str, str]] = []  # (doc_id, namespace)

    # A ─ contract ---------------------------------------------------------
    section("A. API contract & auth rejection")
    code, _ = Api(base_url, None).request("GET", "/api/jobs", auth=False)
    check("unauthenticated request rejected (401/403)", code in (401, 403), f"got {code}")
    code, _ = api.request("POST", "/api/ingest", {"namespace": ns})
    check("neither text nor data_base64 -> 400", code == 400, f"got {code}")
    code, _ = api.request("POST", "/api/ingest",
                          {"namespace": ns, "text": "x", "data_base64": "eA=="})
    check("both text and data_base64 -> 400", code == 400, f"got {code}")
    code, _ = api.request("POST", "/api/ingest",
                          {"namespace": ns, "data_base64": "!!notb64!!"})
    check("invalid base64 -> 400", code == 400, f"got {code}")
    code, _ = api.request("POST", "/api/ingest", {"namespace": ns, "upload": True})
    check("upload without filename -> 400", code == 400, f"got {code}")
    code, _ = api.request("GET", "/api/jobs?status=bogus")
    check("invalid status filter -> 400", code == 400, f"got {code}")
    code, _ = api.request("GET", f"/api/jobs/{uuid.uuid4()}")
    check("nonexistent job -> 404 (no existence leak)", code == 404, f"got {code}")

    # B ─ async text ingest ------------------------------------------------
    section("B. Async text ingest -> poll -> searchable")
    text = f"The migratory pattern of the {sentinel} follows lunar tides. " * 3
    code, job = api.request("POST", "/api/ingest", {
        "namespace": ns, "text": text, "content_type": "text",
        "filename": f"e2e-note-{run_id}", "metadata": {"e2e_run": run_id},
    })
    check("submit accepted (202 queued or 200 terminal)", code in (200, 202),
          f"got {code}: {job}")
    check("response carries job_id + status", bool(job.get("job_id")) and bool(job.get("status")))
    if job.get("job_id") and job.get("status") not in TERMINAL:
        job, observed, errors = poll_job(api, job["job_id"], args.timeout)
    else:
        observed, errors = [job.get("status")], []
    assert_terminal_job("text ingest", job, observed, errors, "done")
    check("text ingest: chunks_created >= 1", (job.get("chunks_created") or 0) >= 1,
          str(job.get("chunks_created")))
    check("text ingest: doc_id populated", bool(job.get("doc_id")))
    if job.get("doc_id"):
        created_docs.append((job["doc_id"], ns))
    hits = search_until(api, sentinel, ns)
    check("text ingest: content retrievable via vector search",
          found_sentinel(hits, sentinel), f"{len(hits)} hits, sentinel absent")

    # C ─ dedup ------------------------------------------------------------
    section("C. Dedup on identical resubmit")
    code, djob = api.request("POST", "/api/ingest", {
        "namespace": ns, "text": text, "content_type": "text",
        "filename": f"e2e-note-{run_id}",
    })
    if djob.get("job_id") and djob.get("status") not in TERMINAL:
        djob, dobs, derr = poll_job(api, djob["job_id"], args.timeout)
    else:
        dobs, derr = [djob.get("status")], []
    check("dedup: resubmit terminates", djob.get("status") in TERMINAL, str(dobs))
    check("dedup: identical content -> skipped", djob.get("status") == "skipped",
          f"got {djob.get('status')} (dedup guard may not be running in worker)")

    # D ─ file via base64 ----------------------------------------------------
    section("D. File ingest (data_base64)")
    md = f"# E2E fixture\n\nThe {sentinel}-file variant lives in a markdown file.\n".encode()
    code, fjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "data_base64": base64.b64encode(md).decode(),
        "filename": f"e2e-{run_id}.md", "content_type": "text/markdown",
    })
    check("file submit accepted", code in (200, 202), f"got {code}: {fjob}")
    if fjob.get("job_id") and fjob.get("status") not in TERMINAL:
        fjob, fobs, ferr = poll_job(api, fjob["job_id"], args.timeout)
    else:
        fobs, ferr = [fjob.get("status")], []
    assert_terminal_job("file ingest", fjob, fobs, ferr, "done")
    if fjob.get("doc_id"):
        created_docs.append((fjob["doc_id"], ns))
    hits = search_until(api, f"{sentinel}-file", ns)
    check("file ingest: content retrievable", found_sentinel(hits, f"{sentinel}-file"),
          f"{len(hits)} hits")

    # E ─ wait mode ----------------------------------------------------------
    section("E. Wait mode (single-call terminal)")
    code, wjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "text": f"wait-mode {sentinel}-wait content for e2e.",
        "content_type": "text", "wait": True, "filename": f"e2e-wait-{run_id}",
    })
    check("wait=true returns terminal in one call (200)",
          code == 200 and wjob.get("status") in TERMINAL,
          f"code={code} status={wjob.get('status')}")
    if wjob.get("doc_id"):
        created_docs.append((wjob["doc_id"], ns))

    # F ─ presigned upload -----------------------------------------------------
    if not args.skip_presign:
        section("F. Presigned upload flow + tamper rejection")
        code, pjob = api.request("POST", "/api/ingest", {
            "namespace": ns, "upload": True, "filename": f"e2e-presign-{run_id}.md",
            "content_type": "text/markdown",
        })
        ok = check("begin_upload returns upload_url + headers",
                   code == 200 and pjob.get("upload_url") and pjob.get("status") == "uploading",
                   f"code={code} status={pjob.get('status')}")
        if ok and pjob.get("job_id"):
            body = f"# Presign\n\nThe {sentinel}-presign variant arrived via S3 event.\n".encode()
            put_code, _ = api.request("PUT", "", raw_url=pjob["upload_url"], raw_body=body,
                                      headers=pjob.get("required_headers") or {})
            check("PUT to presigned URL accepted", put_code == 200, f"got {put_code}")
            pjob2, pobs, perr = poll_job(api, pjob["job_id"], args.timeout)
            assert_terminal_job("presign ingest", pjob2, pobs, perr, "done")
            if pjob2.get("doc_id"):
                created_docs.append((pjob2["doc_id"], ns))
            hits = search_until(api, f"{sentinel}-presign", ns)
            check("presign ingest: content retrievable",
                  found_sentinel(hits, f"{sentinel}-presign"), f"{len(hits)} hits")

            # Tamper: new ticket, mutate a pinned metadata header -> S3 must reject.
            _, tjob = api.request("POST", "/api/ingest", {
                "namespace": ns, "upload": True, "filename": f"e2e-tamper-{run_id}.md",
                "content_type": "text/markdown",
            })
            hdrs = dict(tjob.get("required_headers") or {})
            ns_keys = [k for k in hdrs if "namespace" in k.lower()]
            if ns_keys:
                hdrs[ns_keys[0]] = "victim-namespace"
                tcode, _ = api.request("PUT", "", raw_url=tjob["upload_url"],
                                       raw_body=b"tampered", headers=hdrs)
                check("tampered metadata PUT rejected by presign signature",
                      tcode == 403, f"got {tcode} — namespace pinning not enforced!")
            else:
                check("tamper test: namespace header pinned in ticket", False,
                      f"no namespace key among required_headers {list(hdrs)}", warn_only=True)

    # G ─ failure path ---------------------------------------------------------
    section("G. Failure path (corrupt PDF)")
    junk = b"%PDF-1.7\n%\xde\xad\xbe\xef this is not a real pdf body" + os.urandom(64)
    code, gjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "data_base64": base64.b64encode(junk).decode(),
        "filename": f"e2e-corrupt-{run_id}.pdf", "content_type": "application/pdf",
    })
    check("corrupt file submit accepted (fails async, not at intake)",
          code in (200, 202), f"got {code}")
    if gjob.get("job_id") and gjob.get("status") not in TERMINAL:
        gjob, gobs, gerr = poll_job(api, gjob["job_id"], args.timeout)
    else:
        gobs, gerr = [gjob.get("status")], []
    check("corrupt file: terminal", gjob.get("status") in TERMINAL, str(gobs))
    check("corrupt file: status failed with error_detail",
          gjob.get("status") == "failed" and bool(gjob.get("error_detail")),
          f"status={gjob.get('status')} detail={gjob.get('error_detail')!r}",
          warn_only=(gjob.get("status") == "done" and not gjob.get("chunks_created")))

    # J ─ real DOCX (regression: empty-chunk + tmp-filename bugs) ----------------
    section("J. Real DOCX ingest (regression)")
    docx_fn = f"e2e-{run_id}.docx"
    paras = [f"Paragraph {i}: the {sentinel}-docx sample describes migratory herons and "
             f"lunar navigation, with enough prose across many sentences to force the "
             f"chunker to emit more than one non-empty chunk." for i in range(40)]
    docx = make_docx(paras)
    code, xjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "data_base64": base64.b64encode(docx).decode(), "filename": docx_fn,
        "content_type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    })
    check("docx submit accepted", code in (200, 202), f"got {code}: {xjob}")
    if xjob.get("job_id") and xjob.get("status") not in TERMINAL:
        xjob, xobs, xerr = poll_job(api, xjob["job_id"], args.timeout)
    else:
        xobs, xerr = [xjob.get("status")], []
    assert_terminal_job("docx ingest", xjob, xobs, xerr, "done")
    check("docx ingest: chunks_created >= 1 (not one empty chunk)",
          (xjob.get("chunks_created") or 0) >= 1, str(xjob.get("chunks_created")))
    if xjob.get("doc_id"):
        created_docs.append((xjob["doc_id"], ns))
    check("docx ingest: extracted text is searchable (empty-chunk regression)",
          found_sentinel(search_until(api, f"{sentinel}-docx", ns), f"{sentinel}-docx"), "no hits")
    if xjob.get("doc_id"):
        dcode, doc = get_document(api, xjob["doc_id"], ns)
        fn = (doc.get("filename") or (doc.get("metadata") or {}).get("filename") or "")
        check("docx ingest: original filename preserved (no tmp* leak)",
              dcode == 200 and fn == docx_fn, f"filename={fn!r} (code {dcode})",
              warn_only=(dcode != 200))

    # K ─ real PDF ---------------------------------------------------------------
    section("K. Real PDF ingest")
    pdf = make_pdf(f"{sentinel}-pdf valid one page body extracted by pypdf")
    code, kjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "data_base64": base64.b64encode(pdf).decode(),
        "filename": f"e2e-{run_id}.pdf", "content_type": "application/pdf",
    })
    check("pdf submit accepted", code in (200, 202), f"got {code}: {kjob}")
    if kjob.get("job_id") and kjob.get("status") not in TERMINAL:
        kjob, kobs, kerr = poll_job(api, kjob["job_id"], args.timeout)
    else:
        kobs, kerr = [kjob.get("status")], []
    assert_terminal_job("pdf ingest", kjob, kobs, kerr, "done")
    if kjob.get("doc_id"):
        created_docs.append((kjob["doc_id"], ns))
    check("pdf ingest: extracted text is searchable",
          found_sentinel(search_until(api, f"{sentinel}-pdf", ns), f"{sentinel}-pdf"), "no hits")

    # L ─ large file via presign (payload-limit bypass) --------------------------
    if not args.skip_presign:
        section("L. Large file via presigned upload (>10MB)")
        unit = f"The {sentinel}-large marker recurs throughout this oversized file. ".encode()
        big = unit * (11 * 1024 * 1024 // len(unit) + 1)  # ~11MB > API GW 10MB limit
        code, ljob = api.request("POST", "/api/ingest", {
            "namespace": ns, "upload": True, "filename": f"e2e-large-{run_id}.txt",
            "content_type": "text/plain",
        })
        ok = check("large: begin_upload returns upload_url",
                   code == 200 and ljob.get("upload_url") and ljob.get("status") == "uploading",
                   f"code={code} status={ljob.get('status')}")
        if ok and ljob.get("job_id"):
            put_code, _ = api.request("PUT", "", raw_url=ljob["upload_url"], raw_body=big,
                                      headers=ljob.get("required_headers") or {})
            check(f"large: PUT {len(big)//1024//1024}MB direct to S3 accepted",
                  put_code == 200, f"got {put_code}")
            ljob2, lobs, lerr = poll_job(api, ljob["job_id"], max(args.timeout, 300))
            assert_terminal_job("large ingest", ljob2, lobs, lerr, "done")
            if ljob2.get("doc_id"):
                created_docs.append((ljob2["doc_id"], ns))
            check("large ingest: searchable (>10MB payload-limit bypass works)",
                  found_sentinel(search_until(api, f"{sentinel}-large", ns), f"{sentinel}-large"),
                  "no hits")

    # M ─ concepts extraction (enterprise) ---------------------------------------
    section("M. Concepts extraction (enterprise)")
    prose = (f"Photosynthesis converts sunlight into chemical energy inside plant "
             f"chloroplasts. Chlorophyll absorbs light and drives the Calvin cycle, "
             f"which fixes atmospheric carbon dioxide into glucose. This {sentinel}-concept "
             f"process shapes the global carbon cycle and sustains most life on Earth.")
    code, cjob = api.request("POST", "/api/ingest", {
        "namespace": ns, "text": prose, "content_type": "text", "wait": True,
        "filename": f"e2e-concepts-{run_id}",
    })
    if cjob.get("job_id") and cjob.get("status") not in TERMINAL:
        cjob, _, _ = poll_job(api, cjob["job_id"], args.timeout)
    check("concepts: source doc ingested", cjob.get("status") == "done",
          f"status={cjob.get('status')}")
    if cjob.get("doc_id"):
        created_docs.append((cjob["doc_id"], ns))
        concepts = poll_concepts(api, ns, cjob["doc_id"])
        check("concepts: extracted for the ingested doc (async parity with sync path)",
              len(concepts) >= 1,
              f"{len(concepts)} concepts (endpoint absent or extraction skipped)",
              warn_only=True)

    # N ─ producer S3 drop (Phase-2 producer path) -------------------------------
    section("N. Producer S3 drop")
    bucket = os.environ.get("INGEST_BLOB_S3_BUCKET") or os.environ.get("STACHE_ORIGINALS_BUCKET")
    try:
        import boto3  # optional — the rest of the harness stays stdlib-only
    except ImportError:
        boto3 = None
    if not (boto3 and bucket):
        check("producer drop exercised", False,
              "needs boto3 + INGEST_BLOB_S3_BUCKET in env (skipped)", warn_only=True)
    else:
        # Default to the server's ingest_blob_s3_prefix default ("originals").
        # deploy.sh --local-env doesn't emit INGEST_BLOB_S3_PREFIX, so an empty
        # default would drop the object at producers/... while the worker's
        # BlobStore.head re-prepends originals/ -> 404 -> N spuriously fails.
        prefix = (os.environ.get("INGEST_BLOB_S3_PREFIX") or "originals").strip("/")
        key = (f"{prefix}/" if prefix else "") + f"producers/e2e-{run_id}.md"
        pbody = f"# Producer\n\nThe {sentinel}-producer variant was dropped straight to S3.\n".encode()
        try:
            boto3.client("s3", region_name=os.environ.get("AWS_REGION")).put_object(
                Bucket=bucket, Key=key, Body=pbody, Metadata={
                    "stache-namespace": ns, "stache-filename": f"e2e-producer-{run_id}.md",
                    "stache-content-type": "text/markdown", "stache-requested-by": "e2e-producer",
                })
            dropped = True
        except Exception as e:
            # No AWS creds / no PutObject permission: this scenario needs direct S3
            # access (unlike A-M, which go through the API). Warn-skip rather than
            # crash the whole run and lose the cleanup section.
            check("producer drop exercised", False,
                  f"S3 put failed ({type(e).__name__}); export AWS_PROFILE and retry (skipped)",
                  warn_only=True)
            dropped = False
        if dropped:
            check("producer: object dropped into originals bucket", True, f"s3://{bucket}/{key}")
            deadline, found = time.time() + max(args.timeout, 120), False
            while time.time() < deadline and not found:
                hits = search(api, f"{sentinel}-producer", ns)
                found = found_sentinel(hits, f"{sentinel}-producer")
                if found:
                    for h in hits:
                        did = (h.get("metadata") or {}).get("doc_id") or h.get("doc_id")
                        if did:
                            created_docs.append((did, ns)); break
                else:
                    time.sleep(4.0)
            check("producer drop: S3 event -> worker created job -> searchable", found,
                  "producer-dropped object never became searchable")

    # H ─ ownership --------------------------------------------------------------
    section("H. Ownership scoping")
    code, listing = api.request("GET", "/api/jobs?limit=50")
    jobs = listing.get("jobs", [])
    owners = {j.get("requested_by") for j in jobs}
    check("GET /jobs returns 200 with our jobs", code == 200 and len(jobs) >= 1,
          f"code={code} count={len(jobs)}")
    check("every listed job belongs to the calling principal",
          owners <= {sub}, f"owners seen: {owners}, our sub: {sub}")
    code, filtered = api.request("GET", "/api/jobs?status=done")
    check("status filter honored", code == 200 and
          all(j.get("status") == "done" for j in filtered.get("jobs", [])))

    # I ─ cleanup -----------------------------------------------------------------
    if not args.keep:
        section("I. Cleanup")
        for doc_id, dns in created_docs:
            code, _ = api.request(
                "DELETE", f"/api/documents/id/{doc_id}?namespace={dns}&permanent=true")
            check(f"deleted {doc_id[:8]}…", code == 200, f"got {code}")
        time.sleep(3)
        hits = search(api, sentinel, ns)
        check("sentinel no longer searchable after delete",
              not found_sentinel(hits, sentinel),
              f"{len(hits)} hits still reference it", warn_only=True)

    # summary -----------------------------------------------------------------
    fails = [r for r in results if r[0] == FAIL]
    warns = [r for r in results if r[0] == WARN]
    print(f"\n\033[1m{'='*60}\033[0m")
    print(f"  {len(results)} assertions: "
          f"\033[32m{len(results)-len(fails)-len(warns)} passed\033[0m, "
          f"\033[33m{len(warns)} warnings\033[0m, "
          f"\033[31m{len(fails)} failed\033[0m")
    for _, name, detail in fails:
        print(f"  \033[31mFAIL\033[0m {name} — {detail}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
