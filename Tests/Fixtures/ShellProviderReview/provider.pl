#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
$| = 1;
sub emit { print encode_json($_[0]), "\n" or die $!; }
emit(['state', 'summary', 'Ready']);
while (my $line = <STDIN>) {
    my $frame = eval { decode_json($line) };
    next unless ref($frame) eq 'ARRAY' && @$frame == 4 && $frame->[0] eq 'action';
    emit(['result', $frame->[1], JSON::PP::true, {}]);
    emit(['event', 'confirm-delete', { itemId => 'selected-item' }]) if $frame->[2] eq 'check';
}
