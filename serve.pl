#!/usr/bin/perl
# Serves ONE file on 127.0.0.1 so Tern's browser block can show it.
#
#   perl serve.pl PORT TOKEN FILE NAME TYPE IDLE_SECONDS
#
# It answers only GET and HEAD for exactly /TOKEN/NAME, and only when the Host
# header names 127.0.0.1 or localhost with this port (a page on another origin
# cannot read it through DNS rebinding). Everything else is refused. It exits
# by itself after IDLE_SECONDS without a connection. Core Perl only.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my ($port, $token, $file, $name, $type, $idle) = @ARGV;

exit 64
  unless defined $idle
  && $port =~ /^[0-9]{1,5}\z/
  && $port >= 1 && $port <= 65535
  && $token =~ /^[0-9a-f]{32}\z/
  && $name =~ /^[A-Za-z0-9._-]{1,200}\z/
  && $type =~ m{^[a-z]+/[a-z0-9.+-]+(?:; charset=utf-8)?\z}
  && $idle =~ /^[0-9]{1,5}\z/ && $idle >= 1;
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
    } or alarm 0;
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

    my $host = '';
    for my $header (@lines) {
        last if $header eq '';
        if ($header =~ /^host:\s*(\S+)\s*\z/i) { $host = lc $1; last }
    }
    unless ($host eq "127.0.0.1:$port" || $host eq "localhost:$port") {
        reply($client, 421, 'Misdirected Request', "Content-Length: 0\r\n", '');
        return;
    }
    unless ($method eq 'GET' || $method eq 'HEAD') {
        reply($client, 405, 'Method Not Allowed', "Allow: GET, HEAD\r\nContent-Length: 0\r\n", '');
        return;
    }

    (my $path = $target) =~ s/[?#].*\z//s;
    unless ($path eq "/$token/$name") {
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
