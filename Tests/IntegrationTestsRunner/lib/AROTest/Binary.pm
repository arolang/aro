package AROTest::Binary;

# Locating the aro binary and producing a compiled example via `aro build`.
# Search order matches what test-examples.pl had: $ARO_BIN env var, project
# release build, system installs, ./aro-bin (CI), then PATH fallback.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Time::HiRes qw(time);
use IPC::Run qw(start finish timeout);
use Exporter 'import';

use AROTest::Utils qw($is_windows is_executable get_binary_path);
use AROTest::Config qw($examples_dir $project_root);
use AROTest::Hint qw(write_testrun_log);

our @EXPORT_OK = qw(find_aro_binary build_example);

sub find_aro_binary {
    my $exe_ext = $is_windows ? '.exe' : '';

    # 1. $ARO_BIN trumps everything — CI sets this to a known-good build.
    if ($ENV{ARO_BIN} && is_executable($ENV{ARO_BIN})) {
        return $ENV{ARO_BIN};
    }

    # 2. Local release build (most up-to-date during development).
    my $local_release = File::Spec->catfile($project_root, '.build', 'release', "aro$exe_ext");
    return $local_release if is_executable($local_release);

    if (!$is_windows) {
        # 3. System install.
        return '/usr/bin/aro'        if -x '/usr/bin/aro';
        # 4. Homebrew on Apple Silicon.
        return '/opt/homebrew/bin/aro' if -x '/opt/homebrew/bin/aro';
    }

    # 5. CI-style local binary directory.
    my $local_bin = File::Spec->catfile($project_root, 'aro-bin', "aro$exe_ext");
    return $local_bin if is_executable($local_bin);

    # 6. PATH fallback.
    my $which_cmd = $is_windows ? "where aro$exe_ext 2>nul" : "which aro 2>/dev/null";
    my $which_aro = `$which_cmd`;
    chomp $which_aro;
    # `where` on Windows can return multiple lines.
    ($which_aro) = split /\n/, $which_aro if $which_aro;
    return $which_aro if $which_aro && is_executable($which_aro);

    return 'aro';
}

# Compile an example with `aro build` and return a result hashref:
#   { success => 1, binary_path => ..., duration => ... }   on success
#   { success => 0, error => ..., duration => ... }         on failure
# Failures also append a structured entry to the example's testrun.log.
sub build_example {
    my ($example_name, $timeout, $workdir) = @_;

    my $dir;
    if (defined $workdir) {
        $dir = File::Spec->file_name_is_absolute($workdir)
            ? $workdir
            : File::Spec->catdir($project_root, $workdir);
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $aro_bin = find_aro_binary();
    my $start_time = time;

    # --keep-intermediate preserves LLVM IR so CI can publish it for debugging.
    my ($in, $out, $err) = ('', '', '');
    my $handle = eval {
        start([$aro_bin, 'build', $dir, '--keep-intermediate'],
              \$in, \$out, \$err, timeout($timeout));
    };

    if ($@) {
        my $error_msg = "Build failed to start: $@";
        write_testrun_log($example_name, 'compiled', 'BUILD_START_FAILURE',
                          $error_msg, "$aro_bin build $dir", undef);
        return { success => 0, error => $error_msg, duration => 0 };
    }

    eval { finish($handle) };
    my $build_duration = time - $start_time;

    if ($? != 0) {
        my $combined_err = ($err && $out) ? "$err\n$out" : ($err || $out);
        my $exit_code = $? >> 8;
        my $error_msg = "Build failed: $combined_err";
        write_testrun_log($example_name, 'compiled', 'BUILD_FAILURE',
                          $error_msg, "$aro_bin build $dir", $exit_code);
        return { success => 0, error => $error_msg, duration => $build_duration };
    }

    my $basename = basename($dir);
    my $binary_path = get_binary_path($dir, $basename);

    unless (is_executable($binary_path)) {
        my $build_output = $out || $err || "(no output)";
        my $error_msg = "Binary not found at: $binary_path\n\nBuild output:\n$build_output";
        write_testrun_log($example_name, 'compiled', 'BINARY_NOT_FOUND',
                          $error_msg, "$aro_bin build $dir", 0);
        return { success => 0, error => $error_msg, duration => $build_duration };
    }

    return { success => 1, binary_path => $binary_path, duration => $build_duration };
}

1;
