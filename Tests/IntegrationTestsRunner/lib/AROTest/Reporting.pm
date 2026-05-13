package AROTest::Reporting;

# Result formatting, summary table, and on-disk failure diffs.
#
# The summary table layout — 120-char separator, "Example | Type | Interpreter
# | Binary | Avg Duration" columns — is part of the harness's public contract:
# CI logs and READMEs grep for it. Preserve exact widths/padding.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Temp ();
use Exporter 'import';

use AROTest::Utils qw(colored);
use AROTest::Config qw(%options $examples_dir);

our @EXPORT_OK = qw(
    format_status print_summary _emit_result_line
    create_temp_files create_diff_file
);

# Status string + colour. N/A stays uncoloured so it visually recedes.
sub format_status {
    my ($status) = @_;
    return 'N/A' if $status eq 'N/A';

    my %colors = (
        PASS  => 'green',
        FAIL  => 'red',
        SKIP  => 'yellow',
        ERROR => 'red',
    );
    return colored($status, $colors{$status} // 'white');
}

# Pad a string to $width VISIBLE columns. ANSI colour escapes don't take up
# screen space but they make a string longer in bytes, so the built-in `%-Ns`
# padding misaligns coloured cells against uncoloured ones (notably N/A).
sub _pad_visible {
    my ($s, $width) = @_;
    (my $bare = $s) =~ s/\e\[[0-9;]*m//g;
    my $extra = $width - length($bare);
    return $extra > 0 ? $s . (' ' x $extra) : $s;
}

# One-line "[N/total] Example... STATUS" emitted as each test completes when
# not running --verbose. Returns 1 if the result counts as a failure (used
# by the caller to track exit code).
sub _emit_result_line {
    my ($index, $total, $result) = @_;
    my $status = $result->{status};
    my $color  = $status eq 'PASS' ? 'green'
               : $status eq 'SKIP' ? 'yellow'
               :                     'red';
    print sprintf("[%d/%d] %s... ", $index, $total, $result->{name});
    say colored($status, $color);
    return ($status eq 'FAIL' || $status eq 'ERROR') ? 1 : 0;
}

# Wide summary table + aggregate counts. The 120-char ruler and 30/8/12/12/12
# column widths are deliberate — CI grep relies on them.
sub print_summary {
    my ($results, $duration) = @_;

    my $total   = scalar @$results;
    my $passed  = grep { $_->{status} eq 'PASS' } @$results;
    my $failed  = grep { $_->{status} ne 'PASS' && $_->{status} ne 'SKIP' } @$results;
    my $skipped = grep { $_->{status} eq 'SKIP' } @$results;

    print "\n";
    print "=" x 120 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 120 . "\n";
    printf "%-30s | %-13s | %-12s | %-12s | %-12s\n",
        "Example", "Type", "Interpreter", "Binary", "Avg Duration";
    print "-" x 120 . "\n";

    for my $result (@$results) {
        printf "%-30s | %-13s | %s | %s | %.2fs\n",
            $result->{name},
            $result->{type},
            _pad_visible(format_status($result->{interpreter_status}), 12),
            _pad_visible(format_status($result->{compiled_status}),    12),
            $result->{avg_duration};
    }

    print "=" x 120 . "\n";
    printf "SUMMARY: %d/%d passed (%.1f%%)\n",
        $passed, $total, $total ? 100 * $passed / $total : 0;
    print "  Passed:  " . colored($passed, 'green') . "\n";
    print "  Failed:  " . colored($failed, $failed > 0 ? 'red' : 'green') . "\n";
    print "  Skipped: " . colored($skipped, 'yellow') . "\n";
    printf "  Duration: %.2fs\n", $duration;
    print "=" x 120 . "\n";
}

# Write the expected/actual blobs to side-by-side temp files for `diff -u`.
sub create_temp_files {
    my ($result) = @_;
    my $temp_expected = File::Temp->new(SUFFIX => '.expected.txt', UNLINK => 0);
    my $temp_actual   = File::Temp->new(SUFFIX => '.actual.txt',   UNLINK => 0);
    print $temp_expected $result->{expected};
    print $temp_actual   $result->{actual};
    close $temp_expected;
    close $temp_actual;
    return ($temp_expected->filename, $temp_actual->filename);
}

# Drop unified diffs into the example dir for failed tests. Dual-mode aware:
# `expected.diff` for interpreter failures, `expected.binary.diff` for compiled
# failures. CI artifact upload picks these up automatically.
sub create_diff_file {
    my ($result) = @_;
    return unless $result->{status} eq 'FAIL';

    my $example_name = $result->{name};

    # Interpreter failure
    if ($result->{interpreter_status} && $result->{interpreter_status} eq 'FAIL'
        && $result->{interpreter_expected} && $result->{interpreter_actual}) {
        my $diff_file = File::Spec->catfile($examples_dir, $example_name, 'expected.diff');
        my $temp_result = {
            expected => $result->{interpreter_expected},
            actual   => $result->{interpreter_actual},
        };
        my ($temp_expected, $temp_actual) = create_temp_files($temp_result);
        my $diff_output = `diff -u "$temp_expected" "$temp_actual" 2>&1`;
        if (open my $fh, '>', $diff_file) {
            print $fh $diff_output;
            close $fh;
            print "  Created interpreter diff: $diff_file\n" if $options{verbose};
        }
        unlink $temp_expected, $temp_actual;
    }

    # Compiled-binary failure
    if ($result->{compiled_status} && $result->{compiled_status} eq 'FAIL'
        && $result->{compiled_expected} && $result->{compiled_actual}) {
        my $diff_file = File::Spec->catfile($examples_dir, $example_name, 'expected.binary.diff');
        my $temp_result = {
            expected => $result->{compiled_expected},
            actual   => $result->{compiled_actual},
        };
        my ($temp_expected, $temp_actual) = create_temp_files($temp_result);
        my $diff_output = `diff -u "$temp_expected" "$temp_actual" 2>&1`;
        if (open my $fh, '>', $diff_file) {
            print $fh $diff_output;
            close $fh;
            print "  Created binary diff: $diff_file\n" if $options{verbose};
        }
        unlink $temp_expected, $temp_actual;
    }
}

1;
