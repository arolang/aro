#!/usr/bin/env perl
#
# GitLab #837: the test-type detector used to grep raw .aro source, so a
# comment mentioning a service decided how the example was tested. A comment
# explaining that `Listen ... for the <port: ...>` does not bind a socket --
# "that is what `Start the <socket-server>` does" -- turned a console example
# into a socket one, and the harness then ran the socket executor against a
# program that never binds a port.

use strict;
use warnings;
use v5.30;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More tests => 12;

use lib File::Spec->catdir(dirname(__FILE__), File::Spec->updir, 'lib');

use AROTest::Detect qw(detect_example_type strip_aro_comments);
use AROTest::Config qw($examples_dir);

# --- strip_aro_comments -----------------------------------------------------

is strip_aro_comments(undef), '', 'undef source strips to empty';

like strip_aro_comments(qq{Start the <socket-server> with <port>.\n}),
    qr/Start the <socket-server>/,
    'code outside comments survives';

unlike strip_aro_comments(qq{(* Start the <socket-server> does that *)\n}),
    qr/Start\s+the\s+<socket-server>/,
    'block comment is stripped';

unlike strip_aro_comments(qq{// Start the <socket-server> does that\nLog "hi".\n}),
    qr/Start\s+the\s+<socket-server>/,
    'line comment is stripped';

like strip_aro_comments(qq{// Start the <socket-server>\nLog "hi".\n}),
    qr/Log "hi"/,
    'a line comment ends at the newline';

unlike strip_aro_comments(qq{(* one *)(* Start the <socket-server> *)}),
    qr/Start\s+the\s+<socket-server>/,
    'two block comments on one line are both stripped (non-greedy)';

like strip_aro_comments(qq{Log "(* Start the <socket-server> *)" to the <console>.\n}),
    qr/Start\s+the\s+<socket-server>/,
    'comment markers inside a string literal are not comments';

is strip_aro_comments(qq{A (* x *) B}), 'A   B',
    'a stripped comment leaves a space, so text cannot be glued together';

like strip_aro_comments(qq{Compute the <half> from <n> / 2.\n}),
    qr{<n> / 2},
    'a lone slash is not a line comment';

# --- detect_example_type ----------------------------------------------------

my $tmp = tempdir(CLEANUP => 1);
$examples_dir = $tmp;

sub write_example {
    my ($name, $source) = @_;
    my $dir = File::Spec->catdir($tmp, $name);
    mkdir $dir or die "mkdir $dir: $!";
    open my $fh, '>', File::Spec->catfile($dir, 'main.aro') or die $!;
    print {$fh} $source;
    close $fh;
    return $name;
}

write_example('CommentedSocket', <<'ARO');
(Application-Start: Commented) {
    (* Listen does not bind a port -- Start the <socket-server> is what does. *)
    Log "hello" to the <console>.
    Return an <OK: status> for the <startup>.
}
ARO

is detect_example_type('CommentedSocket'), 'console',
    'a comment mentioning the socket server does not make an example a socket test';

write_example('RealSocket', <<'ARO');
(Application-Start: Real) {
    Start the <socket-server> with <port>.
    Keepalive the <application> for the <events>.
}
ARO

is detect_example_type('RealSocket'), 'socket',
    'a real socket server is still detected';

write_example('RealFileWatcher', <<'ARO');
(Application-Start: Watcher) {
    (* Start the <socket-server> would be wrong here. *)
    Start the <file-monitor> with ".".
    Keepalive the <application> for the <events>.
}
ARO

is detect_example_type('RealFileWatcher'), 'file',
    'a file-monitor example is detected as file even next to a socket comment';
