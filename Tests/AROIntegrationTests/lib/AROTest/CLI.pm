package AROTest::CLI;

use strict;
use warnings;
use v5.30;
use Getopt::Long;
use Exporter 'import';

our @EXPORT_OK = qw(parse_args print_usage);

=head1 NAME

AROTest::CLI - Command-line interface for ARO integration tests

=head1 SYNOPSIS

    use AROTest::CLI qw(parse_args print_usage);

    my ($options, $filters) = parse_args(@ARGV);
    print_usage() if $options->{help};

=head1 DESCRIPTION

Handles command-line argument parsing for the ARO test framework.

=cut

=head2 parse_args(@args)

Parse command-line arguments and return options hash and filter list.

Returns: C<(\%options, \@example_filters)>

Options hash contains:

=over 4

=item * C<generate> - Generate expected.txt files (boolean)

=item * C<verbose> - Verbose output (boolean)

=item * C<timeout> - Timeout in seconds (integer, default: 10)

=item * C<filter> - Filter pattern for examples (string)

=item * C<help> - Show help (boolean)

=back

=cut

sub parse_args {
    my @args = @_;

    my %options = (
        generate => 0,
        verbose => 0,
        timeout => 10,
        filter => '',
        help => 0,
    );

    local @ARGV = @args;
    GetOptions(
        'generate' => \$options{generate},
        'verbose|v' => \$options{verbose},
        'timeout=i' => \$options{timeout},
        'filter=s' => \$options{filter},
        'help|h' => \$options{help},
    ) or die "Invalid options. Use --help for usage.\n";

    # Remaining arguments are example filters
    my @filters = @ARGV;

    return (\%options, \@filters);
}

=head2 print_usage()

Print usage information and exit.

=cut

sub print_usage {
    print <<'USAGE';
ARO Examples Test Harness

Usage:
    ./run-tests.pl [OPTIONS] [EXAMPLE]

Options:
    --generate          Generate expected.txt files for all examples
    -v, --verbose       Show detailed output
    --timeout=N         Timeout in seconds for long-running examples (default: 10)
    --filter=PATTERN    Test only examples matching pattern
    -h, --help          Show this help

Examples:
    # Generate all expected outputs
    ./run-tests.pl --generate

    # Run all tests
    ./run-tests.pl

    # Test only HTTP examples
    ./run-tests.pl --filter=HTTP

    # Test single example
    ./run-tests.pl HelloWorld

    # Verbose mode
    ./run-tests.pl --verbose

Required Perl Modules:
    IPC::Run           - Process management (recommended)
    YAML::XS           - OpenAPI parsing (for HTTP tests)
    HTTP::Tiny         - HTTP client (for HTTP tests)
    Net::EmptyPort     - Port detection (for HTTP/socket tests)
    Term::ANSIColor    - Colored output (optional)

Install with: cpan -i IPC::Run YAML::XS HTTP::Tiny Net::EmptyPort Term::ANSIColor
USAGE
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
