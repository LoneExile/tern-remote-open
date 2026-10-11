#!/usr/bin/perl
# Serves ONE file on 127.0.0.1 so Tern's browser block can show it.
#
#   perl serve.pl PORT TOKEN FILE NAME TYPE IDLE
#   perl serve.pl PORT TOKEN FILE NAME TYPE IDLE DOWNLOADS COPIER [ARG...]
#
# The first form answers only GET and HEAD for exactly /TOKEN/NAME with the
# file. The second (an image: TYPE image/png, jpeg, gif or webp) serves an image
# viewer instead: /TOKEN/NAME is a page with the image (at /TOKEN/raw/NAME) and
# two buttons, which POST to /TOKEN/copy (runs COPIER ARG... FILE, which puts the
# image on the clipboard) and /TOKEN/save (copies FILE into the DOWNLOADS
# directory under a name no file there has yet). A POST must carry the header
# `X-Remote-Open: 1`, which a page of another origin cannot send without a
# preflight this server never answers, and any Origin it carries must be this
# server's.
#
# Every request needs a Host header naming 127.0.0.1 or localhost with this
# port (a page on another origin cannot reach it through DNS rebinding).
# Everything else is refused. It exits by itself after IDLE_SECONDS without a
# connection. Core Perl only.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use IO::Socket::INET;
use IO::Select;
use POSIX ();

my ($port, $token, $file, $name, $type, $idle, $downloads, @copier) = @ARGV;
my $viewer = defined $downloads;

exit 64
  unless defined $idle
  && $port =~ /^[0-9]{1,5}\z/
  && $port >= 1 && $port <= 65535
  && $token =~ /^[0-9a-f]{32}\z/
  && $name =~ /^[A-Za-z0-9._-]{1,200}\z/
  && $type =~ m{^[a-z]+/[a-z0-9.+-]+(?:; charset=utf-8)?\z}
  && $idle =~ /^[0-9]{1,5}\z/ && $idle >= 1;
exit 64
  if $viewer
  && !($type =~ m{^image/(?:png|jpeg|gif|webp)\z}
    && $downloads =~ m{^/[^\x00-\x1f\x7f]*\z}
    && @copier
    && $copier[0] =~ m{^/}
    && !grep { /[\x00-\x1f\x7f]/ } @copier);
exit 65 unless -f $file && -r $file;
my $size = -s $file;

my $listener = IO::Socket::INET->new(
    Listen    => 5,
    LocalAddr => '127.0.0.1',
    LocalPort => $port,
    Proto     => 'tcp',
    ReuseAddr => 1,
) or exit 66;

$SIG{PIPE} = 'IGNORE';
my $select = IO::Select->new($listener);
my $child = 0;

# One connection at a time, each with a hard time limit, so a stalled client
# cannot hold the server.
while ($select->can_read($idle)) {
    my $client = $listener->accept or next;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        serve($client);
        alarm 0;
        1;
    } or do { alarm 0; kill 'KILL', $child if $child; $child = 0 };
    close $client;
}
exit 0;

sub reply {
    my ($client, $status, $reason, $headers, $body) = @_;
    my $head = "HTTP/1.1 $status $reason\r\n"
      . "Connection: close\r\n"
      . "Cache-Control: no-store\r\n"
      . "X-Content-Type-Options: nosniff\r\n"
      . "Referrer-Policy: no-referrer\r\n"
      . $headers . "\r\n";
    print $client $head;
    print $client $body if defined $body;
}

sub json {
    my ($client, $status, $reason, $body) = @_;
    reply($client, $status, $reason, "Content-Type: application/json\r\nContent-Length: " . length($body) . "\r\n", $body);
}

sub serve {
    my ($client) = @_;
    my $sel = IO::Select->new($client);
    my $request = '';
    while ($request !~ /\r?\n\r?\n/ && length($request) < 16384) {
        $sel->can_read(5) or return;
        my $got = sysread($client, my $chunk, 4096);
        return unless $got;
        $request .= $chunk;
    }

    my ($line, @lines) = split /\r?\n/, $request;
    return unless defined $line;
    my ($method, $target) = $line =~ m{^([A-Z]+) (\S+) HTTP/1\.[01]\z} or return;

    my %header;
    for my $h (@lines) {
        last if $h eq '';
        if ($h =~ /^([A-Za-z0-9-]+):\s*(.*?)\s*\z/) { $header{lc $1} //= $2 }
    }
    my $host = lc($header{host} // '');
    unless ($host eq "127.0.0.1:$port" || $host eq "localhost:$port") {
        reply($client, 421, 'Misdirected Request', "Content-Length: 0\r\n", '');
        return;
    }

    (my $path = $target) =~ s/[?#].*\z//s;
    if ($viewer && ($path eq "/$token/copy" || $path eq "/$token/save")) {
        unless ($method eq 'POST') {
            reply($client, 405, 'Method Not Allowed', "Allow: POST\r\nContent-Length: 0\r\n", '');
            return;
        }
        my $origin = $header{origin};
        unless (($header{'x-remote-open'} // '') eq '1'
            && (!defined $origin || $origin eq "http://127.0.0.1:$port" || $origin eq "http://localhost:$port")) {
            json($client, 403, 'Forbidden', '{"ok":false,"error":"refused"}');
            return;
        }
        if ($path eq "/$token/copy") { copy_image($client) } else { save_copy($client) }
        return;
    }

    unless ($method eq 'GET' || $method eq 'HEAD') {
        reply($client, 405, 'Method Not Allowed', "Allow: GET, HEAD\r\nContent-Length: 0\r\n", '');
        return;
    }
    if ($viewer && $path eq "/$token/$name") {
        my $page = page();
        reply($client, 200, 'OK',
            "Content-Type: text/html; charset=utf-8\r\nContent-Length: " . length($page) . "\r\n"
              . "Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; "
              . "script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'\r\n",
            $method eq 'GET' ? $page : undef);
        return;
    }
    my $raw = $viewer ? "/$token/raw/$name" : "/$token/$name";
    unless ($path eq $raw) {
        reply($client, 404, 'Not Found', "Content-Length: 0\r\n", '');
        return;
    }

    open(my $in, '<:raw', $file) or do {
        reply($client, 404, 'Not Found', "Content-Length: 0\r\n", '');
        return;
    };
    reply($client, 200, 'OK', "Content-Type: $type\r\nContent-Length: $size\r\n", undef);
    if ($method eq 'GET') {
        my $left = $size;
        while ($left > 0) {
            my $got = read($in, my $buf, $left < 65536 ? $left : 65536);
            last unless $got;
            print $client $buf;
            $left -= $got;
        }
    }
    close $in;
}

# Runs COPIER ARG... FILE with no input or output and answers by its exit status.
sub copy_image {
    my ($client) = @_;
    my $pid = fork;
    unless (defined $pid) {
        json($client, 500, 'Internal Server Error', '{"ok":false,"error":"could not start the copy"}');
        return;
    }
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec { $copier[0] } @copier, $file or POSIX::_exit(127);
    }
    $child = $pid;
    waitpid($pid, 0);
    my $status = $?;
    $child = 0;
    if ($status == 0) {
        json($client, 200, 'OK', '{"ok":true}');
    } else {
        json($client, 500, 'Internal Server Error', '{"ok":false,"error":"the copy failed"}');
    }
}

# Copies FILE into DOWNLOADS as NAME, else "STEM (2).EXT", "STEM (3).EXT" …:
# O_EXCL, so an existing file is never written to.
sub save_copy {
    my ($client) = @_;
    unless (-d $downloads) {
        json($client, 500, 'Internal Server Error', '{"ok":false,"error":"no Downloads folder"}');
        return;
    }
    my ($stem, $ext) = $name =~ /^(.+?)((?:\.[A-Za-z0-9]+)?)\z/;
    my ($out, $chosen);
    for my $n (1 .. 999) {
        my $candidate = $n == 1 ? $name : "$stem ($n)$ext";
        if (sysopen($out, "$downloads/$candidate", O_WRONLY | O_CREAT | O_EXCL, 0644)) {
            $chosen = $candidate;
            last;
        }
        last unless $!{EEXIST};
    }
    unless (defined $chosen) {
        json($client, 500, 'Internal Server Error', '{"ok":false,"error":"could not create the file in Downloads"}');
        return;
    }
    binmode $out;
    my $written = 0;
    if (open(my $in, '<:raw', $file)) {
        while (my $got = read($in, my $buf, 65536)) {
            print {$out} $buf or last;
            $written += $got;
        }
        close $in;
    }
    if (close($out) && $written == $size) {
        json($client, 200, 'OK', qq({"ok":true,"name":"$chosen"}));
    } else {
        unlink "$downloads/$chosen";
        json($client, 500, 'Internal Server Error', '{"ok":false,"error":"the copy into Downloads failed"}');
    }
}

# The viewer page. NAME is [A-Za-z0-9._-], so it is safe in HTML as it is.
sub page {
    return <<"HTML";
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name</title>
<style>
  :root { color-scheme: light dark; --bg: #f4f4f5; --bar: #ffffffe6; --fg: #18181b; --muted: #71717a; --line: #e4e4e7; --btn: #ffffff; --ok: #15803d; --bad: #b91c1c; }
  \@media (prefers-color-scheme: dark) { :root { --bg: #18181b; --bar: #27272ae6; --fg: #f4f4f5; --muted: #a1a1aa; --line: #3f3f46; --btn: #3f3f46; --ok: #4ade80; --bad: #f87171; } }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg); font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { position: sticky; top: 0; z-index: 1; display: flex; gap: 8px; align-items: center; padding: 8px 12px; background: var(--bar); border-bottom: 1px solid var(--line); backdrop-filter: blur(8px); }
  .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dims, .hint { color: var(--muted); white-space: nowrap; }
  .grow { flex: 1; }
  .status { white-space: nowrap; }
  .status.ok { color: var(--ok); } .status.bad { color: var(--bad); }
  button { font: inherit; padding: 4px 12px; border: 1px solid var(--line); border-radius: 6px; background: var(--btn); color: var(--fg); cursor: pointer; }
  button:hover:not(:disabled) { border-color: var(--muted); }
  button:disabled { opacity: .5; cursor: default; }
  main { display: flex; justify-content: center; align-items: flex-start; padding: 16px; min-height: calc(100% - 42px); }
  img { display: block; max-width: 100%; max-height: calc(100vh - 74px); object-fit: contain; cursor: zoom-in; background: repeating-conic-gradient(#8881 0% 25%, transparent 0% 50%) 50% / 16px 16px; }
  img.actual { max-width: none; max-height: none; cursor: zoom-out; }
</style>
<header>
  <span class="name">$name</span>
  <span class="dims" id="dims"></span>
  <span class="grow"></span>
  <span class="status" id="status" role="status"></span>
  <span class="hint" id="hint">Click the image for actual size</span>
  <button id="copy" type="button">Copy image</button>
  <button id="save" type="button">Save to Downloads</button>
</header>
<main><img id="img" src="raw/$name" alt="$name"></main>
<script>
  const img = document.getElementById("img");
  const status = document.getElementById("status");
  const buttons = [document.getElementById("copy"), document.getElementById("save")];
  img.addEventListener("load", () => {
    document.getElementById("dims").textContent = img.naturalWidth + " × " + img.naturalHeight;
  });
  img.addEventListener("click", () => {
    img.classList.toggle("actual");
    document.getElementById("hint").textContent = img.classList.contains("actual") ? "Click the image to fit" : "Click the image for actual size";
  });
  function say(text, tone) {
    status.textContent = text;
    status.className = "status" + (tone ? " " + tone : "");
  }
  async function act(what) {
    buttons.forEach((b) => (b.disabled = true));
    say(what === "copy" ? "Copying…" : "Saving…");
    try {
      const res = await fetch(what, { method: "POST", headers: { "X-Remote-Open": "1" } });
      const body = await res.json().catch(() => ({}));
      if (res.ok && body.ok) {
        say(what === "copy" ? "Copied to the clipboard" : "Saved to Downloads as " + body.name, "ok");
      } else {
        say((body.error || "HTTP " + res.status) + ": nothing changed", "bad");
      }
    } catch (e) {
      say("The preview has stopped: click the link again", "bad");
    }
    buttons.forEach((b) => (b.disabled = false));
  }
  buttons[0].addEventListener("click", () => act("copy"));
  buttons[1].addEventListener("click", () => act("save"));
</script>
</html>
HTML
}
