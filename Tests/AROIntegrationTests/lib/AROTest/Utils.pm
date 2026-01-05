package AROTest::Utils;

use strict;
use warnings;
use v5.30;
use Exporter 'import';

our @EXPORT_OK = qw(colored);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

=head1 NAME

AROTest::Utils - Utility functions for ARO integration tests

=head1 SYNOPSIS

    use AROTest::Utils qw(colored);

    print colored("PASS", 'green'), "\n";
    print colored("FAIL", 'red'), "\n";

=head1 DESCRIPTION

Provides common utility functions for the ARO test framework.

=cut

# Check if Term::ANSIColor is available
my $has_term_color = eval { require Term::ANSIColor; 1; } || 0;

=head2 colored($text, $color)

Returns colored text if Term::ANSIColor is available, otherwise returns plain text.

=over 4

=item * C<$text> - The text to colorize

=item * C<$color> - The color name (e.g., 'red', 'green', 'yellow', 'bold red')

=back

Returns: The colored string, or plain text if colors are not available.

=cut

sub colored {
    my ($text, $color) = @_;
    return $text unless $has_term_color;
    return Term::ANSIColor::colored($text, $color);
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
