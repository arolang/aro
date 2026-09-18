package AROTest::Ports;

# Port allocation for examples that host a server.
#
# Under `--jobs > 1` the pool gives each forked worker an ARO_TEST_WORKER_ID
# of 0..jobs-1 (see Pool.pm) and every worker owns a 1000-wide lane:
#
#   worker N   ->   [30000 + N*1000, 30000 + N*1000 + 1000)
#                    HTTP from the lane base, socket from base + 500
#
# Two concurrent workers therefore cannot pick the same port, whatever
# Net::EmptyPort probes: only a same-worker race could remain, and a worker
# runs one example at a time. That is the #297 fix, which HTTP.pm had and the
# console executors did not -- they called bare `empty_port()`, which returns
# a port from the *ephemeral* range, where two workers probing at once can be
# handed the same number and the loser fails to bind (GitLab #597).
#
# In serial runs the canonical port is preferred instead, so a manual probe
# against 8080/9000 still works and observable output stays stable.

use strict;
use warnings;
use v5.30;
use Exporter 'import';

use AROTest::Config qw(%options);
use AROTest::Utils qw($has_net_emptyport);

our @EXPORT_OK = qw(http_port socket_port lane_base);

sub lane_base {
    return 30000 + (($ENV{ARO_TEST_WORKER_ID} // 0) * 1000);
}

# $canonical is the port to prefer when running serially: the contract's port
# for an HTTP example, 8080/9000 for a console one.
sub http_port {
    my ($canonical) = @_;
    return $canonical unless $has_net_emptyport;
    return $options{jobs} > 1
        ? Net::EmptyPort::empty_port(lane_base())
        : Net::EmptyPort::empty_port($canonical);
}

sub socket_port {
    my ($canonical) = @_;
    return $canonical unless $has_net_emptyport;
    return $options{jobs} > 1
        ? Net::EmptyPort::empty_port(lane_base() + 500)
        : Net::EmptyPort::empty_port($canonical);
}

1;
