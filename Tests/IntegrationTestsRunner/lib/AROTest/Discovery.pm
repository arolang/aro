package AROTest::Discovery;

# Walk the Examples/ directory and return testable example names (sorted).
# A few "non-example" subdirectories (template, data, output, demo-output)
# are excluded — they hold scaffolding or test output rather than .aro code.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

use AROTest::Config qw($examples_dir);

our @EXPORT_OK = qw(discover_examples);

sub discover_examples {
    opendir my $dh, $examples_dir or die "Cannot open $examples_dir: $!";

    my %excluded = (
        'template'    => 1,
        'data'        => 1,
        'output'      => 1,
        'demo-output' => 1,
    );

    my @examples = grep {
        -d File::Spec->catdir($examples_dir, $_)
            && !/^\./
            && !$excluded{$_}
    } readdir $dh;
    closedir $dh;

    return sort @examples;
}

1;
