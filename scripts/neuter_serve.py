"""Proves tests/serve.sh can fail: breaks serve.pl one behaviour at a time (a copy, never the
real file) and requires the serve.pl tests to go RED. A hang counts as RED."""
import os, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(ROOT + "/serve.pl").read()
M = [
    ("host-check", 'unless ($host eq "127.0.0.1:$port" || $host eq "localhost:$port") {', "unless (1) {"),
    ("token-path", "unless ($path eq $raw) {", "unless (1) {"),
    ("method", "unless ($method eq 'GET' || $method eq 'HEAD') {", "unless (1) {"),
    ("head-body", "if ($method eq 'GET') {", "if (1) {"),
    ("bind-all", "LocalAddr => '127.0.0.1',", "LocalAddr => '0.0.0.0',"),
    ("nosniff", '"X-Content-Type-Options: nosniff\\r\\n"', '""'),
    ("idle-exit", "while ($select->can_read($idle)) {", "while (1) { $select->can_read($idle);"),
    ("token-arg", "$token =~ /^[0-9a-f]{32}\\z/", "1"),
    # the image viewer
    ("viewer-type", "$type =~ m{^image/(?:png|jpeg|gif|webp)\\z}", "1"),
    ("post-header", "($header{'x-remote-open'} // '') eq '1'", "1"),
    ("post-origin", "!defined $origin ||", "1 ||"),
    ("post-only", "unless ($method eq 'POST') {", "unless (1) {"),
    ("raw-path", 'my $raw = $viewer ? "/$token/raw/$name" : "/$token/$name";', 'my $raw = "/$token/$name";'),
    ("copy-file", "exec { $copier[0] } @copier, $file", "exec { $copier[0] } @copier"),
    ("copy-status", "if ($status == 0) {", "if (1) {"),
    ("save-excl", "O_WRONLY | O_CREAT | O_EXCL", "O_WRONLY | O_CREAT"),
]
bad = 0
for ident, old, new in M:
    if src.count(old) != 1:
        print("STALE", ident, src.count(old)); bad += 1; continue
    p = os.path.join(tempfile.gettempdir(), f"serve_neuter_{ident}.pl")
    open(p, "w").write(src.replace(old, new))
    try:
        r = subprocess.run(["bash", "tests/serve.sh"], cwd=ROOT, env=dict(os.environ, SERVE=p), capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        print("RED      ", ident, "(the tests hung)"); os.remove(p); continue
    fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL ")]
    if r.returncode == 0:
        print("SURVIVED", ident); bad += 1
    else:
        print("RED     ", ident, len(fails), "failing; first:", fails[0][:70] if fails else "(no FAIL line)")
    os.remove(p)
print("serve.pl mutations: %d, not caught: %d" % (len(M), bad))
sys.exit(1 if bad else 0)
