#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Server-side pathname validation.  MKDIR is used as the probe because
# it needs no signature and shares is_valid_filename() with every other
# path-taking command.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $data = "$e->{dir}/data";

# Each of these must be rejected by is_valid_filename()
my %invalid = (
	'relative'     => 'relative path',
	'/trailing/'   => 'trailing slash',
	'//double'     => 'double slash',
	'/.hidden'     => 'dot file (old test/10)',
	'/a/.hidden'   => 'dot file in a subdir',
	'/a/..'        => 'dot-dot',
	'/-dash'       => 'leading dash',
	'/a' x 513     => 'over 1024 bytes',
	'/'.('a' x 101) => 'component over 100 bytes (old test/11)',
	# 34 x U+20AC is 34 chars but 102 bytes: the limit is in bytes
	'/'.("\xe2\x82\xac" x 34) => 'multibyte component over 100 bytes',
);
for my $c (split(//, q{!"$&'*;<>?\`|})) {
	$invalid{"/bad${c}char"} = "forbidden character $c";
}
for my $path (sort keys %invalid) {
	server_fails($e, "MKDIR $path\n",
		     qr/Invalid filename in MKDIR command/,
		     "rejected: $invalid{$path}");
}

# Control characters and broken UTF-8 never get as far as path checks.
# Old tests 13-15 also had a leading dot, so they never tested this.
for my $t (['/new%0Aline', 'URL-encoded newline'],
	   ['/nul%00', 'URL-encoded NUL'],
	   ['/del%7F', 'URL-encoded DEL'],
	   ['/bad%FFutf8', 'invalid UTF-8'],
	   ['/badescape%zz', 'malformed escape']) {
	server_fails($e, "MKDIR $t->[0]\n", qr/Syntax error/,
		     "rejected: $t->[1]");
}
server_fails($e, "MKDIR /bell\aring\n", qr/Invalid command/,
	     'rejected: raw control character in command line');

opendir(my $dh, $data) or xbail("opendir: $!");
is_deeply([ grep(!/\A\.\.?\z/, readdir($dh)) ], [],
	  'no rejected path was created');

# Boundaries that must still work (old tests 12 and 16)
my $c100 = 'a' x 100;
my $euro33 = "\xe2\x82\xac" x 33;	# 99 bytes
my %valid = (
	"/$c100"                     => '100-byte component',
	"/$euro33"                   => '99-byte multibyte component',
	"/$c100" x 10 . '/'.('b' x 13) => 'exactly 1024 bytes',
	"/x$euro33" x 10 . '/'.("\xe2\x82\xac" x 4).'a'
		=> 'exactly 1024 bytes, multibyte',
	'/with+space'                => '"+" decodes to a space',
	'/caf%C3%A9'                 => 'URL-encoded UTF-8',
	'/a.b_c-d,e=f@g:h~i'         => 'punctuation that is allowed',
);
for my $path (sort keys %valid) {
	server_ok($e, "MKDIR $path\n", "accepted: $valid{$path}");
}
ok(-d "$data/with space", '"+" became a space on disk');
ok(-d "$data/caf\xc3\xa9", 'URL-encoded UTF-8 decoded on disk');

server_fails($e, 'MKDIR '.("/$c100" x 10).'/'.('b' x 14)."\n",
	     qr/Invalid filename/, '1025 bytes is one too many');

done_testing;
