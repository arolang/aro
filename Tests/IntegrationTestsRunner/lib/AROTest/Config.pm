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
    detect_cpu_limit resolve_jobs
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

# How many CPUs this process may actually use.
#
# `nproc` is the wrong question inside a container: it reports the *node's*
# processors, so a 2-CPU pod on a 64-core node looks like 64 and any figure
# derived from it is nonsense. The cgroup quota is the real limit, so read
# that first and fall back to the visible count only when unconstrained
# (GitLab #597).
sub detect_cpu_limit {
    # cgroup v2: "<quota> <period>", or "max <period>" when unlimited.
    if (open my $fh, '<', '/sys/fs/cgroup/cpu.max') {
        my $line = <$fh>;
        close $fh;
        if (defined $line && $line =~ /^(\S+)\s+(\d+)/) {
            my ($quota, $period) = ($1, $2);
            if ($quota ne 'max' && $period > 0) {
                my $cpus = int($quota / $period);
                return $cpus > 0 ? $cpus : 1;
            }
        }
    }

    # cgroup v1: quota and period in separate files; -1 quota means unlimited.
    my $quota  = _read_int('/sys/fs/cgroup/cpu/cpu.cfs_quota_us');
    my $period = _read_int('/sys/fs/cgroup/cpu/cpu.cfs_period_us');
    if (defined $quota && defined $period && $quota > 0 && $period > 0) {
        my $cpus = int($quota / $period);
        return $cpus > 0 ? $cpus : 1;
    }

    # Unconstrained: the visible processor count.
    for my $cmd ('nproc 2>/dev/null', 'sysctl -n hw.ncpu 2>/dev/null') {
        my $out = `$cmd`;
        if (defined $out && $out =~ /(\d+)/ && $1 > 0) {
            return $1;
        }
    }
    return 1;
}

sub _read_int {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    chomp $line;
    return $line =~ /^-?\d+$/ ? $line + 0 : undef;
}

# Worker count for --jobs. A number is taken as given; "auto" is derived from
# the CPU limit above and clamped.
#
# The floor is 2 because the long tail of this suite is HTTP and socket
# examples that spend their time waiting on a port rather than on a CPU, so a
# single-CPU pod still gains from a second worker -- and because 2 is what CI
# used before, which nothing here should regress. The ceiling is 4 to keep the
# step modest: each worker can run `aro build`, and the value that is actually
# right depends on the pod, which this same run now reports.
our $JOBS_AUTO_FLOOR = 2;
our $JOBS_AUTO_CEILING = 4;

sub resolve_jobs {
    my ($requested) = @_;
    return (undef, "--jobs must be a positive integer or \"auto\"")
        unless defined $requested;

    if (lc($requested) eq 'auto') {
        my $cpus = detect_cpu_limit();
        my $jobs = $cpus;
        $jobs = $JOBS_AUTO_FLOOR   if $jobs < $JOBS_AUTO_FLOOR;
        $jobs = $JOBS_AUTO_CEILING if $jobs > $JOBS_AUTO_CEILING;
        return ($jobs, undef, $cpus);
    }

    return (undef, "--jobs must be a positive integer or \"auto\" (got $requested)")
        unless $requested =~ /^\d+$/ && $requested >= 1;

    return ($requested + 0, undef, undef);
}

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
