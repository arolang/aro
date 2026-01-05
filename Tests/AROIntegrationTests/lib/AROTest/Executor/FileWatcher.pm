package AROTest::Executor::FileWatcher;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';

=head1 NAME

AROTest::Executor::FileWatcher - Execute file watcher ARO examples

=head1 SYNOPSIS

    use AROTest::Executor::FileWatcher;

    my $executor = AROTest::Executor::FileWatcher->new($config);
    my ($output, $error) = $executor->execute('/path/to/example', 10);

=head1 DESCRIPTION

Executes file watcher ARO examples by:
1. Starting the file watcher
2. Creating/modifying/deleting test files
3. Capturing watcher output
4. Cleanup

=cut

=head2 execute($example_dir, $timeout)

Execute a file watcher example.

Parameters:

=over 4

=item * C<$example_dir> - Path to example directory

=item * C<$timeout> - Timeout in seconds

=back

Returns: C<($output, $error)> where error is undef on success

=cut

sub execute {
    my ($self, $example_dir, $timeout) = @_;

    unless ($self->{has_ipc_run}) {
        return (undef, "SKIP: Missing required module (IPC::Run)");
    }

    my $test_file = "/tmp/aro_test_$$.txt";

    say "  Starting file watcher" if $self->verbose;

    # Start watcher
    my $aro_bin = AROTest::Binary::Locator::find_aro_binary();
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start([$aro_bin, 'run', $example_dir], \$in, \$out, \$err, IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start file watcher: $@");
    }

    # Register cleanup
    my $cleanup = sub {
        eval {
            kill 'TERM', $handle->pid if $handle->pumpable;
            sleep 0.5;
            IPC::Run::kill_kill($handle) if $handle->pumpable;
            unlink $test_file if -f $test_file;
        };
    };
    $self->config->add_cleanup_handler($cleanup);

    # Wait for startup
    sleep 2;

    say "  Performing file operations" if $self->verbose;

    # Create file
    system("touch $test_file");
    sleep 1;

    # Modify file
    system("echo 'test' >> $test_file");
    sleep 1;

    # Delete file
    unlink $test_file;
    sleep 1;

    # Capture output
    eval { IPC::Run::finish($handle, IPC::Run::timeout(2)) };

    # Cleanup
    $cleanup->();

    return ($out, undef);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
