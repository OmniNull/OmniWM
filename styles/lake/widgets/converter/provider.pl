#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(basename);
use File::Spec;
use POSIX qw(:sys_wait_h);
use Errno qw(EINTR);
$| = 1;
my $child = 0;
my %formats = (png => 'png', jpeg => 'jpg', tiff => 'tiff');
sub emit { print encode_json($_[0]), "\n" or die $!; }
sub stop_child {
    if ($child) {
        kill 'KILL', $child;
        while (waitpid($child, 0) < 0 && $! == EINTR) {}
        $child = 0;
    }
}
$SIG{TERM} = sub { stop_child(); exit 0; };
$SIG{INT} = sub { stop_child(); exit 0; };
END { stop_child(); }
sub convert {
    my ($request, $args, $attachments) = @_;
    return 'invalid_format' unless ref($args) eq 'HASH' && defined($args->{format})
        && !ref($args->{format}) && exists($formats{$args->{format}});
    return 'invalid_attachments' unless ref($attachments) eq 'HASH' && ref($attachments->{files}) eq 'ARRAY'
        && @{$attachments->{files}} >= 1 && @{$attachments->{files}} <= 32
        && defined($attachments->{outputDirectory}) && !ref($attachments->{outputDirectory})
        && File::Spec->file_name_is_absolute($attachments->{outputDirectory}) && -d $attachments->{outputDirectory};
    my $format = $args->{format};
    my $directory = $attachments->{outputDirectory};
    my @outputs;
    my $total = scalar @{$attachments->{files}};
    for my $file (@{$attachments->{files}}) {
        return 'invalid_input' unless ref($file) eq 'HASH' && defined($file->{path}) && !ref($file->{path})
            && File::Spec->file_name_is_absolute($file->{path}) && -f $file->{path}
            && defined($file->{name}) && !ref($file->{name}) && length($file->{name}) <= 1024;
    }
    for my $file (@{$attachments->{files}}) {
        my $index = @outputs + 1;
        my $stem = basename($file->{name});
        $stem =~ s/\.[^.]*$//;
        $stem =~ s/[^a-zA-Z0-9._-]/_/g;
        $stem = substr($stem, 0, 80);
        $stem = 'image' unless length($stem);
        my $name = sprintf('%02d-%s.%s', $index, $stem, $formats{$format});
        my $path = File::Spec->catfile($directory, $name);
        emit(['state', 'conversion', { active => JSON::PP::true, completed => scalar(@outputs), total => $total }]);
        $child = fork();
        return 'converter_launch_failed' unless defined($child);
        if ($child == 0) {
            open STDOUT, '>&', STDERR or POSIX::_exit(126);
            exec('/usr/bin/sips', '-s', 'format', $format, $file->{path}, '--out', $path) or POSIX::_exit(127);
        }
        my $wait;
        do { $wait = waitpid($child, 0); } while ($wait < 0 && $! == EINTR);
        my $status = $?;
        $child = 0;
        return 'conversion_failed' unless $wait > 0 && $status == 0 && -f $path && -s $path;
        push @outputs, { name => $name, path => $name };
    }
    emit(['state', 'conversion', { active => JSON::PP::false, completed => $total, total => $total }]);
    emit(['result', $request, JSON::PP::true, { converted => $total, format => $format }, { files => \@outputs }]);
    return undef;
}
emit(['state', 'status', { ready => JSON::PP::true, files => JSON::PP::true }]);
while (my $line = <STDIN>) {
    die 'oversized action' if length($line) > 65536;
    my $message = eval { decode_json($line) };
    die 'invalid action' unless ref($message) eq 'ARRAY' && (@$message == 4 || @$message == 5)
        && $message->[0] eq 'action' && defined($message->[1]) && !ref($message->[1])
        && length($message->[1]) <= 64 && defined($message->[2]) && !ref($message->[2]);
    my ($kind, $request, $name, $arguments, $attachments) = @$message;
    if ($name eq 'ping') {
        emit(['result', $request, JSON::PP::true, { protocol => 1, files => JSON::PP::true }]);
    } elsif ($name eq 'convert') {
        my $error = convert($request, $arguments, $attachments);
        if ($error) {
            emit(['state', 'conversion', { active => JSON::PP::false, error => $error }]);
            emit(['result', $request, JSON::PP::false, $error]);
        }
    } else { emit(['result', $request, JSON::PP::false, 'unknown_action']); }
}
