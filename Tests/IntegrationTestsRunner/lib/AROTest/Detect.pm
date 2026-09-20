package AROTest::Detect;

# Auto-detect the test type for an example when test.hint doesn't say.
# Order matters: a non-empty OpenAPI contract makes it http; otherwise the
# .aro source is grepped for socket-server / file-monitor markers; finally
# fall back to console.

use strict;
use warnings;
use v5.30;
use File::Spec;
use Exporter 'import';

use AROTest::Utils qw($has_yaml);
use AROTest::Config qw($examples_dir);

our @EXPORT_OK = qw(detect_example_type strip_aro_comments);

# Remove ARO comments so a sentence *about* a service can't decide how an
# example is tested (GitLab #837). Block comments are `(* ... *)` and do not
# nest (Sources/AROParser/Lexer.swift), line comments run to end of line.
#
# String literals are skipped over rather than scanned, which keeps
# `Log "(* not a comment *)" to the <console>.` intact. That case is rarer
# than the one being fixed, but honouring it costs one extra alternation and
# matches what the lexer does: comment markers are only recognised between
# tokens, never inside a string.
#
# This is deliberately not a parser — the harness has none and needs none.
# Each comment becomes a single space so the surrounding text cannot be
# glued into a marker that was never written.
sub strip_aro_comments {
    my ($source) = @_;
    return '' unless defined $source;

    my $out = '';
    while ($source =~ m{
        \G (?:
              ( " (?: \\. | [^"\\] )* "? )   # $1 string literal (kept; unterminated tolerated)
            | \(\* .*? (?: \*\) | \z )       #    block comment (dropped)
            | // [^\n]*                      #    line comment (dropped)
            | ( [^"(/]+ | . )                # $2 ordinary source (kept)
          )
    }gcxs) {
        if    (defined $1) { $out .= $1 }
        elsif (defined $2) { $out .= $2 }
        else               { $out .= ' ' }   # a comment stood here
    }

    return $out;
}

sub detect_example_type {
    my ($example_name) = @_;
    my $dir = File::Spec->catdir($examples_dir, $example_name);

    # OpenAPI contract: only treat as HTTP if the spec actually defines paths.
    if (-f File::Spec->catfile($dir, 'openapi.yaml')) {
        if ($has_yaml) {
            my $has_paths = 0;
            eval {
                my $spec = YAML::XS::LoadFile(File::Spec->catfile($dir, 'openapi.yaml'));
                $has_paths = 1 if $spec->{paths} && keys %{$spec->{paths}} > 0;
            };
            return 'http' if $has_paths;
            # Otherwise fall through to source-pattern detection.
        } else {
            # No YAML parser available — assume HTTP conservatively.
            return 'http';
        }
    }

    my @aro_files = glob File::Spec->catfile($dir, '*.aro');
    for my $file (@aro_files) {
        open my $fh, '<', $file or next;
        my $content = do { local $/; <$fh> };
        close $fh;

        $content = strip_aro_comments($content);

        return 'socket' if $content =~ /Start\s+the\s+<socket-server>/;
        return 'file'   if $content =~ /Start\s+the\s+<file-monitor>/;
    }

    return 'console';
}

1;
