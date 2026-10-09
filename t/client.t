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

# Stands in for ssh: records its arguments and the stream it was sent
my $rec = "$dir/rec-ssh";
write_file($rec, "#!/bin/sh\nprintf '%s\\n' \"\$\@\" >$rec.args\n".
		 "cat >$rec.stdin\n");
chmod(0755, $rec);
my $via_rec = sub {
	my ($env, @args) = @_;
	unlink("$rec.args", "$rec.stdin");
	my ($ok, $out, $err) = kup_client($e, $env, @args);
	ok($ok, "kup @args") or diag("stderr: $err");
	(-e "$rec.args" ? read_file("$rec.args") : undef, $err);
};

subtest 'global options' => sub {
	my $no_env = { KUP_HOST => undef };
	for my $o ([qw(-o cli.example.org)], ['--host=cli.example.org'],
		   [qw(--host cli.example.org)]) {
		my ($args) = $via_rec->({ KUP_RSH => $rec }, @$o, 'info');
		is($args, "cli.example.org\n", "@$o overrides KUP_HOST");
	}
	for my $o ([ '-e', $rec ], [ "--rsh=$rec" ], [ '--ssh', $rec ]) {
		my ($args) = $via_rec->($no_env, @$o, qw(-o h info));
		is($args, "h\n", "@$o sets the rsh command");
	}
	for my $o ([qw(-c gl-kup)], ['--subcmd=gl-kup']) {
		my ($args) = $via_rec->({ KUP_RSH => $rec }, @$o, 'info');
		is($args, "kup.example.org\ngl-kup\n", "@$o sets the subcmd");
	}
	is(read_file("$rec.stdin"), "INFO\n", 'stream reached the rsh');

	write_file("$e->{home}/.kuprc",
		   "host = rc.example.org\nrsh = $rec\nsubcmd = rc-sub\n");
	my ($args) = $via_rec->($no_env, 'info');
	is($args, "rc.example.org\nrc-sub\n", 'host, rsh, subcmd from .kuprc');
	($args) = $via_rec->({ KUP_SUBCMD => 'env-sub' }, 'info');
	is($args, "kup.example.org\nenv-sub\n",
	   'KUP_HOST and KUP_SUBCMD override .kuprc');
	unlink("$e->{home}/.kuprc");

	(undef, my $err) = $via_rec->({ KUP_RSH => $rec }, qw(-v mkdir /a));
	is($err, "MKDIR /a\n", '-v echoes commands to stderr');

	my ($ok, $out, $usage) = kup_client($e, '-h');
	ok($ok && $usage =~ /\AUsage: .*^Commands:/ms, '-h shows usage');

	($ok, undef, $err) = kup_client($e, { KUP_RSH => "$rec;id" }, 'info');
	ok(!$ok && $err =~ /suspicious KUP_RSH/, 'shell metachar in rsh');
};

subtest 'usage errors' => sub {
	for my $args ([], [qw(put a.txt)], [qw(put a.txt a.txt.sign)],
		      [qw(put --tar /p.git)], [qw(put --diff /p.git v1)],
		      ['mkdir'], ['rm'], [qw(mv /a)]) {
		my ($ok, $out, $err) = kup_client($e, '-b', @$args);
		ok(!$ok && $? >> 8 == 1 && $err =~ /\AUsage:/,
		   "usage for: kup @$args") or diag($err);
	}
	$client_fails->(qr/unknown option to put command: --frob/,
			'unknown put option', qw(put --frob x y /z));
	$client_fails->(qr/not a plain file: \./, 'put of a directory',
			qw(put . a.txt.sign /x));
	$client_fails->(qr/invalid path name for git tree/,
			'put --diff of a non-.git tree',
			qw(put --diff /p v1 v2 a.txt.sign /x.gz));
	$client_fails->(qr/invalid ref: v\x01/, 'control char in TAR ref',
			'put', '--tar', '/p.git', "v\x01", 'a.txt.sign', '/x');
	for my $i (0, 1) {
		my @refs = ('v1', 'v2');
		$refs[$i] = "v\x01";
		$client_fails->(qr/invalid ref: v\x01/,
				"control char in DIFF ref ".($i + 1),
				'put', '--diff', '/p.git', @refs,
				'a.txt.sign', '/x');
	}
	for my $args ([qw(rm /.x)], [qw(mv /.x /y)], [qw(mv /y /.x)],
		      [qw(ls /.x)]) {
		$client_fails->(qr/invalid pathname: \/\.x/,
				"invalid path: kup @$args", @$args);
	}
};

subtest 'aliases and encoding' => sub {
	for my $t ([[qw(del /a)], "DELETE /a\n"],
		   [[qw(delete /a)], "DELETE /a\n"],
		   [[qw(link /a /b)], "LINK /a /b\n"],
		   [[qw(dir /a)], "DIR /a/\n"],
		   [[qw(MKDIR /a)], "MKDIR /a\n"]) {
		is($batch->(@{$t->[0]}), $t->[1], "kup @{$t->[0]}");
	}
	write_file("$dir/r.tar.bz2", 'BZ');
	like($batch->(qw(put r.tar.bz2 a.txt.sign /r.tar.bz2)),
	     qr/\ADATA 2 bz2\n.*^PUT \/r\.tar\.gz\n\z/ms, 'bz2 upload');
	like($batch->('put', 'a.txt', 'a.txt.sign', "/caf\xc3\xa9%"),
	     qr/^PUT \/caf%C3%A9%25\n\z/m, 'non-ASCII and % are %-encoded');
};

subtest 'end to end over a fake ssh' => sub {
	my $fpr = $e->gen_key('alice');
	$e->authorize($fpr);
	write_file("$dir/a.txt.sign", sign_blob($e, $fpr, "abcd\n"));
	# Stands in for ssh: records its arguments, then runs the server
	my $rsh = "$dir/fake-ssh";
	write_file($rsh, "#!/bin/sh\nprintf '%s\\n' \"\$\@\" >$rsh.args\n".
			 "exec @{[ perl_cmd() ]} $e->{server}\n");
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

	# Release scripts do "kup put ... && announce", so failures must
	# show up in the exit status
	local $TODO = 'close_output() ignores the rsh exit status';
	write_file("$dir/bad.sign", sign_blob($e, $fpr, "not abcd\n"));
	($ok, undef, $err) = kup_client($e, { KUP_RSH => $rsh },
					qw(put a.txt bad.sign /pub/bad));
	ok(!$ok, 'server-side failure makes kup fail') or diag($err);
	($ok) = kup_client($e, { KUP_RSH => "$dir/no-such-ssh" }, 'info');
	ok(!$ok, 'missing rsh command makes kup fail');
};

done_testing;
