package AROTest::Binary::Locator;

use strict;
use warnings;
use v5.30;
use FindBin qw($RealBin);
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(find_aro_binary find_example_binary);

=head1 NAME

AROTest::Binary::Locator - Locate ARO binaries and compiled examples

=head1 SYNOPSIS

    use AROTest::Binary::Locator qw(find_aro_binary find_example_binary);

    my $aro = find_aro_binary();
    my $example_bin = find_example_binary('HelloWorld', '/path/to/example');

=head1 DESCRIPTION

Locates the ARO CLI binary and compiled example binaries. Searches in
multiple standard locations to support both local development and CI environments.

=cut

=head2 find_aro_binary()

Find the ARO CLI binary. Searches in order:

=over 4

=item 1. C<which aro> - System PATH (for installed/CI version)

=item 2. C<.build/release/aro> - Local release build

=item 3. C<aro> - Fallback (let shell resolve)

=back

Returns: Path to the aro binary

=cut

sub find_aro_binary {
    # Try to find aro in PATH first (for CI/installed version)
    my $which_aro = `which aro 2>/dev/null`;
    chomp $which_aro;

    if ($which_aro && -x $which_aro) {
        return $which_aro;
    }

    # Fallback to local build directory (relative to project root)
    my $local_aro = File::Spec->catfile($RealBin, '..', '..', '.build', 'release', 'aro');
    if (-x $local_aro) {
        return $local_aro;
    }

    # Last resort: try 'aro' and let shell find it
    return 'aro';
}

=head2 find_example_binary($example_name, $example_dir)

Find a compiled example binary. Searches in order:

=over 4

=item 1. C<$dir/$example_name> - Direct binary in example directory

=item 2. C<$dir/.build/debug/$example_name> - Debug build

=item 3. C<$dir/.build/release/$example_name> - Release build

=back

Parameters:

=over 4

=item * C<$example_name> - Name of the example (e.g., 'HelloWorld')

=item * C<$example_dir> - Path to the example directory

=back

Returns: Path to the binary, or undef if not found

=cut

sub find_example_binary {
    my ($example_name, $example_dir) = @_;

    # Try common locations
    my @paths = (
        File::Spec->catfile($example_dir, $example_name),                    # Examples/HelloWorld/HelloWorld
        File::Spec->catfile($example_dir, '.build', 'debug', $example_name),
        File::Spec->catfile($example_dir, '.build', 'release', $example_name),
    );

    for my $path (@paths) {
        return $path if -x $path;
    }

    return undef;
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
