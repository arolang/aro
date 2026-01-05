#!/usr/bin/env perl
# =============================================================================
# test-examples.pl - Compatibility Wrapper
# =============================================================================
# This is a compatibility wrapper for the new modular test framework.
# The actual implementation is in Tests/AROIntegrationTests/run-tests.pl
#
# This wrapper allows existing CI/CD pipelines and scripts to continue working
# without modification while using the improved modular architecture.
#
# For new usage, prefer calling the modular framework directly:
#   cd Tests/AROIntegrationTests && ./run-tests.pl [options]
# =============================================================================

use strict;
use warnings;
use FindBin qw($RealBin);
use Cwd qw(abs_path);

# Change to the modular framework directory
my $framework_dir = "$RealBin/Tests/AROIntegrationTests";
unless (-d $framework_dir) {
    die "ERROR: Modular framework directory not found: $framework_dir\n" .
        "Expected location: Tests/AROIntegrationTests/\n";
}

chdir $framework_dir or die "Cannot change to $framework_dir: $!\n";

# Execute the modular test framework with all original arguments
exec './run-tests.pl', @ARGV or die "Cannot execute run-tests.pl: $!\n";
