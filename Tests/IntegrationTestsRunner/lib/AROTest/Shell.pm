package AROTest::Shell;

# Thin wrapper around IPC::Run for running shell snippets (pre-scripts, etc.)
# with a timeout. Returns (stdout, stderr, exit_code). On startup failure
# returns (undef, message, -1).

use strict;
use warnings;
use v5.30;
use IPC::Run qw(start timeout);
use Exporter 'import';

our @EXPORT_OK = qw(run_script);

sub run_script {
    my ($script, $timeout_secs, $context) = @_;

    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start(['sh', '-c', $script], \$in, \$out, \$err, timeout($timeout_secs));
    };

    if ($@) {
        return (undef, "Failed to start $context: $@", -1);
    }

    eval { $handle->finish; };
    my $exit_code = $? >> 8;
    return ($out, $err, $exit_code);
}

1;
