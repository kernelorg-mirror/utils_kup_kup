#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# DATA / SIGN / PUT: what lands in data_path, and what is refused
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $fpr = $e->gen_key('alice');
$e->authorize($fpr);
my $data = "$e->{dir}/data";

my $zcat = sub {
	my ($cmd, $file) = @_;
	my $out;
	spawn([ $cmd, '-cd', $file ], undef, { 1 => \$out }) or
		xbail("$cmd -cd $file failed");
	$out;
};
my $zip = sub {
	my ($cmd, $payload) = @_;
	my $out;
	spawn([ $cmd, '-c' ], undef, { 0 => $payload, 1 => \$out }) or
		xbail("$cmd -c failed");
	$out;
};

server_ok($e, "MKDIR /test\n", 'create upload dir');

{
	my $payload = "abcd\n";
	my $stream = put_cmds($e, $fpr, $payload, '/test/abcd.txt');
	server_ok($e, $stream, 'plain upload');
	is(read_file("$data/test/abcd.txt"), $payload, 'content installed');
	like(read_file("$data/test/abcd.txt.sign"),
	     qr/\A-----BEGIN PGP SIGNATURE-----/, 'signature installed');
	ok(!-e "$data/test/abcd.txt.gz", 'plain upload is not compressed');
	is((stat("$data/test/abcd.txt"))[9],
	   (stat("$data/test/abcd.txt.sign"))[9],
	   'file and signature share an mtime');

	$payload = "abcd, take two\n";
	server_ok($e, put_cmds($e, $fpr, $payload, '/test/abcd.txt'),
		  'plain upload over an existing file');
	is(read_file("$data/test/abcd.txt"), $payload, 'content replaced');
}

# Old test/8 and friends: the server must not care whether data is text
for my $t (["no newline", 'nonewline'],
	   [join('', map { chr } 0..255) x 4, 'binary'],
	   ['', 'empty']) {
	my ($payload, $name) = @$t;
	server_ok($e, put_cmds($e, $fpr, $payload, "/test/$name"),
		  "$name upload");
	is(read_file("$data/test/$name"), $payload,
	   "$name content is byte-identical");
}

{
	my $payload = join('', map { "line $_\n" } 1..1000);
	server_ok($e, put_cmds($e, $fpr, $payload, '/test/big.txt.gz'),
		  'upload to .gz name');
	ok(!-e "$data/test/big.txt", 'no plain file for .gz upload');
	is($zcat->('gzip', "$data/test/big.txt.gz"), $payload,
	   '.gz made by the server');
	is($zcat->('xz', "$data/test/big.txt.xz"), $payload,
	   '.xz made by the server');
	ok(-f "$data/test/big.txt.sign", 'one .sign for the whole group');

	# Old test/9 and test/17: compressed on the wire, signed uncompressed
	for my $z (['gzip', 'gz'], ['xz', 'xz']) {
		my ($cmd, $fmt) = @$z;
		server_ok($e, put_cmds($e, $fpr, $payload,
				       "/test/from-$fmt.gz",
				       wire => $zip->($cmd, $payload),
				       fmt => $fmt),
			  "$fmt-compressed DATA");
		is($zcat->('gzip', "$data/test/from-$fmt.gz"), $payload,
		   "$fmt-compressed DATA is stored decompressed+recompressed");
	}
	server_fails($e, blob(DATA => 'x', 'bz2'),
		     qr/Unsupported compression format/,
		     'compressor not in config is refused');
}

# Plain and compressed forms of one stem can't live side by side
server_fails($e, put_cmds($e, $fpr, 'x', '/test/abcd.txt.gz'),
	     qr/Filename conflict/, '.gz upload over a plain file');
server_fails($e, put_cmds($e, $fpr, 'x', '/test/big.txt'),
	     qr/Filename conflict/, 'plain upload over a .gz group');
ok(!-e "$data/test/abcd.txt.xz" && !-e "$data/test/big.txt",
   'conflicting uploads installed nothing');

for my $aux (qw(/test/foo.sign /test/foo.xz)) {
	server_fails($e, put_cmds($e, $fpr, 'x', $aux),
		     qr/Cannot install auxiliary files directly/,
		     "PUT $aux refused");
}

server_ok($e, "MKDIR /test/dir\n", 'create a dir');
server_fails($e, put_cmds($e, $fpr, 'x', '/test/dir'),
	     qr/Trying to overwrite a non-file/, 'PUT over a directory');

server_fails($e, "PUT /test/x\n", qr/PUT without DATA/, 'PUT without DATA');
server_fails($e, blob(DATA => 'x')."PUT /test/x\n", qr/PUT without SIGN/,
	     'PUT without SIGN');
server_fails($e, put_cmds($e, $fpr, 'x', '/test/once')."PUT /test/twice\n",
	     qr/PUT without DATA/, 'a PUT consumes its DATA and SIGN');
ok(-f "$data/test/once" && !-e "$data/test/twice",
   'first PUT of the session still installed');

server_fails($e, "DATA 10 %\nshort", qr/End of stream before end of DATA/,
	     'truncated DATA');
server_fails($e, "DATA ten %\n", qr/Bad DATA command/, 'non-numeric length');
server_fails($e, "DATA 10\n", qr/Bad DATA command/, 'missing format');

{
	my $small = kup_env(cfg => { 'limits.max_data' => 1024 });
	my $sfpr = $small->gen_key('alice');
	$small->authorize($sfpr);
	my ($ok, undef, $err) = kup_server($small, "MKDIR /t\n".
			      put_cmds($small, $sfpr, 'x' x 2048, '/t/big'));
	ok(!$ok, 'DATA over max_data is refused');
	ok(!-e "$small->{dir}/data/t/big", 'oversized DATA not installed');

	local $TODO = 'RLIMIT_FSIZE kills the server with SIGXFSZ';
	like($err, qr/\S/, 'uploader is told why the session ended');
	opendir(my $dh, "$small->{dir}/tmp") or xbail("opendir: $!");
	is_deeply([ grep(!/\A\.\.?\z/, readdir($dh)) ], [],
		  'no session debris left in tmp_path');
}

done_testing;
