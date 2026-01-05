package AROTest::Executor::Base;

use strict;
use warnings;
use v5.30;
use File::Spec;
use AROTest::Binary::Locator qw(find_aro_binary);

=head1 NAME

AROTest::Executor::Base - Base class for test executors

=head1 SYNOPSIS

    package AROTest::Executor::MyExecutor;
    use parent 'AROTest::Executor::Base';

    sub execute {
        my ($self, $example_dir, $timeout) = @_;
        # Implementation
        return ($output, $error);
    }

=head1 DESCRIPTION

Base class for all test executors. Provides common functionality for
running ARO examples with different execution strategies (console, HTTP,
socket, file watcher).

=cut

=head2 new($config)

Create a new executor instance.

Parameters:

=over 4

=item * C<$config> - AROTest::Config instance

=back

=cut

sub new {
    my ($class, $config) = @_;

    my $self = bless {
        config => $config,
        has_ipc_run => eval { require IPC::Run; 1; } || 0,
    }, $class;

    return $self;
}

=head2 execute($example_dir, $timeout)

Execute the example and return output. Must be implemented by subclasses.

Parameters:

=over 4

=item * C<$example_dir> - Path to example directory

=item * C<$timeout> - Timeout in seconds

=back

Returns: C<($output, $error)> where error is undef on success

=cut

sub execute {
    my ($self, $example_dir, $timeout) = @_;
    die "execute() must be implemented by subclass";
}

=head2 run_aro_command(@args)

Run an aro command with IPC::Run if available, otherwise fallback to system().

Parameters:

=over 4

=item * C<@args> - Arguments to pass to aro (e.g., 'run', 'build', 'check')

=back

Returns: C<($output, $error, $exit_code)>

=cut

sub run_aro_command {
    my ($self, $timeout, @args) = @_;

    my $aro_bin = find_aro_binary();

    if ($self->{has_ipc_run}) {
        my ($in, $out, $err) = ('', '', '');
        my $handle = eval {
            IPC::Run::start([$aro_bin, @args], \$in, \$out, \$err, IPC::Run::timeout($timeout));
        };

        if ($@) {
            return (undef, "Failed to start: $@", -1);
        }

        eval {
            IPC::Run::finish($handle);
        };

        my $exit_code = $? >> 8;

        if ($@) {
            if ($@ =~ /timeout/) {
                IPC::Run::kill_kill($handle);
                return (undef, "TIMEOUT after ${timeout}s", -1);
            }
            return (undef, "ERROR: $@", $exit_code);
        }

        # Combine stdout and stderr
        my $output = $out;
        $output .= $err if $err;

        return ($output, undef, $exit_code);
    } else {
        # Fallback to system()
        my $cmd = join(' ', $aro_bin, @args);
        my $output = `$cmd 2>&1`;
        my $exit_code = $? >> 8;

        if ($exit_code != 0) {
            return ($output, "Exit code: $exit_code", $exit_code);
        }

        return ($output, undef, 0);
    }
}

=head2 run_script($script, $timeout, $context)

Run a shell script with timeout support.

Parameters:

=over 4

=item * C<$script> - Shell script to execute

=item * C<$timeout> - Timeout in seconds

=item * C<$context> - Description of script (for error messages)

=back

Returns: C<($output, $error, $exit_code)>

=cut

sub run_script {
    my ($self, $script, $timeout, $context) = @_;

    unless ($self->{has_ipc_run}) {
        return (undef, "IPC::Run module not available", -1);
    }

    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        IPC::Run::start(['sh', '-c', $script], \$in, \$out, \$err,
                       IPC::Run::timeout($timeout));
    };

    if ($@) {
        return (undef, "Failed to start $context: $@", -1);
    }

    eval { $handle->finish; };
    my $exit_code = $? >> 8;

    return ($out, $err, $exit_code);
}

=head2 config()

Get the configuration object.

=cut

sub config {
    my ($self) = @_;
    return $self->{config};
}

=head2 verbose()

Check if verbose mode is enabled.

=cut

sub verbose {
    my ($self) = @_;
    return $self->{config}->is_verbose;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
