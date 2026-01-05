#!/usr/bin/env perl
# Unit tests for AROTest::TypeDetection

use strict;
use warnings;
use Test::More tests => 11;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Temp;

BEGIN {
    use_ok('AROTest::TypeDetection', qw(detect_type));
}

# Test detect_type() with HTTP example (openapi.yaml with paths)
{
    my $temp_dir = File::Temp->newdir();
    my $openapi_file = File::Spec->catfile($temp_dir, 'openapi.yaml');

    open my $fh, '>', $openapi_file or die "Cannot create $openapi_file: $!";
    print $fh "openapi: 3.0.0\n";
    print $fh "paths:\n";
    print $fh "  /users:\n";
    print $fh "    get:\n";
    print $fh "      operationId: listUsers\n";
    close $fh;

    my $type = detect_type($temp_dir);
    is($type, 'http', 'detects HTTP type when openapi.yaml has paths');
}

# Test detect_type() with socket example
{
    my $temp_dir = File::Temp->newdir();
    my $aro_file = File::Spec->catfile($temp_dir, 'main.aro');

    open my $fh, '>', $aro_file or die "Cannot create $aro_file: $!";
    print $fh "(Application-Start: Socket Server) {\n";
    print $fh "    <Start> the <socket-server> with <config>.\n";
    print $fh "    <Return> an <OK: status> for the <startup>.\n";
    print $fh "}\n";
    close $fh;

    my $type = detect_type($temp_dir);
    is($type, 'socket', 'detects socket type when <socket-server> present');
}

# Test detect_type() with file watcher example
{
    my $temp_dir = File::Temp->newdir();
    my $aro_file = File::Spec->catfile($temp_dir, 'main.aro');

    open my $fh, '>', $aro_file or die "Cannot create $aro_file: $!";
    print $fh "(Application-Start: File Monitor) {\n";
    print $fh "    <Start> the <file-monitor> with <path>.\n";
    print $fh "    <Return> an <OK: status> for the <startup>.\n";
    print $fh "}\n";
    close $fh;

    my $type = detect_type($temp_dir);
    is($type, 'file', 'detects file type when <file-monitor> present');
}

# Test detect_type() with console example (default)
{
    my $temp_dir = File::Temp->newdir();
    my $aro_file = File::Spec->catfile($temp_dir, 'main.aro');

    open my $fh, '>', $aro_file or die "Cannot create $aro_file: $!";
    print $fh "(Application-Start: Hello World) {\n";
    print $fh "    <Log> \"Hello, World!\" to the <console>.\n";
    print $fh "    <Return> an <OK: status> for the <startup>.\n";
    print $fh "}\n";
    close $fh;

    my $type = detect_type($temp_dir);
    is($type, 'console', 'defaults to console type for simple examples');
}

# Test detect_type() with empty directory
{
    my $temp_dir = File::Temp->newdir();

    my $type = detect_type($temp_dir);
    is($type, 'console', 'defaults to console for empty directory');
}

# Test priority: openapi.yaml with paths takes precedence
{
    my $temp_dir = File::Temp->newdir();

    # Create openapi.yaml with paths
    my $openapi_file = File::Spec->catfile($temp_dir, 'openapi.yaml');
    open my $fh1, '>', $openapi_file or die "Cannot create $openapi_file: $!";
    print $fh1 "openapi: 3.0.0\n";
    print $fh1 "paths:\n";
    print $fh1 "  /api:\n";
    print $fh1 "    get:\n";
    print $fh1 "      operationId: test\n";
    close $fh1;

    # Also create file with socket-server
    my $aro_file = File::Spec->catfile($temp_dir, 'main.aro');
    open my $fh2, '>', $aro_file or die "Cannot create $aro_file: $!";
    print $fh2 "<Start> the <socket-server> with <config>.\n";
    close $fh2;

    my $type = detect_type($temp_dir);
    is($type, 'http', 'openapi.yaml with paths takes precedence over socket detection');
}

# Test with actual Examples directory - HelloWorld
{
    my $examples_dir = File::Spec->catdir($RealBin, '..', '..', '..', 'Examples');
    my $hello_world_dir = File::Spec->catdir($examples_dir, 'HelloWorld');

    if (-d $hello_world_dir) {
        my $type = detect_type($hello_world_dir);
        is($type, 'console', 'correctly detects HelloWorld as console type');
    } else {
        ok(1, 'skipping HelloWorld test - directory not found');
    }
}

# Test with actual Examples directory - HTTPServer (if exists)
{
    my $examples_dir = File::Spec->catdir($RealBin, '..', '..', '..', 'Examples');
    my $http_dir = File::Spec->catdir($examples_dir, 'HelloWorldAPI');

    if (-d $http_dir) {
        my $type = detect_type($http_dir);
        is($type, 'http', 'correctly detects HelloWorldAPI as http type');
    } else {
        ok(1, 'skipping HTTP test - directory not found');
    }
}

# Test case sensitivity (patterns are case-sensitive)
{
    my $temp_dir = File::Temp->newdir();
    my $aro_file = File::Spec->catfile($temp_dir, 'main.aro');

    open my $fh, '>', $aro_file or die "Cannot create $aro_file: $!";
    # Detection uses exact pattern matching (case-sensitive)
    print $fh "<Start> the <socket-server> with <config>.\n";
    close $fh;

    my $type = detect_type($temp_dir);
    is($type, 'socket', 'detects socket with lowercase pattern');
}

# Test with multiple .aro files
{
    my $temp_dir = File::Temp->newdir();

    # Create first file without indicators
    my $file1 = File::Spec->catfile($temp_dir, 'main.aro');
    open my $fh1, '>', $file1 or die;
    print $fh1 "<Log> \"test\" to the <console>.\n";
    close $fh1;

    # Create second file with socket-server
    my $file2 = File::Spec->catfile($temp_dir, 'server.aro');
    open my $fh2, '>', $file2 or die;
    print $fh2 "<Start> the <socket-server> with <config>.\n";
    close $fh2;

    my $type = detect_type($temp_dir);
    is($type, 'socket', 'detects type from any .aro file in directory');
}

done_testing();
