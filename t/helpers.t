#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# gpg-sign-all (uploader side) and genrings (admin side), checked against
# what kup-server actually accepts
use strict;
use v5.10.1;
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));
require_cmd($_) for qw(gpg gpgv gpg-agent gpg-connect-agent gzip xz);

my $e = kup_env();
my $dir = $e->{dir};
my $alice = $e->gen_key('alice');
my $alice2 = $e->gen_key('alice-laptop');
my $bob = $e->gen_key('bob');
my $gpg_env = { GNUPGHOME => $e->{gpg_home} };

my $run = sub {
	my ($cmd, $msg) = @_;
	my ($out, $err);
	my $ok = spawn($cmd, $gpg_env, { 1 => \$out, 2 => \$err });
	ok($ok, $msg) or diag("stderr: $err");
	$err;
};
my $verifies = sub {
	my ($ring, $sig, $file) = @_;
	spawn([ 'gpgv', '--keyring', $ring, $sig, $file ], $gpg_env);
};
# gpg-connect-agent exits 0 even when no agent is running, so ask for a pid
my $agent_alive = sub {
	my $out;
	spawn([ 'gpg-connect-agent', '--no-autostart', 'GETINFO pid', '/bye' ],
	      $gpg_env, { 1 => \$out, 2 => \my $err });
	($out // '') =~ /^D \d+$/m;
};

subtest genrings => sub {
	# An already-expired key: made "in the past" with a 1-day lifetime
	my $old;
	$e->gpg([ '--faked-system-time', '20200101T000000!',
		  '--quick-generate-key', 'old <old@example.org>', 'ed25519',
		  'sign', '1d' ]) or xbail('expired key generation failed');
	$e->gpg([ '--with-colons', '--list-keys', '=old <old@example.org>' ],
		{ 1 => \$old });
	($old) = ($old =~ /^fpr:(?:[^:]*:){8}([0-9A-F]+):/m);

	# gpg leaves a revocation certificate for every key it makes; it
	# is "disarmed" with a leading colon so it can't be imported by
	# accident
	my $revoked = $e->gen_key('revoked');
	(my $rev = read_file("$e->{gpg_home}/openpgp-revocs.d/$revoked.rev"))
		=~ s/^:(-----BEGIN)/$1/m;
	$e->gpg([ '--import' ], { 0 => $rev }) or xbail('revocation failed');

	write_file("$dir/users", <<EOF);
# comment lines and junk are ignored
alice $alice extra fields are fine
alice $alice2
bob $bob
expired $old
revoked $revoked
mallory 0123456789ABCDEF
EOF
	$run->([ "$KupTest::TOPDIR/genrings", "$dir/users", "$dir/rings" ],
	       'genrings');
	my @rings = map { m!/([^/]+)\.gpg\z! } glob("$dir/rings/*.gpg");
	is_deeply(\@rings, [qw(alice bob)],
		  'rings only for users with a usable key');

	my $out;
	$e->gpg([ '--no-default-keyring', '--keyring', "$dir/rings/alice.gpg",
		  '--with-colons', '--list-keys' ], { 1 => \$out });
	my @fprs = sort($out =~ /^fpr:(?:[^:]*:){8}([0-9A-F]+):/mg);
	is_deeply(\@fprs, [ sort($alice, $alice2) ],
		  "alice's ring holds both her keys and nothing else");

	# The real test: kup-server accepts uploads checked against it
	rename("$dir/rings/alice.gpg", "$dir/pgp/$e->{user}.gpg") or
		xbail("rename: $!");
	server_ok($e, put_cmds($e, $alice2, "ok\n", '/from-genrings'),
		  'genrings keyring works with kup-server');
	server_fails($e, put_cmds($e, $bob, "no\n", '/from-bob'),
		     qr/Signature invalid/, "bob can't sign as alice");
};

subtest 'gpg-sign-all' => sub {
	my $payload = "release tarball\n";
	for my $z (['gzip', 'gz'], ['xz', 'xz']) {
		write_file("$dir/rel-$z->[1].tar", $payload);
		spawn([ $z->[0], "$dir/rel-$z->[1].tar" ]) or
			xbail("$z->[0] failed");
	}
	write_file("$dir/notes.txt", "notes\n");

	ok($agent_alive->(), 'sanity: our gpg-agent is running');
	$run->([ "$KupTest::TOPDIR/gpg-sign-all", '-u', $alice,
		 map { "$dir/$_" } qw(rel-gz.tar.gz rel-xz.tar.xz notes.txt) ],
	       'gpg-sign-all');

	my $ring = "$dir/pgp/$e->{user}.gpg";
	for my $f (qw(rel-gz.tar rel-xz.tar)) {
		ok(-f "$dir/$f.sign", "$f.sign made, not $f.gz.sign");
		write_file("$dir/$f.plain", $payload);
		ok($verifies->($ring, "$dir/$f.sign", "$dir/$f.plain"),
		   "$f.sign covers the uncompressed content");
	}
	ok($verifies->($ring, "$dir/notes.txt.sign", "$dir/notes.txt"),
	   'plain file signed as-is');

	server_ok($e, blob(DATA => read_file("$dir/rel-xz.tar.xz"), 'xz').
		  blob(SIGN => read_file("$dir/rel-xz.tar.sign")).
		  "PUT /rel.tar.gz\n",
		  'kup-server accepts what gpg-sign-all made');

	local $TODO = 'gpg >= 2.1 refuses the private agent; kill hits ours';
	ok($agent_alive->(), 'a gpg-agent that was already running survives');
};

done_testing;
