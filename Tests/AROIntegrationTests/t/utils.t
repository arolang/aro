#!/usr/bin/env perl
# Unit tests for AROTest::Utils

use strict;
use warnings;
use Test::More tests => 5;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

BEGIN {
    use_ok('AROTest::Utils', qw(colored));
}

# Test colored() function
{
    my $text = "Hello, World!";

    # Test with Term::ANSIColor available (should return colored text)
    my $colored_text = colored($text, 'green');
    ok(defined $colored_text, 'colored() returns defined value');
    ok(length($colored_text) > 0, 'colored() returns non-empty string');

    # The function should either return colored text or plain text
    # depending on Term::ANSIColor availability
    ok($colored_text =~ /Hello, World!/, 'colored() preserves original text');
}

# Test with empty string (colored() may add ANSI codes even for empty)
{
    my $result = colored('', 'red');
    ok(defined $result, 'colored() handles empty string without error');
}

done_testing();
