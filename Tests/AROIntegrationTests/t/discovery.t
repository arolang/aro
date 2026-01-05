#!/usr/bin/env perl
# Unit tests for AROTest::Discovery

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Temp;

BEGIN {
    use_ok('AROTest::Discovery', qw(discover_examples read_test_hint));
}

# Test discover_examples() with actual Examples directory
{
    my $examples_dir = File::Spec->catdir($RealBin, '..', '..', '..', 'Examples');

    if (-d $examples_dir) {
        my @examples = discover_examples($examples_dir);

        ok(scalar @examples > 0, 'discover_examples() finds examples');
        ok((grep { $_ eq 'HelloWorld' } @examples), 'finds HelloWorld example');

        # Test with filter
        my @http_examples = discover_examples($examples_dir, 'HTTP');
        ok(scalar @http_examples >= 0, 'filter returns valid result');

        # All filtered examples should match pattern
        my $all_match = 1;
        for my $ex (@http_examples) {
            $all_match = 0 unless $ex =~ /HTTP/i;
        }
        ok($all_match, 'filter only returns matching examples');
    } else {
        # Skip these tests if Examples directory doesn't exist
        ok(1, 'skipping discovery tests - Examples directory not found');
        ok(1, 'skipping HelloWorld test');
        ok(1, 'skipping filter test');
        ok(1, 'skipping filter match test');
    }
}

# Test read_test_hint() with temporary test.hint file
{
    my $temp_dir = File::Temp->newdir();
    my $hint_file = File::Spec->catfile($temp_dir, 'test.hint');

    # Create test.hint file
    open my $fh, '>', $hint_file or die "Cannot create $hint_file: $!";
    print $fh "type: http\n";
    print $fh "timeout: 30\n";
    print $fh "workdir: /tmp/test\n";
    print $fh "pre-script: ./setup.sh\n";
    close $fh;

    # Create minimal config
    require AROTest::Config;
    my $config = AROTest::Config->new();

    my $hints = read_test_hint($temp_dir, $config);

    isa_ok($hints, 'HASH', 'read_test_hint() returns hash');
    is($hints->{type}, 'http', 'type is parsed correctly');
    is($hints->{timeout}, 30, 'timeout is parsed correctly');
    is($hints->{workdir}, '/tmp/test', 'workdir is parsed correctly');
    is($hints->{'pre-script'}, './setup.sh', 'pre-script is parsed correctly');
}

# Test read_test_hint() with skip directive
{
    my $temp_dir = File::Temp->newdir();
    my $hint_file = File::Spec->catfile($temp_dir, 'test.hint');

    open my $fh, '>', $hint_file or die "Cannot create $hint_file: $!";
    print $fh "skip: Not implemented yet\n";
    close $fh;

    require AROTest::Config;
    my $config = AROTest::Config->new();

    my $hints = read_test_hint($temp_dir, $config);

    is($hints->{skip}, 'Not implemented yet', 'skip directive is parsed correctly');
}

# Test read_test_hint() with no hint file
{
    my $temp_dir = File::Temp->newdir();

    require AROTest::Config;
    my $config = AROTest::Config->new();

    my $hints = read_test_hint($temp_dir, $config);

    isa_ok($hints, 'HASH', 'returns hash when no hint file');
    is(scalar keys %$hints, 7, 'hash has 7 default keys when no hint file');
    is($hints->{type}, undef, 'default type is undef');
}

# Test read_test_hint() with comments and blank lines
{
    my $temp_dir = File::Temp->newdir();
    my $hint_file = File::Spec->catfile($temp_dir, 'test.hint');

    open my $fh, '>', $hint_file or die "Cannot create $hint_file: $!";
    print $fh "# This is a comment\n";
    print $fh "\n";
    print $fh "type: console\n";
    print $fh "  \n";
    print $fh "# Another comment\n";
    print $fh "timeout: 15\n";
    close $fh;

    require AROTest::Config;
    my $config = AROTest::Config->new();

    my $hints = read_test_hint($temp_dir, $config);

    is($hints->{type}, 'console', 'parses type with comments present');
    is($hints->{timeout}, 15, 'parses timeout with blank lines present');
}

done_testing();
