#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The gitolite auth backend: one shared Unix account, GL_USER says who the
# uploader is, and gitolite rules on the fake repo "@kup-server" say what
# they may do.  The rules below follow the kernel.org kup.conf.
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));
require_cmd($_) for qw(gpg gpgv gzip xz git);
require_gitolite();

my $e = kup_env(gitolite => 1);
my $data = "$e->{dir}/data";
# Before the rules, or compiling them makes an empty repo in its place
my $linux = $e->git_repo('linux');
# Passes check_ref (it's a tag) but makes "git archive" fail
spawn([ qw(git tag -a -m blob blobtag v1:README) ],
      { GIT_DIR => $linux, GIT_CONFIG_NOSYSTEM => 1,
	GIT_CONFIG_GLOBAL => '/dev/null', GIT_COMMITTER_NAME => 'Kup Test',
	GIT_COMMITTER_EMAIL => 'test@example.org' }) or xbail('git tag');
$e->gitolite_conf(<<'EOF');
@uploaders = alice bob carol d.ot

repo @kup-server
    R    = @uploaders
    RW+C testing/ = @uploaders
    RW+C pub/people/USER/ = @uploaders
    RW   pub/alice-only/ = alice
    RW+C pub/tools/ = bob

repo linux
    R    = alice
EOF
mkdir("$data/$_") or xbail("mkdir $_: $!")
	for qw(testing pub pub/people pub/people/alice pub/alice-only
	       pub/people/d.ot pub/people/dXot);

my %fpr;
for my $u (qw(alice bob carol mallory d.ot)) {
	$fpr{$u} = $e->gen_key($u);
	local $e->{user} = $u;
	$e->authorize($fpr{$u});
}

my $put = sub {
	my ($u, $path) = @_;
	put_cmds($e, $fpr{$u}, "$u was here\n", $path);
};
# [ user, stream, undef for success or the expected error, description ]
my $check = sub {
	for my $c (@_) {
		my ($u, $stream, $re, $msg) = @$c;
		local $e->{user} = $u;
		$re ? server_fails($e, $stream, $re, "$u: $msg")
		    : server_ok($e, $stream, "$u: $msg");
	}
};
my $denied = sub { qr/^Permission denied: \Q$_[0]\E$/m };

subtest 'put and mkdir' => sub {
	$check->(
		[ alice => $put->(alice => '/testing/a'), undef,
		  'rule for a group' ],
		[ mallory => $put->(mallory => '/testing/m'),
		  $denied->('put /testing/m'), 'no rules at all' ],
		[ alice => $put->(alice => '/pub/people/alice/x.gz'), undef,
		  'USER is the uploader' ],
		[ bob => $put->(bob => '/pub/people/alice/y'),
		  $denied->('put /pub/people/alice/y'),
		  "USER isn't anyone else" ],
		[ alice => $put->(alice => '/pub/alice-only/x'), undef,
		  'W allows PUT' ],
		[ alice => "MKDIR /pub/alice-only/d\n",
		  $denied->('mkdir /pub/alice-only/d'), "W doesn't allow MKDIR" ],
		[ alice => "DELETE /pub/alice-only/x\n",
		  $denied->('delete /pub/alice-only/x'), "or DELETE" ],
		[ alice => "MKDIR /pub/tools\n", $denied->('mkdir /pub/tools'),
		  "no rule, no MKDIR" ],
		# "pub/tools/" must match the directory itself, too
		[ bob => "MKDIR /pub/tools\n", undef, 'C on the dir itself' ],
		# Valid for kup, but gitolite dies on non-ASCII ref names
		[ alice => "MKDIR /testing/%C3%A9\n",
		  $denied->("mkdir /testing/\xc3\xa9"), 'names gitolite rejects' ],
		[ alice => "MKDIR /testing/a=b\n", $denied->('mkdir /testing/a=b'),
		  'such as = (documented in kup-server.1)' ],
		[ alice => "MKDIR /testing/a~b\n", $denied->('mkdir /testing/a~b'),
		  'and ~' ],
		[ 'd.ot' => $put->('d.ot' => '/pub/people/d.ot/f'), undef,
		  'USER with a dot in it' ],
		# gitolite puts the name into the rule as a regex
		[ 'd.ot' => $put->('d.ot' => '/pub/people/dXot/f'),
		  $denied->('put /pub/people/dXot/f'),
		  'the dot in USER only matches a dot' ],
		[ bob => "MKDIR /pub/tools/sub\n", undef, 'C below it' ],
		[ bob => $put->(bob => '/pub/tools/a.gz'), undef, 'W below it' ],
	);
	ok(-d "$data/pub/tools/sub", 'directories made');
	ok(-f "$data/pub/people/alice/x.xz", 'compressed group installed');
	ok(!-e "$data/pub/people/alice/y", 'denied PUT left nothing');
};

subtest 'move, link and delete' => sub {
	$check->(
		[ bob => "MOVE /pub/tools/a.gz /pub/tools/b.gz\n", undef,
		  'MOVE within own area' ],
		[ alice => "MOVE /pub/tools/b.gz /testing/b.gz\n",
		  $denied->('delete /pub/tools/b.gz'), 'MOVE needs + on the source' ],
		[ alice => "MOVE /testing/a /pub/tools/a\n",
		  $denied->('put /pub/tools/a'), 'and W on the target' ],
		[ alice => "MOVE /testing/a /pub/alice-only/a\n", undef,
		  'MOVE with both' ],
		# Everything under data_path is public anyway
		[ alice => "LINK /pub/tools/b.gz /testing/b.gz\n", undef,
		  'LINK needs only W on the target' ],
		[ alice => "LINK /testing/b.gz /pub/tools/c.gz\n",
		  $denied->('put /pub/tools/c.gz'), "and doesn't work without it" ],
		[ carol => "DELETE /pub/tools/b.gz\n",
		  $denied->('delete /pub/tools/b.gz'), "can't DELETE others' files" ],
		[ bob => "DELETE /pub/tools/b.gz\n", undef, 'DELETE with +' ],
		# alice may make directories in testing/ but not in alice-only/
		[ alice => "MKDIR /testing/d\nMOVE /testing/d /pub/alice-only/d\n",
		  $denied->('mkdir /pub/alice-only/d'),
		  'MOVE of a directory needs C on the target' ],
		[ bob => "MKDIR /pub/tools/d1\nMOVE /pub/tools/d1 /pub/tools/d2\n",
		  undef, 'and works with it' ],
	);
	ok(!-e "$data/pub/alice-only/d", 'denied directory MOVE left nothing');
	ok(-d "$data/pub/tools/d2", 'directory moved');
	ok(-f "$data/pub/alice-only/a", 'moved');
	ok(-f "$data/testing/b.xz", 'linked group');
	ok(!-e "$data/pub/tools/b.gz" && !-e "$data/pub/tools/b.sign",
	   'deleted group');
	ok(!-e "$data/pub/tools/c.gz", 'denied LINK left nothing');
};

subtest 'read access' => sub {
	$check->(
		[ carol => "DIR /pub\n", undef, 'R allows DIR' ],
		[ mallory => "DIR /\n", $denied->('list /'), 'no R, no DIR' ],
		[ alice => "TAR /linux.git v1 %\n", undef,
		  'TAR from a readable repo' ],
		# Git.pm reports errors as exception objects, which gitolite's
		# die handler would turn into strings that escape git_cmd_try
		[ alice => "TAR /linux.git blobtag %\n",
		  qr/^Failed to acquire tarball$/m, 'git errors still work' ],
		[ bob => "TAR /linux.git v1 %\n", $denied->('read /linux.git'),
		  'TAR needs gitolite read access' ],
		[ bob => "DIFF /linux.git v1 v2\n", $denied->('read /linux.git'),
		  'so does DIFF' ],
		[ alice => "TAR /gitolite-admin.git master %\n",
		  $denied->('read /gitolite-admin.git'),
		  'the admin repo is off limits' ],
		[ bob => "TAR /nope.git v1 %\n", $denied->('read /nope.git'),
		  "denied before saying the repo doesn't exist" ],
		[ alice => "TAR /no+repo.git v1 %\n",
		  $denied->('read /no repo.git'), 'repo names gitolite rejects' ],
	);
};

subtest INFO => sub {
	local $e->{user} = 'alice';
	my $out = server_ok($e, "INFO\n", 'INFO');
	like($out, qr/^kup-server \S+/, 'version first');
	like($out, qr{^ls\s+/\*$}m, 'R rule');
	like($out, qr{^put/rm/mv/mkdir\s+/testing/\*$}m, 'RW+C rule');
	like($out, qr{^put/rm/mv/mkdir\s+/pub/people/alice/\*$}m,
	     'USER expanded');
	like($out, qr{^put\s+/pub/alice-only/\*$}m, 'RW rule');
	unlike($out, qr{/pub/tools}, "bob's rules not shown");
};

subtest environment => sub {
	local $e->{user} = 'alice';
	my $run = sub {
		my ($env, $re, $msg) = @_;
		my ($ok, $out, $err) = kup_server($e, "DIR /\n", { -env => $env });
		$re ? ok(!$ok && $err =~ $re, $msg) || diag("stderr: $err")
		    : ok($ok, $msg) || diag("stderr: $err");
	};
	for my $u (undef, '', '../alice', "alice\n", 'al/ice', '@admins',
		   '-alice') {
		$run->({ GL_USER => $u }, qr/Missing or invalid GL_USER/,
		       'GL_USER '.($u // 'unset').' rejected');
	}
	for my $v (qw(HOME GL_LIBDIR)) {
		$run->({ $v => undef }, qr/Missing or invalid $v/, "$v unset");
		$run->({ $v => 'relative' }, qr/Missing or invalid $v/,
		       "$v relative");
	}
	$run->({ GL_LIBDIR => "$e->{dir}/nope" },
	       qr/Cannot load the gitolite libraries/, 'GL_LIBDIR without gitolite');
	# The sig-note-to-kup cron job calls kup-server directly, without
	# GL_BINDIR.  Gitolite::Rc puts that in front of PATH anyway, which
	# taint mode refuses on the first exec, so a DIR alone proves nothing
	my ($ok, undef, $err) = kup_server($e, $put->(alice => '/testing/nobindir'),
					   { -env => { GL_BINDIR => undef } });
	ok($ok, 'GL_BINDIR is optional, even for a PUT') or diag("stderr: $err");

	# Gitolite::Rc runs the file named in G3T_RC
	my $evil = "$e->{dir}/evil.rc";
	write_file($evil, "open(my \$fh, '>', '$e->{dir}/pwned'); 1;\n");
	$run->({ G3T_RC => $evil }, undef, 'G3T_RC in the environment');
	ok(!-e "$e->{dir}/pwned", '... is not run');
};

done_testing;
