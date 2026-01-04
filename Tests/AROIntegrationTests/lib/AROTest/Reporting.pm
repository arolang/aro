package AROTest::Reporting;

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use File::Temp;
use AROTest::Utils qw(colored);
use Exporter 'import';

our @EXPORT_OK = qw(print_summary create_diff_file colored_status);

=head1 NAME

AROTest::Reporting - Test result reporting and diff generation

=head1 SYNOPSIS

    use AROTest::Reporting qw(print_summary create_diff_file);

    print_summary(\@results, $duration);
    create_diff_file($result, 'expected.build.diff');

=head1 DESCRIPTION

Provides formatted output for test results including summaries,
statistics, and diff file generation.

=cut

=head2 colored_status($status)

Return colored status string.

Parameters:

=over 4

=item * C<$status> - Status string (PASS, FAIL, ERROR, SKIP)

=back

Returns: Colored status string

=cut

sub colored_status {
    my ($status) = @_;
    return colored('PASS', 'green') if $status eq 'PASS';
    return colored('FAIL', 'red') if $status eq 'FAIL';
    return colored('ERROR', 'red') if $status eq 'ERROR';
    return colored('SKIP', 'yellow') if $status eq 'SKIP';
    return $status;
}

=head2 print_summary(\@results, $duration)

Print formatted test summary with statistics.

Parameters:

=over 4

=item * C<\@results> - Array reference of test results

=item * C<$duration> - Total duration in seconds

=back

=cut

sub print_summary {
    my ($results, $duration) = @_;

    # Count results for both phases
    my ($run_pass, $run_fail, $build_pass, $build_fail) = (0, 0, 0, 0);
    my ($skip, $run_err, $build_err) = (0, 0, 0);

    for my $r (@$results) {
        $skip++ if $r->{run_status} eq 'SKIP';

        # Run phase
        $run_pass++ if $r->{run_status} eq 'PASS';
        $run_fail++ if $r->{run_status} eq 'FAIL';
        $run_err++ if $r->{run_status} eq 'ERROR';

        # Build phase
        $build_pass++ if $r->{build_status} eq 'PASS';
        $build_fail++ if $r->{build_status} eq 'FAIL';
        $build_err++ if $r->{build_status} eq 'ERROR';
    }

    # Header
    print "\n";
    print "=" x 100 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 100 . "\n";
    printf "%-30s | %-8s | %-11s | %-12s | %s\n",
        "Example", "Type", "Status Run", "Status Build", "Duration";
    print "-" x 100 . "\n";

    # Results table
    for my $r (sort { $a->{name} cmp $b->{name} } @$results) {
        printf "%-30s | %-8s | %-11s | %-12s | %.2fs\n",
            $r->{name},
            $r->{type} // 'UNKNOWN',
            colored_status($r->{run_status}),
            colored_status($r->{build_status}),
            $r->{total_duration};
    }

    print "=" x 100 . "\n";

    # Statistics
    my $total = @$results;
    my $tested = $total - $skip;
    printf "SUMMARY: Run: %d/%d (%.1f%%), Build: %d/%d (%.1f%%)\n",
        $run_pass, $tested, ($tested ? 100.0 * $run_pass / $tested : 0),
        $build_pass, $tested, ($tested ? 100.0 * $build_pass / $tested : 0);

    print "  Run Phase:\n";
    print "    Passed:  " . colored($run_pass, 'green') . "\n";
    print "    Failed:  " . colored($run_fail, 'red') . "\n";
    print "    Errors:  " . colored($run_err, 'red') . "\n";

    print "  Build Phase:\n";
    print "    Passed:  " . colored($build_pass, 'green') . "\n";
    print "    Failed:  " . colored($build_fail, 'red') . "\n";
    print "    Errors:  " . colored($build_err, 'red') . "\n";

    print "  Skipped: " . colored($skip, 'yellow') . "\n";
    printf "  Duration: %.2fs\n", $duration;
    print "=" x 100 . "\n";
}

=head2 create_diff_file($result, $diff_filename)

Create a diff file for a failed test.

Parameters:

=over 4

=item * C<$result> - Test result hash

=item * C<$diff_filename> - Diff filename (e.g., 'expected.run.diff')

=back

=cut

sub create_diff_file {
    my ($result, $diff_filename) = @_;

    # Only create diff for failures with expected/actual data
    return unless $result->{status} eq 'FAIL';
    return unless $result->{expected} && $result->{actual};

    # Determine diff file path
    my $expected_file = $result->{expected_file} || '';
    return unless $expected_file && -f $expected_file;

    my $diff_file;
    if ($diff_filename) {
        # Use custom filename (e.g., expected.run.diff, expected.build.diff)
        my $dir = File::Basename::dirname($expected_file);
        $diff_file = File::Spec->catfile($dir, $diff_filename);
    } else {
        # Default: expected.diff
        $diff_file = $expected_file;
        $diff_file =~ s/expected\.txt$/expected.diff/;
    }

    # Create temporary files for diff command
    my ($temp_expected, $temp_actual) = _create_temp_files($result);

    # Generate unified diff
    my $diff_output = `diff -u "$temp_expected" "$temp_actual" 2>&1`;

    # Write diff to file
    open my $fh, '>', $diff_file or do {
        warn "Failed to create diff file: $diff_file: $!\n";
        unlink $temp_expected, $temp_actual;
        return;
    };

    print $fh $diff_output;
    close $fh;

    # Cleanup temp files
    unlink $temp_expected, $temp_actual;
}

# Create temporary files for diff comparison
sub _create_temp_files {
    my ($result) = @_;

    my $temp_expected = File::Temp->new(SUFFIX => '.expected.txt', UNLINK => 0);
    my $temp_actual = File::Temp->new(SUFFIX => '.actual.txt', UNLINK => 0);

    print $temp_expected $result->{expected};
    print $temp_actual $result->{actual};

    close $temp_expected;
    close $temp_actual;

    return ($temp_expected->filename, $temp_actual->filename);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
