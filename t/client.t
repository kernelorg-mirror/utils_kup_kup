#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The kup client: command-line parsing, path canonicalization, and the
# exact protocol stream it produces.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $dir = $e->{dir};
write_file("$dir/a.txt", "abcd\n");
write_file("$dir/a.txt.sign", "SIG\n");
write_file("$dir/r.tar.xz", "XZDATA");
write_file("$dir/one.gz", "x");

# Batch-mode output for @args, or undef (with a failed test) on error
my $batch = sub {
	my ($ok, $out, $err) = kup_client($e, '-b', @_);
	ok($ok, "kup -b @_") or diag("stderr: $err");
	$ok ? $out : undef;
};
my $client_fails = sub {
	my ($re, $msg, @args) = @_;
	my ($ok, $out, $err) = kup_client($e, '-b', @args);
	ok(!$ok && $err =~ $re, $msg) or diag("ok=$ok stderr: $err");
	is($out, '', "$msg: nothing sent");
};

subtest put => sub {
	is($batch->(qw(put a.txt a.txt.sign /pub/)),
	   "DATA 5 %\nabcd\nSIGN 4 %\nSIG\nPUT /pub/a.txt\n",
	   'trailing slash on remote reuses the local name');
	is($batch->(qw(put r.tar.xz a.txt.sign /pub/r.tar.xz)),
	   "DATA 6 xz\nXZDATASIGN 4 %\nSIG\nPUT /pub/r.tar.gz\n",
	   'compressed file sent as-is; remote .xz becomes .gz');
	like($batch->(qw(put one.gz a.txt.sign /pub/one.gz)),
	     qr/\ADATA 1 %\n/, 'files under 2 bytes are never compressed');
	like($batch->('put', 'a.txt', 'a.txt.sign', '/pub/with space'),
	     qr/^PUT \/pub\/with\+space\n\z/m, 'remote name URL-encoded');
	like($batch->(qw(put a.txt a.txt.sign pub/./x/../a)),
	     qr/^PUT \/pub\/a\n\z/m, 'relative remote path canonicalized');

	is($batch->(qw(put --tar --prefix=p/ /proj.git v1 a.txt.sign
		       /pub/p.tar.gz)),
	   "TAR /proj.git v1 p/\nSIGN 4 %\nSIG\nPUT /pub/p.tar.gz\n",
	   'put --tar --prefix=');
	like($batch->(qw(put -t -p p/ proj.git v1 a.txt.sign /pub/p.tar.gz)),
	     qr/\ATAR \/proj.git v1 p\/\n/, 'put -t -p, relative tree');
	like($batch->(qw(put --tar /proj.git v1 a.txt.sign /pub/p.tar.gz)),
	     qr/\ATAR \/proj.git v1 %\n/, 'empty prefix is sent as %');
	like($batch->(qw(put --diff /proj.git v1 v2 a.txt.sign /pub/p.gz)),
	     qr/\ADIFF \/proj.git v1 v2\nSIGN /, 'put --diff');

	$client_fails->(qr/target filename cannot end in \.sign/,
			'put to a .sign name',
			qw(put a.txt a.txt.sign /pub/a.sign));
	$client_fails->(qr/invalid path name for git tree/,
			'put --tar of a non-.git tree',
			qw(put --tar /proj v1 a.txt.sign /pub/p.tar.gz));
	$client_fails->(qr/cannot open: nope/, 'missing local file',
			qw(put nope a.txt.sign /pub/));
	$client_fails->(qr/invalid pathname/, '.. above the root',
			qw(put a.txt a.txt.sign /../a));
};

subtest 'mv, ln, rm, mkdir' => sub {
	is($batch->(qw(mv /pub/a.txt b.txt)), "MOVE /pub/a.txt /pub/b.txt\n",
	   'mv target is relative to the source directory');
	is($batch->(qw(ln /pub/a.txt /old/)), "LINK /pub/a.txt /old/a.txt\n",
	   'ln to a directory keeps the name');
	is($batch->(qw(move /p/a.tar.bz2 /p/b.tar.xz)),
	   "MOVE /p/a.tar.gz /p/b.tar.gz\n", 'mv of compressed names');
	is($batch->(qw(rm /p/r.tar.xz)), "DELETE /p/r.tar.gz\n",
	   'rm of .xz deletes the group');
	is($batch->(qw(mkdir pub/new)), "MKDIR /pub/new\n", 'mkdir');

	$client_fails->(qr/cannot move to or from compressed/,
			'mv between compressed and plain',
			qw(mv /p/a.gz /p/a));
	$client_fails->(qr/moving filename to self/, 'mv onto itself',
			qw(mv /p/a /p/a));
	$client_fails->(qr/cannot explicitly move \.sign/, 'mv a .sign',
			qw(mv /p/a.sign /p/b.sign));
	$client_fails->(qr/cannot delete \.sign/, 'rm a .sign',
			qw(rm /p/a.sign));
	$client_fails->(qr/directory name cannot end in/, 'mkdir x.gz',
			qw(mkdir /p/x.gz));
};

subtest 'ls, info, chaining' => sub {
	is($batch->(qw(ls / /a b/)), "DIR /\nDIR /a/\nDIR /b/\n",
	   'ls with several dirs');
	is($batch->(qw(mkdir /a -- info -- ls /a)),
	   "MKDIR /a\nINFO\nDIR /a/\n", 'commands chained with --');

	$client_fails->(qr/invalid pathname/,
			'an error in any command sends nothing at all',
			qw(mkdir /a -- mkdir /.bad));
	$client_fails->(qr/garbage at end of mkdir/, 'extra argument',
			qw(mkdir /a /b));
	$client_fails->(qr/unknown command: frob/, 'unknown command',
			qw(frob));
	$client_fails->(qr/unknown option: --frob/, 'unknown option',
			qw(--frob info));

	local $TODO = 'cmd_dir() does not URL-encode its argument';
	is($batch->('ls', '/with space'), "DIR /with+space/\n",
	   'ls path URL-encoded');
};

subtest 'host configuration' => sub {
	my ($ok, undef, $err) = kup_client($e, { KUP_HOST => undef }, 'info');
	ok(!$ok && $err =~ /please specify --host/, 'no host anywhere');

	write_file("$e->{home}/.kuprc", "host = rc.example.org\n");
	($ok) = kup_client($e, { KUP_HOST => undef }, '-b', 'info');
	ok($ok, 'host from ~/.kuprc');
	unlink("$e->{home}/.kuprc");

	($ok, undef, $err) = kup_client($e, { KUP_HOST => 'a;b' }, 'info');
	ok(!$ok && $err =~ /suspicious KUP_HOST/, 'shell metachar in host');
	($ok, undef, $err) = kup_client($e, { KUP_SUBCMD => 'a;b' }, 'info');
	ok(!$ok && $err =~ /suspicious KUP_SUBCMD/,
	   'shell metachar in subcmd');

	local $TODO = '--batch never connects, but still demands a host';
	($ok) = kup_client($e, { KUP_HOST => undef }, '-b', 'info');
	ok($ok, '--batch without a host');
};

subtest 'end to end over a fake ssh' => sub {
	my $fpr = $e->gen_key('alice');
	$e->authorize($fpr);
	write_file("$dir/a.txt.sign", sign_blob($e, $fpr, "abcd\n"));
	# Stands in for ssh: records its arguments, then runs the server
	my $rsh = "$dir/fake-ssh";
	write_file($rsh, "#!/bin/sh\nprintf '%s\\n' \"\$\@\" >$rsh.args\n".
			 "exec $^X -T $e->{server}\n");
	chmod(0755, $rsh);

	my ($ok, $out, $err) = kup_client($e,
		{ KUP_RSH => $rsh, KUP_SUBCMD => 'kup-server' },
		qw(mkdir /pub -- put a.txt a.txt.sign /pub/ -- ls /pub));
	ok($ok, 'mkdir, put and ls in one session') or diag("stderr: $err");
	is(read_file("$rsh.args"), "kup.example.org\nkup-server\n",
	   'rsh gets the host, then the subcmd');
	is(read_file("$e->{dir}/data/pub/a.txt"), "abcd\n", 'file uploaded');
	like($out, qr/^\+\+\+ \/pub\/\n.* a\.txt\n.* a\.txt\.sign\n\n\z/sm,
	     'ls output came back');
};

done_testing;
