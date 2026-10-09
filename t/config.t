#!perl -w
# SPDX-License-Identifier: GPL-2.0-or-later
#
# kup-server.cfg variants, timeouts, compressor failures and locking
use strict;
use v5.10.1;
use Fcntl qw(:flock);
use Time::HiRes qw(time);
use KupTest;
require_mods(qw(Config::Simple BSD::Resource Git));

my $e = kup_env();
my $fpr = $e->gen_key('alice');
$e->authorize($fpr);
my $dir = $e->{dir};
my $data = $e->{data};
my $payload = "compress me\n" x 100;
my $gzip = require_cmd('gzip');
my $xz = require_cmd('xz');

server_ok($e, "MKDIR /t\n", 'create upload dir');

subtest 'compressor configuration' => sub {
	# The pre-0.3.6 style: a path per format, -9 and -cd get appended
	$e->set_cfg('compressors.gz' => $gzip, 'compressors.xz' => $xz,
		    map { ("$_.compress_command" => undef,
			   "$_.decompress_command" => undef) } qw(gz xz));
	server_ok($e, put_cmds($e, $fpr, $payload, '/t/old-style.gz'),
		  'old-style [compressors] paths');
	ok(-f "$data/t/old-style.gz" && -f "$data/t/old-style.xz",
	   'both formats made');
	$e->set_cfg('compressors.gz' => undef, 'compressors.xz' => undef,
		    'gz.compress_command' => "$gzip -9",
		    'gz.decompress_command' => "$gzip -cd",
		    'xz.compress_command' => "$xz -6",
		    'xz.decompress_command' => "$xz -cd");

	$e->set_cfg('compressors.use' => 'gz, xz, zst');
	server_fails($e, "INFO\n",
		     qr/Compressor zst requested, but commands not specified/,
		     'compressor in "use" without commands');

	$e->set_cfg('compressors.use' => 'gz');
	server_ok($e, put_cmds($e, $fpr, $payload, '/t/gz-only.gz'),
		  'a single compressor');
	ok(-f "$data/t/gz-only.gz" && !-e "$data/t/gz-only.xz",
	   'only the configured format made');
	$e->set_cfg('compressors.use' => undef);
	SKIP: {
		skip('/usr/bin/bzip2 missing for built-in defaults', 2)
			if !-x '/usr/bin/bzip2' || !-x '/bin/gzip';
		server_ok($e, put_cmds($e, $fpr, $payload, '/t/defaults.gz'),
			  'no "use" key: built-in gz, bz2, xz');
		ok(-f "$data/t/defaults.bz2", 'built-in default made .bz2');
	}
	$e->set_cfg('compressors.use' => 'gz, xz');
};

subtest 'compressor failures' => sub {
	my $slow = "$dir/slow-compressor";
	write_file($slow, "#!/bin/sh\nexec sleep 30\n");
	chmod(0755, $slow);

	$e->set_cfg('xz.compress_command' => require_cmd('false'));
	server_fails($e, put_cmds($e, $fpr, $payload, '/t/fail.gz'),
		     qr/Failed to compress output data/, 'compressor fails');
	ok(!glob("$data/t/fail.*"), 'nothing installed');

	$e->set_cfg('xz.compress_command' => $slow,
		    'limits.timeout_compress' => 1);
	my $t0 = time;
	server_fails($e, put_cmds($e, $fpr, $payload, '/t/slow.gz'),
		     qr/Timeout compressing output data/,
		     'compressor timeout');
	cmp_ok(time - $t0, '<', 10, 'did not wait for the compressor');
	ok(!glob("$data/t/slow.*"), 'nothing installed');
	$e->set_cfg('xz.compress_command' => "$xz -6",
		    'limits.timeout_compress' => 60);
};

subtest timeouts => sub {
	$e->set_cfg('limits.timeout_command' => 1, 'limits.timeout_data' => 1);
	my ($ok, undef, $err) = kup_server($e, "MKDIR /t/idle\n",
					   { -hold_stdin => 1 });
	ok(!$ok && $err =~ /Timeout waiting for command/,
	   'idle session times out') or diag($err);
	ok(-d "$data/t/idle", 'commands before the timeout ran');

	($ok, undef, $err) = kup_server($e, "DATA 100 %\nonly some",
					{ -hold_stdin => 1 });
	ok(!$ok && $err =~ /Timeout waiting for data/, 'stalled DATA')
		or diag($err);
	$e->set_cfg('limits.timeout_command' => 30, 'limits.timeout_data' => 30);
};

subtest paths => sub {
	my $user_tmp = "$dir/tmp/$e->{user}";
	$e->set_cfg('paths.tmp_path' => "$dir/tmp/");
	server_fails($e, "INFO\n", qr/Parent directory \(\Q$user_tmp\E\)/,
		     'per-user tmp_path needs a dir for the user');
	mkdir($user_tmp, 0700) or xbail("mkdir $user_tmp: $!");
	server_ok($e, put_cmds($e, $fpr, 'x', '/t/per-user'),
		  'upload with per-user tmp_path');
	$e->set_cfg('paths.tmp_path' => "$dir/tmp");

	$e->set_cfg('paths.lock_file' => "$dir/nope");
	server_ok($e, "INFO\n", 'lock file is only needed to change the tree');
	server_fails($e, "MKDIR /t/nolock\n", qr/Cannot open lock file/,
		     'missing lock file');
	$e->set_cfg('paths.lock_file' => "$dir/lock");

	rename($e->{cfg}, "$e->{cfg}.bak") or xbail("rename: $!");
	server_fails($e, "INFO\n", qr/Error reading config file/,
		     'missing config file');
	rename("$e->{cfg}.bak", $e->{cfg}) or xbail("rename: $!");
};

subtest 'auth backend' => sub {
	# Under gitolite everyone is the same Unix user, so the unix backend
	# there would mean no access control at all
	for my $gl_user ('mallory', '') {
		my ($ok, $out, $err) = kup_server($e, "MKDIR /t/gl\n",
			{ -env => { GL_USER => $gl_user } });
		ok(!$ok && $err =~ /GL_USER is set, but the auth backend is not gitolite/,
		   "unix backend refuses GL_USER='$gl_user'") or diag("stderr: $err");
	}
	ok(!-e "$data/t/gl", '... before doing anything');
	server_ok($e, "MKDIR /t/gl\n", 'and works without it');

	$e->set_cfg('auth.backend' => 'ldap');
	server_fails($e, "DIR /\n", qr/Unknown auth backend: ldap/,
		     'unknown backend');
	$e->set_cfg('auth.backend' => undef);
};

subtest locking => sub {
	# A child holds the tree lock for a while; the server must wait
	open(my $lock, '<', "$dir/lock") or xbail("open lock: $!");
	flock($lock, LOCK_EX) or xbail("flock: $!");
	my $pid = fork() // xbail("fork: $!");
	if ($pid == 0) {
		select(undef, undef, undef, 1.5);
		POSIX::_exit(0);	# releases the inherited lock
	}
	close($lock);
	my $t0 = time;
	server_ok($e, "MKDIR /t/locked\n", 'MKDIR while the tree is locked');
	cmp_ok(time - $t0, '>=', 1, 'waited for the lock holder');
	waitpid($pid, 0);
};

done_testing;
