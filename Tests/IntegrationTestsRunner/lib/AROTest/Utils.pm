package AROTest::Utils;

# Platform detection, binary path helpers, terminal color wrapper.
# Extracted verbatim from test-examples.pl so behavior stays identical.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(
    $is_windows $is_linux $is_macos
    $has_yaml $has_http_tiny $has_net_emptyport $has_term_color
    colored is_executable get_binary_path
);

our $is_windows = ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys');
our $is_linux   = ($^O eq 'linux');
our $is_macos   = ($^O eq 'darwin');

# Optional modules — fall back gracefully if any is missing.
our $has_yaml          = eval { require YAML::XS;       1; } || 0;
our $has_http_tiny     = eval { require HTTP::Tiny;     1; } || 0;
our $has_net_emptyport = eval { require Net::EmptyPort; 1; } || 0;
our $has_term_color    = eval { require Term::ANSIColor; 1; } || 0;

sub colored {
    my ($text, $color) = @_;
    return $text unless $has_term_color;
    return Term::ANSIColor::colored($text, $color);
}

# Executables on Windows need .exe; everywhere else they're bare names.
sub get_binary_path {
    my ($dir, $basename) = @_;
    my $binary_name = $is_windows ? "$basename.exe" : $basename;
    return File::Spec->catfile($dir, $binary_name);
}

# `-x` is unreliable on Windows; fall back to "exists and has .exe extension".
sub is_executable {
    my ($path) = @_;
    if ($is_windows) {
        return (-e $path && $path =~ /\.exe$/i);
    }
    return -x $path;
}

1;
