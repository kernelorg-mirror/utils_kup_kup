#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# MKDIR, MOVE, LINK, DELETE, DIR, INFO and general protocol handling.
# MOVE/LINK/DELETE must always act on a whole file group (stem, its
# compressed variants and its .sign), never on single members.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $fpr = $e->gen_key('alice');
$e->authorize($fpr);
my $data = "$e->{dir}/data";

my @gz_group = ('.gz', '.xz', '.sign');
my $group_is = sub {
	my ($stem, $exts, $want, $msg) = @_;
	my @have = grep { -f "$data$stem$_" } @$exts;
	is_deeply(\@have, $want ? $exts : [], $msg);
};
# Fresh plain file /pub/a.txt and compressed group /pub/b.gz
my $seed = sub {
	server_ok($e, "MKDIR /pub\n".
		  put_cmds($e, $fpr, "aaa\n", '/pub/a.txt').
		  put_cmds($e, $fpr, "bbb\n", '/pub/b.gz'),
		  'seed /pub/a.txt and /pub/b.gz');
};
$seed->();

subtest MKDIR => sub {
	server_ok($e, "MKDIR /x/y/z\n", 'MKDIR creates parents');
	ok(-d "$data/x/y/z", 'nested dir exists');
	is((stat("$data/x/y/z"))[2] & 07777, 0775, 'mode is 0777 & ~umask 002');
	server_ok($e, "MKDIR /x/y/z\n", 'MKDIR of an existing dir is fine');
	for my $ext (qw(.gz .xz .sign)) {
		server_fails($e, "MKDIR /d$ext\n",
			     qr/Protected filename space/, "MKDIR /d$ext");
	}
	server_fails($e, "MKDIR /pub/b\n",
		     qr/Filename conflict \(file and directory\)/,
		     'MKDIR over the stem of a .gz group');
};

subtest MOVE => sub {
	server_ok($e, "MOVE /pub/a.txt /pub/a2.txt\n", 'MOVE plain file');
	$group_is->('/pub/a2.txt', ['', '.sign'], 1, 'file and .sign moved');
	$group_is->('/pub/a.txt', ['', '.sign'], 0, 'old names gone');

	server_ok($e, "MOVE /pub/b.gz /pub/b2.gz\n", 'MOVE .gz group');
	$group_is->('/pub/b2', \@gz_group, 1, 'whole group moved');
	$group_is->('/pub/b', \@gz_group, 0, 'old group gone');

	server_ok($e, "MOVE /x /x2\n", 'MOVE directory');
	ok(-d "$data/x2/y/z" && !-e "$data/x", 'directory tree moved');

	server_ok($e, "MKDIR /x3\n", 'create a second dir');
	server_fails($e, "MOVE /x2 /x3\n",
		     qr/Directory MOVE destination busy/,
		     'MOVE directory onto an existing one');
	server_fails($e, "MOVE /pub/b2.gz /pub/b3\n",
		     qr/must itself end in \.gz/, 'MOVE .gz to a plain name');
	server_fails($e, "MOVE /pub/b2.xz /pub/b3.xz\n",
		     qr/auxiliary files not supported/,
		     'MOVE of a group member');
	server_fails($e, "MOVE /pub/a2.txt /pub/a.sign\n",
		     qr/auxiliary filename space/, 'MOVE onto a .sign name');
	server_fails($e, "MOVE /pub/nope /pub/nope2\n",
		     qr/MOVE of nonexistent object/, 'MOVE nonexistent');
	server_fails($e, "MOVE /pub/a2.txt\n", qr/Bad MOVE command/,
		     'MOVE with one argument');
};

subtest LINK => sub {
	server_ok($e, "LINK /pub/a2.txt /pub/a3.txt\n", 'LINK plain file');
	for my $ext ('', '.sign') {
		is((stat("$data/pub/a3.txt$ext"))[1],
		   (stat("$data/pub/a2.txt$ext"))[1],
		   "a3.txt$ext is a hard link");
	}
	server_ok($e, "LINK /pub/b2.gz /pub/b3.gz\n", 'LINK .gz group');
	$group_is->('/pub/b3', \@gz_group, 1, 'whole group linked');
	$group_is->('/pub/b2', \@gz_group, 1, 'source group kept');
	server_fails($e, "LINK /x2 /x4\n", qr/Cannot LINK a directory/,
		     'LINK directory');
};

subtest DELETE => sub {
	server_ok($e, "DELETE /pub/a3.txt\n", 'DELETE plain file');
	$group_is->('/pub/a3.txt', ['', '.sign'], 0, 'file and .sign gone');
	server_ok($e, "DELETE /pub/b3.gz\n", 'DELETE .gz group');
	$group_is->('/pub/b3', \@gz_group, 0, 'whole group gone');

	server_ok($e, "DELETE /x3\n", 'DELETE empty directory');
	ok(!-e "$data/x3", 'directory gone');
	server_fails($e, "DELETE /x2\n", qr/DELETE of directory failed/,
		     'DELETE non-empty directory');
	for my $aux (qw(/pub/a2.txt.sign /pub/b2.xz)) {
		server_fails($e, "DELETE $aux\n",
			     qr/auxiliary files not supported/,
			     "DELETE $aux");
	}
	server_fails($e, "DELETE /pub/nope\n",
		     qr/DELETE of nonexistent object/, 'DELETE nonexistent');
};

subtest DIR => sub {
	write_file("$data/pub/.hidden", '');
	write_file("$data/pub/has space", 'x');
	my $out = server_ok($e, "DIR /pub\n", 'DIR');
	my @lines = split(/\n/, $out, -1);
	is(shift(@lines), '+++ /pub/', 'starts with a sync marker');
	is_deeply([ splice(@lines, -2) ], ['', ''],
		  'ends with an empty terminator line');
	my @names = map { (split(/ /))[-1] } @lines;
	is_deeply(\@names, [ qw(a2.txt a2.txt.sign b2.gz b2.sign b2.xz
				has+space) ],
		  'sorted, hidden files skipped, names URL-encoded');
	like($lines[0],
	     qr/\A-rw-rw-r-- +1 \S+ +\S+ +4 \d{4}-\d\d-\d\d \d\d:\d\d:\d\d /,
	     'ls -l style fields');

	$out = server_ok($e, "DIR /\n", 'DIR / is allowed');
	like($out, qr/\A\+\+\+ \/\n/, 'root listing');
	server_fails($e, "DIR /nope\n", qr/Invalid directory in DIR command/,
		     'DIR of a missing directory');
	server_fails($e, "DIR /pub/a2.txt\n",
		     qr/Invalid directory in DIR command/, 'DIR of a file');
};

subtest protocol => sub {
	is(server_ok($e, "INFO\n", 'INFO'), "kup-server 0.3.6\n",
	   'INFO prints the version');
	server_ok($e, '', 'empty session');
	server_ok($e, "\n  \n# a comment\nMKDIR /c1\n", 'blank and # lines');
	ok(-d "$data/c1", 'command after comments ran');
	server_ok($e, "MKDIR /d1\nDONE\nMKDIR /d2\n", 'DONE');
	ok(-d "$data/d1" && !-e "$data/d2", 'nothing after DONE runs');
	server_fails($e, "FROB /x\n", qr/Invalid command/, 'unknown command');
	server_fails($e, "mkdir /x\n", qr/Syntax error/,
		     'commands are upper case');
	server_fails($e, 'MKDIR /'.('a' x 4096)."\n", qr/Invalid command/,
		     'overlong command line');
};

done_testing;
