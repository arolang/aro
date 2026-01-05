package AROTest::Config;

use strict;
use warnings;
use v5.30;
use FindBin qw($RealBin);
use File::Spec;

=head1 NAME

AROTest::Config - Global configuration management for ARO integration tests

=head1 SYNOPSIS

    use AROTest::Config;

    my $config = AROTest::Config->new(
        generate => 0,
        verbose => 1,
        timeout => 10,
        filter => '',
    );

    if ($config->is_verbose) {
        print "Running in verbose mode\n";
    }

=head1 DESCRIPTION

Manages global configuration state for the ARO test framework. Provides
accessors for options and manages cleanup handlers for graceful shutdown.

=cut

# Singleton instance
my $instance;

=head2 new(%options)

Creates a new configuration object. Options hash can contain:

=over 4

=item * C<generate> - Whether to generate expected output files (default: 0)

=item * C<verbose> - Whether to show verbose output (default: 0)

=item * C<timeout> - Timeout in seconds for tests (default: 10)

=item * C<filter> - Pattern to filter examples (default: '')

=item * C<examples_dir> - Override examples directory (default: $RealBin/Examples)

=back

=cut

sub new {
    my ($class, %options) = @_;

    my $self = bless {
        generate => $options{generate} // 0,
        verbose => $options{verbose} // 0,
        timeout => $options{timeout} // 10,
        filter => $options{filter} // '',
        examples_dir => $options{examples_dir} // File::Spec->catdir($RealBin, '..', '..', 'Examples'),
        cleanup_handlers => [],
    }, $class;

    # Set up signal handling for cleanup
    $self->_setup_signal_handlers();

    # Store as singleton
    $instance = $self;

    return $self;
}

=head2 instance()

Returns the singleton instance if one has been created.

=cut

sub instance {
    return $instance;
}

=head2 get($key)

Get a configuration value by key.

=cut

sub get {
    my ($self, $key) = @_;
    return $self->{$key};
}

=head2 set($key, $value)

Set a configuration value.

=cut

sub set {
    my ($self, $key, $value) = @_;
    $self->{$key} = $value;
}

=head2 is_generate()

Returns true if in generate mode (creating expected.txt files).

=cut

sub is_generate {
    my ($self) = @_;
    return $self->{generate};
}

=head2 is_verbose()

Returns true if verbose output is enabled.

=cut

sub is_verbose {
    my ($self) = @_;
    return $self->{verbose};
}

=head2 timeout()

Returns the configured timeout in seconds.

=cut

sub timeout {
    my ($self) = @_;
    return $self->{timeout};
}

=head2 filter()

Returns the example filter pattern.

=cut

sub filter {
    my ($self) = @_;
    return $self->{filter};
}

=head2 examples_dir()

Returns the examples directory path.

=cut

sub examples_dir {
    my ($self) = @_;
    return $self->{examples_dir};
}

=head2 add_cleanup_handler($coderef)

Register a cleanup handler to be called on shutdown or signal.

    $config->add_cleanup_handler(sub {
        kill 'TERM', $server_pid if $server_pid;
    });

=cut

sub add_cleanup_handler {
    my ($self, $handler) = @_;
    push @{$self->{cleanup_handlers}}, $handler;
}

=head2 run_cleanup_handlers()

Execute all registered cleanup handlers. Called automatically on signals.

=cut

sub run_cleanup_handlers {
    my ($self) = @_;
    $_->() for @{$self->{cleanup_handlers}};
}

# Private method to set up signal handlers
sub _setup_signal_handlers {
    my ($self) = @_;

    $SIG{INT} = $SIG{TERM} = sub {
        warn "\nCaught signal, cleaning up...\n";
        $self->run_cleanup_handlers();
        exit 1;
    };
}

1;

__END__

=head1 AUTHOR

ARO Integration Test Framework

=head1 LICENSE

Copyright (c) 2024-2026 ARO Project

=cut
