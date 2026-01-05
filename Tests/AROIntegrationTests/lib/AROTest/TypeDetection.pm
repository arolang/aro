package AROTest::TypeDetection;

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(detect_type);

=head1 NAME

AROTest::TypeDetection - Automatic test type detection for ARO examples

=head1 SYNOPSIS

    use AROTest::TypeDetection qw(detect_type);

    my $type = detect_type('/path/to/example');
    # Returns: 'console', 'http', 'socket', or 'file'

=head1 DESCRIPTION

Automatically detects the type of an ARO example by examining its structure
and content. Detection rules:

=over 4

=item * B<http> - Has openapi.yaml with non-empty paths

=item * B<socket> - .aro files contain C<< <Start> the <socket-server> >>

=item * B<file> - .aro files contain C<< <Start> the <file-monitor> >>

=item * B<console> - Default for all other examples

=back

=cut

# Check if YAML::XS is available
my $has_yaml = eval { require YAML::XS; 1; } || 0;

=head2 detect_type($example_dir)

Detect the type of test based on the example's structure and content.

=over 4

=item * C<$example_dir> - Path to the example directory

=back

Returns: 'http', 'socket', 'file', or 'console'

=cut

sub detect_type {
    my ($example_dir) = @_;

    # Check for OpenAPI contract with non-empty paths
    my $openapi_file = File::Spec->catfile($example_dir, 'openapi.yaml');
    if (-f $openapi_file) {
        # Only treat as HTTP if the spec has actual paths defined
        if ($has_yaml) {
            my $has_paths = 0;
            eval {
                my $spec = YAML::XS::LoadFile($openapi_file);
                $has_paths = 1 if $spec->{paths} && keys %{$spec->{paths}} > 0;
            };
            # Return 'http' if we found actual paths
            return 'http' if $has_paths;
            # Otherwise fall through to console detection
        } else {
            # If YAML::XS not available, assume HTTP (conservative)
            return 'http';
        }
    }

    # Check ARO source for specific patterns
    my @aro_files = glob File::Spec->catfile($example_dir, '*.aro');
    for my $file (@aro_files) {
        open my $fh, '<', $file or next;
        my $content = do { local $/; <$fh> };
        close $fh;

        return 'socket' if $content =~ /<Start>\s+the\s+<socket-server>/;
        return 'file' if $content =~ /<Start>\s+the\s+<file-monitor>/;
    }

    return 'console';
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
