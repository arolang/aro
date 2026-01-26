package AROTest::Executor::Console;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';
use File::Spec;
use POSIX qw(:signal_h);

=head1 NAME

AROTest::Executor::Console - Execute console/stdout ARO examples

=head1 SYNOPSIS

    use AROTest::Executor::Console;

    my $executor = AROTest::Executor::Console->new($config);
    my ($output, $error) = $executor->execute('/path/to/example', 10);

=head1 DESCRIPTION

Executes console-based ARO examples that output to stdout. These are simple
examples that run, produce output, and exit.

Supports C<keep-alive> hint for long-running applications that need SIGINT
for graceful shutdown, and C<allow-error> hint for tests expecting non-zero
exit codes.

=cut

=head2 execute($example_dir, $timeout, $hints)

Execute a console example using C<aro run>.

Parameters:

=over 4

=item * C<$example_dir> - Path to example directory

=item * C<$timeout> - Timeout in seconds

=item * C<$hints> - Optional hints hash reference (from test.hint)

=back

Returns: C<($output, $error)> where error is undef on success

=cut

sub execute {
    my ($self, $example_dir, $timeout, $hints) = @_;

    my $keep_alive = $hints && $hints->{'keep-alive'};
    my $allow_error = $hints && $hints->{'allow-error'};

    if ($keep_alive) {
        say "  Running: aro run --keep-alive $example_dir (with SIGINT after 1s)" if $self->verbose;
        return $self->_execute_keep_alive($example_dir, $timeout);
    }

    say "  Running: aro run $example_dir" if $self->verbose;

    my ($output, $error, $exit_code) = $self->run_aro_command($timeout, 'run', $example_dir);

    if (defined $error) {
        return (undef, $error);
    }

    if ($exit_code != 0 && !$allow_error) {
        return (undef, "Exit code: $exit_code\n$output");
    }

    return ($output, undef);
}

=head2 _execute_keep_alive($example_dir, $timeout)

Execute with --keep-alive flag and send SIGINT after 1 second for graceful
shutdown. Used for testing Application-End handlers.

=cut

sub _execute_keep_alive {
    my ($self, $example_dir, $timeout) = @_;

    unless ($self->{has_ipc_run}) {
        return (undef, "IPC::Run required for keep-alive tests");
    }

    require IPC::Run;

    my $aro_bin = AROTest::Binary::Locator::find_aro_binary();
    my ($in, $out, $err) = ('', '', '');

    my $handle = eval {
        IPC::Run::start(
            [$aro_bin, 'run', '--keep-alive', $example_dir],
            \$in, \$out, \$err,
            IPC::Run::timeout($timeout)
        );
    };

    if ($@) {
        return (undef, "Failed to start: $@");
    }

    # Wait for the application to start, then send SIGINT
    sleep 1;
    IPC::Run::signal($handle, 'INT');

    eval { IPC::Run::finish($handle); };

    # Combine stdout and stderr
    my $output = $out;
    $output .= $err if $err;

    if ($@ && $@ =~ /timeout/) {
        IPC::Run::kill_kill($handle);
        return (undef, "TIMEOUT after ${timeout}s");
    }

    return ($output, undef);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
