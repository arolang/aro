package AROTest::Generation;

use strict;
use warnings;
use v5.30;
use File::Spec;
use AROTest::Discovery qw(read_test_hint);
use AROTest::TypeDetection qw(detect_type);
use AROTest::Comparison::Normalization qw(normalize_output);
use AROTest::Comparison::Matching qw(auto_placeholderize);
use AROTest::Utils qw(colored);
use Exporter 'import';

our @EXPORT_OK = qw(generate_expected generate_all_expected);

=head1 NAME

AROTest::Generation - Generate expected.txt files for ARO examples

=head1 SYNOPSIS

    use AROTest::Generation qw(generate_expected generate_all_expected);

    generate_expected('HelloWorld', $runner, $config);
    generate_all_expected(\@examples, $runner, $config);

=head1 DESCRIPTION

Generates expected.txt files by running examples and capturing their output.
Applies normalization and auto-placeholderization to make tests resilient.

=cut

=head2 generate_expected($example_name, $runner, $config)

Generate expected.txt for a single example.

Parameters:

=over 4

=item * C<$example_name> - Name of the example

=item * C<$runner> - AROTest::Runner instance

=item * C<$config> - AROTest::Config instance

=back

=cut

sub generate_expected {
    my ($example_name, $runner, $config) = @_;

    my $examples_dir = $config->examples_dir;
    my $dir = File::Spec->catdir($examples_dir, $example_name);

    # Read test hints
    my $hints = read_test_hint($dir, $config);

    # Skip if requested
    if (defined $hints->{skip}) {
        say "Skipping $example_name: $hints->{skip}";
        return;
    }

    # Determine type and timeout
    my $type = $hints->{type} || detect_type($dir);
    my $timeout = $hints->{timeout} // $config->timeout;

    my $expected_file = File::Spec->catfile($dir, 'expected.txt');

    say "Generating expected output for $example_name ($type)...";

    # Execute the example
    my $executor = $runner->{executors}{$type};
    unless ($executor) {
        warn colored("  ✗ Failed: Unknown test type: $type\n", 'red');
        return;
    }

    my ($output, $error) = $executor->execute($dir, $timeout);

    if ($error) {
        warn colored("  ✗ Failed: $error\n", 'red');
        return;
    }

    # Normalize output before saving
    $output = normalize_output($output, $type);

    # Auto-replace dynamic values with placeholders
    $output = auto_placeholderize($output, $type);

    # Write with enhanced metadata header
    open my $fh, '>', $expected_file or die "Cannot write $expected_file: $!";
    print $fh "# Generated: " . localtime() . "\n";
    print $fh "# Type: $type\n";
    print $fh "# Command: aro run ./Examples/$example_name\n";

    # Add note if test-script is used
    if (defined $hints->{'test-script'}) {
        print $fh "# NOTE: This example uses test-script for verification\n";
        print $fh "# This expected.txt is for reference only, not used in testing\n";
    }

    # Add optional metadata from hints
    if (defined $hints->{workdir}) {
        print $fh "# Workdir: $hints->{workdir}\n";
    }

    if (defined $hints->{timeout} && $hints->{timeout} != $config->timeout) {
        print $fh "# Timeout: $hints->{timeout}s\n";
    }

    print $fh "---\n";
    print $fh $output;
    close $fh;

    say colored("  ✓ Generated $expected_file\n", 'green');
}

=head2 generate_all_expected(\@examples, $runner, $config)

Generate expected.txt files for multiple examples.

Parameters:

=over 4

=item * C<\@examples> - Array reference of example names

=item * C<$runner> - AROTest::Runner instance

=item * C<$config> - AROTest::Config instance

=back

=cut

sub generate_all_expected {
    my ($examples, $runner, $config) = @_;

    my $total = scalar @$examples;
    my $current = 0;

    for my $example (@$examples) {
        $current++;
        say sprintf("[%d/%d] %s", $current, $total, $example);

        eval {
            generate_expected($example, $runner, $config);
        };
        if ($@) {
            warn colored("  ✗ Error: $@\n", 'red');
        }

        # Prevent overwhelming the system
        sleep 0.5;
    }

    say "\nGeneration complete. $current expected files created/updated.";
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
