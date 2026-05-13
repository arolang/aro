package AROTest::Config;

# Shared runtime state for the test harness: parsed CLI options, resolved paths,
# accumulated results, signal-cleanup handlers. Modules import these as needed
# rather than reaching into main::. The main runner is responsible for calling
# init() once after CLI parsing.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Cwd qw(abs_path);
use Exporter 'import';

our @EXPORT_OK = qw(
    %options $examples_dir $project_root %results @cleanup_handlers
    init_paths register_cleanup install_signal_handlers
);

# Populated by the main runner via init_paths() after Getopt::Long parses argv.
our %options = (
    generate => 0,
    verbose  => 0,
    timeout  => 60,
    filter   => '',
    jobs     => 1,
    help     => 0,
);

our $examples_dir;   # absolute path to Examples/
our $project_root;   # absolute path to the project (parent of Tests/)
our %results;        # accumulated test results, keyed by example name
our @cleanup_handlers;  # subs to run on SIGINT/SIGTERM

# Resolve project paths from the harness's location (Tests/IntegrationTestsRunner/).
sub init_paths {
    my ($real_bin) = @_;
    $project_root = abs_path(File::Spec->catdir($real_bin, '..', '..'))
        // die "Cannot resolve project root from $real_bin\n";
    $examples_dir = File::Spec->catdir($project_root, 'Examples');
    return ($project_root, $examples_dir);
}

sub register_cleanup {
    my ($sub) = @_;
    push @cleanup_handlers, $sub;
}

sub install_signal_handlers {
    $SIG{INT} = $SIG{TERM} = sub {
        warn "\nCaught signal, cleaning up...\n";
        $_->() for @cleanup_handlers;
        exit 1;
    };
}

1;
