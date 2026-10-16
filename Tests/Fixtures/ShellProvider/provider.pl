#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
use POSIX ();
$| = 1;
select STDERR; $| = 1; select STDOUT;
my $options = decode_json($ENV{'OMNIWM_PROVIDER_OPTIONS'} || '{}');
my $tag = $options->{'tag'} || 'A';
my $mode = $options->{'mode'} || 'echo';
my $directory = $ENV{'OMNIWM_WIDGET_DIR'} or die 'missing widget directory';
my $closed = $directory . '/closed';
my $launches = $directory . '/launches';
my $previous = '';
if (open(my $old, '<', $closed)) { local $/; $previous = <$old> || ''; close($old); }
open(my $starts, '>>', $launches) or die $!;
print $starts "$tag\n";
close($starts) or die $!;
sub emit { print encode_json($_[0]), "\n" or die $!; }
sub finish {
    $SIG{'TERM'} = 'IGNORE';
    open(my $out, '>', $closed) or die $!;
    print $out $tag;
    close($out) or die $!;
    print STDERR "fixture:closed:$tag\n";
    exit(0);
}
$SIG{'TERM'} = \&finish;
my $identity = { tag => $tag, mode => $mode, pid => $$, previousClosed => $previous,
    instance => $ENV{'OMNIWM_INSTANCE'}, protocol => $ENV{'OMNIWM_PROVIDER_PROTOCOL'} };
emit(['state', 'identity', $identity]);
emit(['event', 'ready', $identity]);
print STDERR "fixture:ready:$tag\n";
if ($mode eq 'stopped') { kill 'STOP', $$ or die $!; }
if ($mode eq 'stall' || $mode eq 'stopped') { while (1) { POSIX::pause(); } }
my $count = 0;
while (my $line = <STDIN>) {
    die 'oversized action' if length($line) > 65536;
    my $message = decode_json($line);
    die 'invalid action' unless ref($message) eq 'ARRAY' && @$message == 4 && $message->[0] eq 'action';
    my ($kind, $request, $name, $arguments) = @$message;
    if ($name eq 'crash') {
        emit(['result', $request, JSON::PP::true, { exiting => 7 }]);
        exit(7);
    } elsif ($name eq 'flood_state') {
        for my $index (1 .. 8192) { emit(['state', 'latest', { index => $index }]); }
        emit(['result', $request, JSON::PP::true, { count => 8192 }]);
    } elsif ($name eq 'flood_events') {
        emit(['result', $request, JSON::PP::true, { beforeFlood => JSON::PP::true }]);
        for my $index (1 .. 300) { emit(['event', 'sample', $index]); }
        print STDERR "fixture:flood_done\n";
    } elsif ($name eq 'echo') {
        my $value = { tag => $tag, count => ++$count, argument => $arguments };
        emit(['state', 'latest', $value]);
        emit(['event', 'changed', $value]);
        emit(['result', $request, JSON::PP::true, $value]);
    } else {
        emit(['result', $request, JSON::PP::false, 'unknown_action']);
    }
}
finish();
