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
    # `aro build` gets its own budget, separate from the run timeout.
    #
    # Compiling an example is not the same kind of work as running one, and
    # bounding both with 60s made a loaded runner look like a broken change:
    # three unrelated merge requests failed `integration:linux` on the same
    # day with `RecursiveActions … ERROR`, which is the build-failed branch
    # (GitLab #592). That example builds in 0.8s locally.
    #
    # 300s is chosen to be far above any honest build and still catch a
    # genuinely hung one. A build that takes five minutes is worth failing;
    # one that takes ninety seconds on a busy runner is not a defect in
    # whichever merge request happened to be queued at the time.
    build_timeout => 300,
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
