package AROTest::Executor::Console;

use strict;
use warnings;
use v5.30;
use parent 'AROTest::Executor::Base';
use File::Spec;

=head1 NAME

AROTest::Executor::Console - Execute console/stdout ARO examples

=head1 SYNOPSIS

    use AROTest::Executor::Console;

    my $executor = AROTest::Executor::Console->new($config);
    my ($output, $error) = $executor->execute('/path/to/example', 10);

=head1 DESCRIPTION

Executes console-based ARO examples that output to stdout. These are simple
examples that run, produce output, and exit.

=cut

=head2 execute($example_dir, $timeout)

Execute a console example using C<aro run>.

Parameters:

=over 4

=item * C<$example_dir> - Path to example directory

=item * C<$timeout> - Timeout in seconds

=back

Returns: C<($output, $error)> where error is undef on success

=cut

sub execute {
    my ($self, $example_dir, $timeout) = @_;

    say "  Running: aro run $example_dir" if $self->verbose;

    my ($output, $error, $exit_code) = $self->run_aro_command($timeout, 'run', $example_dir);

    if (defined $error) {
        return (undef, $error);
    }

    if ($exit_code != 0) {
        return (undef, "Exit code: $exit_code\n$output");
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
