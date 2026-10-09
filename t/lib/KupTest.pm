# SPDX-License-Identifier: GPL-2.0-or-later
#
# Shared helpers for the t/*.t tests, modelled on PublicInbox::TestCommon.
# Every test builds a throwaway kup "world" (data tree, keyrings, git repos,
# server config) in its own temporary directory.
package KupTest;
use strict;
use warnings;
use v5.10.1;
use parent qw(Exporter);
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp ();
use POSIX ();

our @EXPORT;
BEGIN {
	@EXPORT = qw(tmpdir require_cmd require_mods spawn run_script
		read_file write_file kup_env blob sign_blob kup_server
		server_ok server_fails put_cmds kup_client xbail);
	# Re-export Test::More so tests only need "use KupTest;"
	require Test::More;
	my @methods = grep(!/\W/, @Test::More::EXPORT);
	eval(join('', (map { "*$_=\\&Test::More::$_;" } @methods),
		'*TODO = \*Test::More::TODO;'));
	die $@ if $@;
	push @EXPORT, @methods, '$TODO';
}

our $TOPDIR = File::Spec->rel2abs(dirname(__FILE__).'/../..');

sub xbail (@) { BAIL_OUT(join(' ', @_)) }

sub tmpdir (;$) {
	my ($base) = @_;
	($base) = ($0 =~ m!([^/]+)\.t\z!) unless defined $base;
	$base //= 'kup';
	my $tmp = File::Temp->newdir("kup-$base-$$-XXXX", TMPDIR => 1);
	wantarray ? ($tmp->dirname, $tmp) : $tmp;
}

sub read_file ($) {
	my ($path) = @_;
	open(my $fh, '<:raw', $path) or croak "open $path: $!";
	local $/;
	my $s = <$fh>;
	$s // '';
}

sub write_file ($$) {
	my ($path, $data) = @_;
	open(my $fh, '>:raw', $path) or croak "open $path: $!";
	print $fh $data or croak "write $path: $!";
	close($fh) or croak "close $path: $!";
}

sub which ($) {
	my ($cmd) = @_;
	for my $d (split(/:/, $ENV{PATH} // '/bin:/usr/bin')) {
		return "$d/$cmd" if -x "$d/$cmd";
	}
	undef;
}

sub require_cmd ($) {
	my ($cmd) = @_;
	which($cmd) // Test::More::plan(skip_all => "$cmd missing for $0");
}

sub require_mods (@) {
	my @need = grep { !eval("require $_; 1") } @_;
	return if !@need;
	Test::More::plan(skip_all => join(', ', @need)." missing for $0");
}

# Run @$cmd with optional extra %$env (undef values delete a variable).
# $opt->{0} is a string fed to stdin; $opt->{1} and $opt->{2} are scalar
# refs that receive stdout and stderr.  Returns true on exit status 0.
sub spawn ($;$$) {
	my ($cmd, $env, $opt) = @_;
	$opt //= {};
	my @fh;
	for my $fd (0..2) {
		open($fh[$fd], '+>:raw', undef) or croak "tmpfile: $!";
	}
	print { $fh[0] } ($opt->{0} // '');
	seek($fh[0], 0, 0);

	my $pid = fork() // croak "fork: $!";
	if ($pid == 0) {
		# Don't let the developer's own kup settings leak in
		delete @ENV{grep(/^KUP_/, keys %ENV)};
		while (my ($k, $v) = each %{$env // {}}) {
			defined($v) ? ($ENV{$k} = $v) : delete($ENV{$k});
		}
		open(STDIN, '<&', $fh[0]) or POSIX::_exit(127);
		open(STDOUT, '>&', $fh[1]) or POSIX::_exit(127);
		open(STDERR, '>&', $fh[2]) or POSIX::_exit(127);
		chdir($opt->{-C}) or POSIX::_exit(127) if defined $opt->{-C};
		{ no warnings 'exec'; exec { $cmd->[0] } @$cmd; }
		POSIX::_exit(127);
	}
	waitpid($pid, 0);
	my $status = $?;
	for my $fd (1, 2) {
		next if !$opt->{$fd};
		seek($fh[$fd], 0, 0);
		local $/;
		${$opt->{$fd}} = readline($fh[$fd]) // '';
	}
	$? = $status;
	$status == 0;
}

# Both programs have "-T" on their #! line, so perl insists on seeing it
# on the command line as well.
sub run_script ($;$$) {
	my ($cmd, $env, $opt) = @_;
	spawn([ $^X, '-T', @$cmd ], $env, $opt);
}

# Build a DATA or SIGN command with its payload
sub blob ($$;$) {
	my ($cmd, $payload, $fmt) = @_;
	use bytes;
	"$cmd ".length($payload).' '.($fmt // '%')."\n".$payload;
}

sub kup_env (@) {
	KupTest::Env->new(@_);
}

# Run a protocol stream through the env's server.
# Returns ($ok, $stdout, $stderr).
sub kup_server ($$) {
	my ($e, $stream) = @_;
	my ($out, $err);
	my $ok = run_script([ $e->{server} ], undef,
				{ 0 => $stream, 1 => \$out, 2 => \$err });
	($ok, $out, $err);
}

# Run the kup client in batch mode, with $HOME pointing into the env.
# Returns ($ok, $stdout, $stderr).
sub kup_client ($@) {
	my ($e, @args) = @_;
	my $env = { HOME => $e->{home}, KUP_HOST => 'kup.example.org' };
	if (ref($args[0]) eq 'HASH') {
		my $override = shift @args;
		%$env = (%$env, %$override);
	}
	my ($out, $err);
	my $ok = run_script([ "$TOPDIR/kup", @args ], $env,
				{ 1 => \$out, 2 => \$err, -C => $e->{dir} });
	($ok, $out, $err);
}

sub server_ok ($$$) {
	my ($e, $stream, $msg) = @_;
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($ok, $out, $err) = kup_server($e, $stream);
	ok($ok, $msg) or diag("stderr: $err");
	$out;
}

# Any fatal() ends the whole session, so each failure needs its own run
sub server_fails ($$$$) {
	my ($e, $stream, $re, $msg) = @_;
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($ok, $out, $err) = kup_server($e, $stream);
	ok(!$ok && $err =~ $re, $msg) or
		diag("exit ok=".($ok ? 1 : 0)." stderr: $err");
}

# DATA + SIGN + PUT for $payload.  %o: wire => bytes actually sent
# (e.g. a compressed form of $payload), fmt => its compression format,
# signer => fingerprint to sign with (defaults to $fpr).
sub put_cmds ($$$$;%) {
	my ($e, $fpr, $payload, $path, %o) = @_;
	blob(DATA => $o{wire} // $payload, $o{fmt}).
		blob(SIGN => sign_blob($e, $o{signer} // $fpr, $payload)).
		"PUT $path\n";
}

# A detached, armored signature over $data by $fpr
sub sign_blob ($$$;@) {
	my ($e, $fpr, $data, @gpg_opt) = @_;
	@gpg_opt = ('--detach-sign') if !@gpg_opt;
	my ($sig, $err);
	$e->gpg([ '-u', $fpr, '--armor', @gpg_opt ],
		{ 0 => $data, 1 => \$sig, 2 => \$err })
		or xbail("gpg sign failed: $err");
	$sig;
}

package KupTest::Env;
use strict;
use warnings;
use Carp qw(croak);

my $CFG_TEMPLATE = <<'EOF';
[paths]
data_path = @DIR@/data
git_path = @DIR@/git
lock_file = @DIR@/lock
tmp_path = @DIR@/tmp
pgp_path = @DIR@/pgp

[limits]
max_data = @MAX_DATA@
bufsiz = 262144
timeout_command = 30
timeout_data = 30
timeout_compress = 60
timeout_compress_cpu = 60

[compressors]
use = gz, xz

[gz]
compress_command = @GZIP@ -9
decompress_command = @GZIP@ -cd

[xz]
compress_command = @XZ@ -6
decompress_command = @XZ@ -cd
EOF

# %opt:
#   max_data => bytes (default 8 MiB)
sub new {
	my ($class, %opt) = @_;
	my ($dir, $guard) = KupTest::tmpdir();
	my $self = bless {
		dir   => $dir,
		guard => $guard,
		user  => scalar(getpwuid($<)),
		gpg_home => "$dir/gnupg",
	}, $class;

	for my $sub (qw(data git tmp pgp home gnupg)) {
		mkdir("$dir/$sub") or croak "mkdir $dir/$sub: $!";
		$self->{$sub} //= "$dir/$sub";
	}
	chmod(0700, "$dir/gnupg");
	# The server wants a world-writable sticky tmp_path (or per-user dirs)
	chmod(01777, "$dir/tmp");
	KupTest::write_file("$dir/lock", '');

	my %sub = (
		DIR      => $dir,
		MAX_DATA => $opt{max_data} // 8 * 1024 * 1024,
		GZIP     => KupTest::require_cmd('gzip'),
		XZ       => KupTest::require_cmd('xz'),
	);
	(my $cfg = $CFG_TEMPLATE) =~ s/\@([A-Z_]+)\@/$sub{$1}/g;
	$self->{cfg} = "$dir/kup-server.cfg";
	KupTest::write_file($self->{cfg}, $cfg);

	# kup-server hard-codes its config path on purpose: adding an
	# override (env or argv) would hand uploaders a way to swap in their
	# own keyrings.  Test a copy with only that one line changed.
	my $src = KupTest::read_file("$KupTest::TOPDIR/kup-server");
	my $n = ($src =~ s{^my \$cfg_file = '/etc/kup/kup-server\.cfg';$}
			  {my \$cfg_file = '$self->{cfg}';}mg);
	KupTest::xbail("expected 1 \$cfg_file line in kup-server, found $n")
		if $n != 1;
	$self->{server} = "$dir/kup-server";
	KupTest::write_file($self->{server}, $src);

	$self;
}

sub gpg {
	my ($self, $args, $opt) = @_;
	KupTest::spawn([ 'gpg', '--batch', '--quiet', '--no-tty',
			 '--pinentry-mode', 'loopback', '--passphrase', '',
			 @$args ],
		       { GNUPGHOME => $self->{gpg_home} }, $opt);
}

# Generate a signing key and return its fingerprint
sub gen_key {
	my ($self, $name) = @_;
	KupTest::require_cmd('gpg');
	my $uid = "$name <$name\@example.org>";
	my $err;
	$self->gpg([ '--quick-generate-key', $uid, 'ed25519', 'sign',
		     'never' ], { 2 => \$err })
		or KupTest::xbail("gpg key generation failed: $err");
	my $out;
	$self->gpg([ '--with-colons', '--list-keys', "=$uid" ],
		   { 1 => \$out });
	my ($fpr) = ($out =~ /^fpr:(?:[^:]*:){8}([0-9A-F]{40,}):/m)
		or KupTest::xbail("no fingerprint for $uid");
	$self->{gpg_used} = 1;
	$fpr;
}

# Make @fprs the only keys allowed to sign uploads for the current user
sub authorize {
	my ($self, @fprs) = @_;
	my ($ring, $err);
	$self->gpg([ '--export', @fprs ], { 1 => \$ring, 2 => \$err })
		or KupTest::xbail("gpg export failed: $err");
	KupTest::write_file("$self->{dir}/pgp/$self->{user}.gpg", $ring);
}

# Create a bare repo at git_path/$name.git with tags v1 and v2.
# Returns the path to the bare repo.
sub git_repo {
	my ($self, $name) = @_;
	KupTest::require_cmd('git');
	my $work = "$self->{dir}/work-$name";
	my $bare = "$self->{dir}/git/$name.git";
	# Pin everything that could make the archive differ between runs
	my $env = {
		GIT_CONFIG_NOSYSTEM => 1,
		GIT_CONFIG_GLOBAL   => '/dev/null',
		GIT_AUTHOR_NAME     => 'Kup Test',
		GIT_AUTHOR_EMAIL    => 'test@example.org',
		GIT_AUTHOR_DATE     => '@1300000000 +0000',
		GIT_COMMITTER_NAME  => 'Kup Test',
		GIT_COMMITTER_EMAIL => 'test@example.org',
		GIT_COMMITTER_DATE  => '@1300000000 +0000',
	};
	my $git = sub {
		my $err;
		KupTest::spawn([ 'git', @_ ], $env, { -C => $work, 2 => \$err })
			or KupTest::xbail("git @_ failed: $err");
	};
	mkdir($work) or croak "mkdir $work: $!";
	$git->(qw(init -q -b master));
	KupTest::write_file("$work/README", "hello\n");
	$git->(qw(add README));
	$git->(qw(commit -q -m one));
	$git->(qw(tag v1));
	KupTest::write_file("$work/README", "hello, world\n");
	$git->(qw(commit -q -a -m two));
	$git->(qw(tag -a -m), 'version 2', 'v2');
	$git->('clone', '-q', '--bare', $work, $bare);
	$bare;
}

# Run git against a bare repo and return its stdout
sub git_out {
	my ($self, $bare, @args) = @_;
	my ($out, $err);
	KupTest::spawn([ 'git', @args ],
		       { GIT_DIR => $bare, GIT_CONFIG_NOSYSTEM => 1,
			 GIT_CONFIG_GLOBAL => '/dev/null' },
		       { 1 => \$out, 2 => \$err })
		or KupTest::xbail("git @args failed: $err");
	$out;
}

sub DESTROY {
	my ($self) = @_;
	# spawn() sets $?, which would become the exit status of a test
	# script that calls exit() while an env is still alive
	local $?;
	# Stop the agent before File::Temp removes its home directory
	if ($self->{gpg_used}) {
		KupTest::spawn([ 'gpgconf', '--kill', 'gpg-agent' ],
			       { GNUPGHOME => $self->{gpg_home} });
	}
	delete $self->{guard};
}

1;
