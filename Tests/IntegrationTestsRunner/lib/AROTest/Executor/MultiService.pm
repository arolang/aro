package AROTest::Executor::MultiService;

# MultiService executor: an example that hosts HTTP + TCP socket + file
# event handlers all at once. Drive each surface in turn and concatenate the
# transcripts for the comparator.

use strict;
use warnings;
use v5.30;
use File::Spec;
use File::Basename;
use Cwd qw(cwd);
use Time::HiRes qw(time sleep);
use IPC::Run qw(start finish timeout kill_kill pump);
use Exporter 'import';

use AROTest::Utils qw($has_http_tiny $has_net_emptyport is_executable get_binary_path);
use AROTest::Config qw(%options $examples_dir @cleanup_handlers);
use AROTest::Binary qw(find_aro_binary);
use AROTest::Normalize qw(_normalize_json_output);

our @EXPORT_OK = qw(run_multiservice_example_internal);

sub run_multiservice_example_internal {
    my ($example_name, $timeout, $mode, $binary_name) = @_;
    $mode //= 'interpreter';

    unless ($has_http_tiny && $has_net_emptyport) {
        return (undef, "SKIP: Missing required modules (HTTP::Tiny, Net::EmptyPort)");
    }

    my $dir;
    if ($example_name eq '.' || File::Spec->file_name_is_absolute($example_name)) {
        $dir = $example_name;
    } else {
        $dir = File::Spec->catdir($examples_dir, $example_name);
    }

    my $http_port   = Net::EmptyPort::empty_port(8080);
    my $socket_port = Net::EmptyPort::empty_port(9000);
    my $watch_dir   = File::Spec->catdir(cwd(), 'watched-dir');

    mkdir $watch_dir unless -d $watch_dir;

    # Build command
    my @cmd;
    if ($mode eq 'compiled') {
        my $basename = defined $binary_name ? $binary_name : basename($dir);
        my $binary_path = get_binary_path($dir, $basename);
        unless (is_executable($binary_path)) {
            return (undef, "ERROR: Compiled binary not found at $binary_path");
        }
        @cmd = ($binary_path);
    } else {
        my $aro_bin = find_aro_binary();
        @cmd = ($aro_bin, 'run', $dir);
    }

    say "  Starting multi-service app: @cmd" if $options{verbose};

    # Use fork/exec to avoid IPC::Run pipe deadlock issues.
    # Redirect child stdout/stderr to /dev/null so the child never blocks on writes.
    require POSIX;
    my $child_pid = fork();
    if (!defined $child_pid) {
        return (undef, "Failed to fork multi-service app: $!");
    }
    if ($child_pid == 0) {
        # Child: redirect stdout/stderr and exec; pass free ports via env
        $ENV{ARO_HTTP_PORT}   = $http_port;
        $ENV{ARO_SOCKET_PORT} = $socket_port;
        open(STDOUT, '>', '/dev/null') or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null') or POSIX::_exit(1);
        exec(@cmd) or POSIX::_exit(1);
    }

    say "  App started, pid=$child_pid" if $options{verbose};

    my $cleanup = sub {
        return unless $child_pid;
        eval {
            kill('TERM', $child_pid);
            my $waited = 0;
            while ($waited < 3.0) {
                my $res = waitpid($child_pid, POSIX::WNOHANG());
                last if $res != 0;
                select(undef, undef, undef, 0.1);
                $waited += 0.1;
            }
            kill('KILL', $child_pid);
            waitpid($child_pid, 0);
        };
        $child_pid = 0;
    };
    push @cleanup_handlers, $cleanup;

    say "  Waiting for HTTP port $http_port" if $options{verbose};
    my $http_ready = 0;
    for (1..20) {
        if (Net::EmptyPort::wait_port($http_port, 0.5)) { $http_ready = 1; last; }
    }
    say "  HTTP ready=$http_ready" if $options{verbose};
    unless ($http_ready) {
        $cleanup->();
        @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;
        return (undef, "ERROR: HTTP server did not start on port $http_port");
    }

    # Wait for socket port
    my $socket_ready = 0;
    for (1..10) {
        if (Net::EmptyPort::wait_port($socket_port, 0.5)) { $socket_ready = 1; last; }
    }
    unless ($socket_ready) {
        $cleanup->();
        @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;
        return (undef, "ERROR: Socket server did not start on port $socket_port");
    }

    say "  Connecting socket client" if $options{verbose};

    # Connect persistent socket client
    my $sock;
    for (1..5) {
        $sock = IO::Socket::INET->new(
            PeerAddr => 'localhost',
            PeerPort => $socket_port,
            Proto    => 'tcp',
            Timeout  => 3,
        );
        last if $sock;
        select(undef, undef, undef, 0.5);
    }
    unless ($sock) {
        $cleanup->();
        @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;
        return (undef, "ERROR: Could not connect to socket server: $!");
    }
    $sock->autoflush(1);

    require IO::Select;
    my $sel = IO::Select->new($sock);

    # Read available socket data within $wait seconds.
    # Uses sysread (not readline) because ARO broadcasts raw bytes without newline terminators.
    my $read_socket = sub {
        my ($wait) = @_;
        my $buf = '';
        my $deadline = time() + $wait;
        while (time() < $deadline) {
            my $remaining = $deadline - time();
            last if $remaining <= 0;
            my $poll = $remaining > 0.2 ? 0.2 : $remaining;
            next unless $sel->can_read($poll);
            my $chunk = '';
            my $bytes = sysread($sock, $chunk, 4096);
            last unless defined $bytes && $bytes > 0;
            $buf .= $chunk;
        }
        # Split on any line ending or NUL, discard empty fragments
        return grep { length $_ } split /[\r\n\0]+/, $buf;
    };

    my @output;
    my $http = HTTP::Tiny->new(timeout => 5);

    # 1. Welcome message on connect
    say "  Waiting for socket welcome" if $options{verbose};
    for my $line ($read_socket->(2)) {
        push @output, "Socket: $line";
    }

    # 2. HTTP GET /status
    say "  HTTP GET /status" if $options{verbose};
    my $status_resp = $http->get("http://localhost:$http_port/status");
    if ($status_resp->{success}) {
        my $body = _normalize_json_output($status_resp->{content});
        push @output, "GET /status => $body";
    } else {
        push @output, "GET /status => ERROR: " . $status_resp->{status};
    }

    # 3. Create file -> socket notification
    my $test_file = File::Spec->catfile($watch_dir, "ms_testfile.txt");
    unlink $test_file if -f $test_file;  # clean up any previous run
    say "  Creating test file" if $options{verbose};
    { open(my $fh, '>', $test_file) or die "Cannot create $test_file: $!"; close $fh; }
    for my $line ($read_socket->(3)) {
        $line =~ s{FILE CREATED: .*/([^/]+)$}{FILE CREATED: $1};
        push @output, "Socket: $line";
    }

    # 4. HTTP POST /broadcast
    say "  HTTP POST /broadcast" if $options{verbose};
    my $broadcast_resp = $http->post(
        "http://localhost:$http_port/broadcast",
        { headers => { 'Content-Type' => 'application/json' },
          content => '{"message":"Hello from HTTP!"}' }
    );
    if ($broadcast_resp->{success}) {
        my $body = _normalize_json_output($broadcast_resp->{content});
        push @output, "POST /broadcast => $body";
    } else {
        push @output, "POST /broadcast => ERROR: " . $broadcast_resp->{status};
    }
    for my $line ($read_socket->(2)) {
        push @output, "Socket: $line";
    }

    # 5. Delete file -> socket notification
    say "  Deleting test file" if $options{verbose};
    unlink $test_file if -f $test_file;
    # Wait longer for deletion events on Linux (inotify can be slower)
    for my $line ($read_socket->(5)) {
        $line =~ s{FILE DELETED: .*/([^/]+)$}{FILE DELETED: $1};
        push @output, "Socket: $line";
    }

    close $sock;
    $cleanup->();
    @cleanup_handlers = grep { $_ != $cleanup } @cleanup_handlers;

    return (join("\n", @output), undef);
}

1;
