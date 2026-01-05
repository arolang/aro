package AROTest::Discovery;

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(discover_examples read_test_hint);

=head1 NAME

AROTest::Discovery - Example discovery and test.hint parsing

=head1 SYNOPSIS

    use AROTest::Discovery qw(discover_examples read_test_hint);

    my @examples = discover_examples('/path/to/Examples');
    my $hints = read_test_hint('/path/to/example', $config);

=head1 DESCRIPTION

Discovers ARO example directories and parses test.hint configuration files.

=cut

=head2 discover_examples($examples_dir, $filter)

Discover all example directories in the examples directory.

Parameters:

=over 4

=item * C<$examples_dir> - Path to the Examples directory

=item * C<$filter> - Optional pattern to filter examples (regex)

=back

Returns: Sorted array of example names (excluding 'template' and hidden directories)

=cut

sub discover_examples {
    my ($examples_dir, $filter) = @_;

    opendir my $dh, $examples_dir or die "Cannot open $examples_dir: $!";
    my @examples = grep {
        -d File::Spec->catdir($examples_dir, $_) &&
        !/^\./ &&
        $_ ne 'template'
    } readdir $dh;
    closedir $dh;

    # Apply filter if provided
    if ($filter) {
        @examples = grep { /$filter/i } @examples;
    }

    return sort @examples;
}

=head2 read_test_hint($example_dir, $config)

Read test.hint file for an example if it exists.

Supported directives:

=over 4

=item * C<workdir> - Working directory for test execution

=item * C<timeout> - Override timeout in seconds

=item * C<type> - Test type (console|http|socket|file)

=item * C<skip> - Skip reason (if present, test is skipped)

=item * C<pre-script> - Shell script to run before test

=item * C<test-script> - Shell script to run instead of normal test

=item * C<occurrence-check> - Use occurrence-based matching

=back

Parameters:

=over 4

=item * C<$example_dir> - Path to the example directory

=item * C<$config> - AROTest::Config instance for verbose flag

=back

Returns: Hash reference with parsed directives (undef for absent values)

=cut

sub read_test_hint {
    my ($example_dir, $config) = @_;

    my $hint_file = File::Spec->catfile($example_dir, 'test.hint');
    my %hints = (
        workdir => undef,
        timeout => undef,
        type => undef,
        skip => undef,
        'pre-script' => undef,
        'test-script' => undef,
        'occurrence-check' => undef,
    );

    # Return empty hints if file doesn't exist (backward compatible)
    return \%hints unless -f $hint_file;

    open my $fh, '<', $hint_file or do {
        warn "Warning: Cannot read $hint_file: $!\n" if $config && $config->is_verbose;
        return \%hints;
    };

    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;

        # Strip whitespace
        chomp $line;
        $line =~ s/^\s+|\s+$//g;

        # Skip comments and blank lines
        next if !$line || $line =~ /^#/;

        # Parse key: value
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            my $key = lc $1;
            my $value = $2;

            # Strip value whitespace
            $value =~ s/^\s+|\s+$//g;

            # Validate and store
            if (exists $hints{$key}) {
                if (defined $hints{$key} && $config && $config->is_verbose) {
                    warn "Warning: $hint_file:$line_no duplicate key '$key' (overriding)\n";
                }
                $hints{$key} = $value;
            } elsif ($config && $config->is_verbose) {
                warn "Warning: $hint_file:$line_no unknown directive '$key'\n";
            }
        } elsif ($config && $config->is_verbose) {
            warn "Warning: $hint_file:$line_no malformed line (expected 'key: value'): $line\n";
        }
    }

    close $fh;

    # Validate values
    if (defined $hints{timeout} && $hints{timeout} !~ /^\d+$/) {
        warn "Warning: Invalid timeout value '$hints{timeout}' (must be integer), ignoring\n";
        $hints{timeout} = undef;
    }

    if (defined $hints{type} && $hints{type} !~ /^(console|http|socket|file)$/) {
        warn "Warning: Invalid type '$hints{type}' (must be console|http|socket|file), ignoring\n";
        $hints{type} = undef;
    }

    return \%hints;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
