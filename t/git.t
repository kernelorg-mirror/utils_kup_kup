#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# TAR and DIFF: the server builds the data from git_path itself, and the
# uploader signs what git would produce locally.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $fpr = $e->gen_key('alice');
$e->authorize($fpr);
my $bare = $e->git_repo('proj');
my $data = "$e->{dir}/data";

my $gunzip = sub {
	my $out;
	spawn([ 'gzip', '-cd', $_[0] ], undef, { 1 => \$out }) or
		xbail("gzip -cd $_[0] failed");
	$out;
};
my $signed = sub {
	my ($cmd, $payload, $path) = @_;
	"$cmd\n".blob(SIGN => sign_blob($e, $fpr, $payload))."PUT $path\n";
};

server_ok($e, "MKDIR /pub\n", 'create upload dir');

# Old test/3, with both a lightweight and an annotated tag
for my $ref (qw(v1 v2)) {
	my $tar = $e->git_out($bare, 'archive', '--format=tar',
			      "--prefix=proj-$ref/", $ref);
	server_ok($e, $signed->("TAR /proj.git $ref proj-$ref/", $tar,
				"/pub/proj-$ref.tar.gz"),
		  "TAR of $ref");
	is($gunzip->("$data/pub/proj-$ref.tar.gz"), $tar,
	   "TAR of $ref matches local git archive");
}

{
	my $tar = $e->git_out($bare, qw(archive --format=tar v1));
	server_ok($e, $signed->('TAR /proj.git v1 %', $tar, '/pub/noprefix.tar'),
		  'TAR with an empty prefix, stored uncompressed');
	is(read_file("$data/pub/noprefix.tar"), $tar, 'plain tar installed');
}

# Old test/7
{
	my $diff = $e->git_out($bare, qw(diff-tree -p v1 v2));
	like($diff, qr/^\+hello, world$/m, 'sanity: the diff is not empty');
	server_ok($e, $signed->('DIFF /proj.git v1 v2', $diff,
				'/pub/patch-v2.gz'),
		  'DIFF between tags');
	is($gunzip->("$data/pub/patch-v2.gz"), $diff,
	   'DIFF matches local git diff-tree');
}

my $tar = $e->git_out($bare, qw(archive --format=tar --prefix=p/ v1));
server_fails($e, $signed->('TAR /proj.git v1 q/', $tar, '/pub/x.tar.gz'),
	     qr/Signature invalid/, 'prefix is part of the signed content');

for my $t (['nosuchref', 'unknown ref'],
	   ['v1:README', 'ref to a blob'],
	   ['--output=/tmp/x', 'ref that looks like an option']) {
	server_fails($e, "TAR /proj.git $t->[0] p/\n",
		     qr/Invalid tree reference/, "TAR rejects $t->[1]");
	server_fails($e, "DIFF /proj.git v1 $t->[0]\n",
		     qr/Invalid tree reference/, "DIFF rejects $t->[1]");
}

for my $t (['/nope.git', 'missing repo'],
	   ['/proj', 'repo name without .git']) {
	server_fails($e, "TAR $t->[0] v1 p/\n", qr/No such git tree/,
		     "TAR rejects $t->[1]");
	server_fails($e, "DIFF $t->[0] v1 v2\n", qr/No such git tree/,
		     "DIFF rejects $t->[1]");
}
server_fails($e, "TAR /../git/proj.git v1 p/\n",
	     qr/Invalid pathname in TAR command/, 'TAR path escape');
server_fails($e, "TAR /proj.git v1\n", qr/Bad TAR command/,
	     'TAR without a prefix');
server_fails($e, "DIFF /proj.git v1\n", qr/Bad DIFF command/,
	     'DIFF with one ref');

done_testing;
