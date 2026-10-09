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
use Cwd ();
use File::Basename qw(dirname);
use File::Spec;
use File::Temp ();
use POSIX ();

our @EXPORT;
BEGIN {
	@EXPORT = qw(tmpdir require_cmd require_mods spawn run_script
		read_file write_file kup_env blob sign_blob kup_server perl_cmd
		server_ok server_fails put_cmds kup_client xbail
		require_gitolite verifiers);
	# Re-export Test::More so tests only need "use KupTest;"
	require Test::More;
	my @methods = grep(!/\W/, @Test::More::EXPORT);
	eval(join('', (map { "*$_=\\&Test::More::$_;" } @methods),
		'*TODO = \*Test::More::TODO;'));
	die $@ if $@;
	push @EXPORT, @methods, '$TODO';
}

our $TOPDIR = Cwd::abs_path(dirname(__FILE__).'/../..');

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
# refs that receive stdout and stderr.  With $opt->{-hold_stdin}, stdin is
# a pipe that stays open until the child exits, so the child waits for
# more input instead of seeing EOF; such a child is killed after
# $HOLD_TIMEOUT seconds, so a server timeout that never fires fails the
# test instead of hanging it.  Returns true on exit status 0.
our $HOLD_TIMEOUT = 30;
sub spawn ($;$$) {
	my ($cmd, $env, $opt) = @_;
	$opt //= {};
	my @fh;
	for my $fd (0..2) {
		open($fh[$fd], '+>:raw', undef) or croak "tmpfile: $!";
	}
	my $stdin_wr;
	if ($opt->{-hold_stdin}) {
		pipe($fh[0], $stdin_wr) or croak "pipe: $!";
	} else {
		print { $fh[0] } ($opt->{0} // '');
		seek($fh[0], 0, 0);
	}

	my $pid = fork() // croak "fork: $!";
	if ($pid == 0) {
		# Don't let the developer's own kup settings leak in
		delete @ENV{grep(/^KUP_/, keys %ENV)};
		while (my ($k, $v) = each %{$env // {}}) {
			defined($v) ? ($ENV{$k} = $v) : delete($ENV{$k});
		}
		close($stdin_wr) if $stdin_wr;
		open(STDIN, '<&', $fh[0]) or POSIX::_exit(127);
		open(STDOUT, '>&', $fh[1]) or POSIX::_exit(127);
		open(STDERR, '>&', $fh[2]) or POSIX::_exit(127);
		chdir($opt->{-C}) or POSIX::_exit(127) if defined $opt->{-C};
		{ no warnings 'exec'; exec { $cmd->[0] } @$cmd; }
		POSIX::_exit(127);
	}
	my $killed;
	if ($stdin_wr) {
		# Small enough to fit the pipe buffer, so this can't block
		print $stdin_wr ($opt->{0} // '');
		$stdin_wr->flush;
		alarm($HOLD_TIMEOUT);
	}
	local $SIG{ALRM} = sub { $killed = 1; kill('KILL', $pid) };
	# Safe signals don't restart waitpid, so retry after the handler ran
	1 while waitpid($pid, 0) == -1 && $!{EINTR};
	alarm(0);
	Test::More::diag("spawn: '@$cmd' still running after ${HOLD_TIMEOUT}s ".
			 'with stdin held open, killed') if $killed;
	my $status = $?;
	close($stdin_wr) if $stdin_wr;
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
sub perl_cmd () {
	# -T ignores PERL5OPT, so "make cover" has to inject Devel::Cover here
	($^X, '-T', $ENV{KUP_TEST_COVER} ?
		("-MDevel::Cover=-db,$TOPDIR/cover_db,-silent,1,-ignore,/Gitolite/,".
		 '-ignore,KupTestSyslog') : (),
	 "-I$TOPDIR/t/lib", '-MKupTestSyslog');
}

# A gitolite source tree ($KUP_TEST_GITOLITE, e.g. ~/src/gitolite/src) or
# an installed gitolite.  Returns the path to the gitolite command.
sub require_gitolite () {
	my $gl = $ENV{KUP_TEST_GITOLITE};
	return "$gl/gitolite" if defined($gl) && -x "$gl/gitolite";
	which('gitolite') // Test::More::plan(skip_all =>
		"gitolite missing for $0 (set KUP_TEST_GITOLITE to a source tree)");
}

# The PGP verifiers kup-server supports that are installed here
sub verifiers () {
	grep { which($_) } qw(gpgv sq);
}

sub run_script ($;$$) {
	my ($cmd, $env, $opt) = @_;
	spawn([ perl_cmd(), @$cmd ], $env, $opt);
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

# Run a protocol stream through the env's server, as $e->{user}.
# $opt->{-env} is merged over the env the server would normally get.
# Returns ($ok, $stdout, $stderr).
sub kup_server ($$;$) {
	my ($e, $stream, $opt) = @_;
	my ($out, $err);
	my $env = { %{$e->server_env}, KUP_TEST_SYSLOG => $e->{syslog},
		    %{$opt->{-env} // {}} };
	my $ok = run_script([ $e->{server} ], $env,
			    { %{$opt // {}},
			      0 => $stream, 1 => \$out, 2 => \$err });
	($ok, $out, $err);
}

# Run the kup client in batch mode, with $HOME pointing into the env.
# Returns ($ok, $stdout, $stderr).
sub kup_client ($@) {
	my ($e, @args) = @_;
	# A fake rsh may run the server, which inherits KUP_TEST_SYSLOG
	my $env = { HOME => $e->{home}, KUP_HOST => 'kup.example.org',
		    KUP_TEST_SYSLOG => $e->{syslog} };
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

# Written in this order; any other sections go last
my @CFG_SECTIONS = qw(paths limits compressors gz xz);

sub default_cfg {
	my ($dir) = @_;
	my $gzip = KupTest::require_cmd('gzip');
	my $xz = KupTest::require_cmd('xz');
	(
		'paths.data_path' => "$dir/data",
		'paths.git_path'  => "$dir/git",
		'paths.lock_file' => "$dir/lock",
		'paths.tmp_path'  => "$dir/tmp",
		'paths.pgp_path'  => "$dir/pgp",
		'limits.max_data' => 8 * 1024 * 1024,
		'limits.bufsiz'   => 262144,
		'limits.timeout_command' => 30,
		'limits.timeout_data' => 30,
		'limits.timeout_compress' => 60,
		'limits.timeout_compress_cpu' => 60,
		'compressors.use' => 'gz, xz',
		'gz.compress_command'   => "$gzip -9",
		'gz.decompress_command' => "$gzip -cd",
		'xz.compress_command'   => "$xz -6",
		'xz.decompress_command' => "$xz -cd",
		map { ("pgp.$_" => KupTest::which($_)) } KupTest::verifiers(),
	);
}

# %opt:
#   cfg => { 'section.key' => value }, merged over default_cfg();
#          an undef value removes the key
#   gitolite => 1: use the gitolite auth backend with a fresh gitolite
#          instance; its repositories are the git_path, and $e->{user}
#          becomes GL_USER
sub new {
	my ($class, %opt) = @_;
	my ($dir, $guard) = KupTest::tmpdir();
	my $self = bless {
		dir   => $dir,
		guard => $guard,
		user  => scalar(getpwuid($<)),
		gpg_home => "$dir/gnupg",
		syslog => "$dir/syslog",	# see KupTestSyslog
	}, $class;

	for my $sub (qw(data git tmp pgp home gnupg)) {
		mkdir("$dir/$sub") or croak "mkdir $dir/$sub: $!";
		$self->{$sub} //= "$dir/$sub";
	}
	chmod(0700, "$dir/gnupg");
	# The server wants a world-writable sticky tmp_path (or per-user dirs)
	chmod(01777, "$dir/tmp");
	KupTest::write_file("$dir/lock", '');

	$self->{cfg} = "$dir/kup-server.cfg";
	$self->{cfg_vals} = { default_cfg($dir) };
	$self->gitolite_setup if $opt{gitolite};
	$self->set_cfg(%{$opt{cfg} // {}});

	# kup-server hard-codes its config path on purpose: adding an
	# override (env or argv) would hand uploaders a way to swap in their
	# own keyrings.  Test a copy with only that one line changed.
	my $src = KupTest::read_file("$KupTest::TOPDIR/kup-server");
	my $n = ($src =~ s{^my \$cfg_file = '/etc/kup/kup-server\.cfg';$}
			  {my \$cfg_file = '$self->{cfg}';}mg);
	KupTest::xbail("expected 1 \$cfg_file line in kup-server, found $n")
		if $n != 1;
	# Attribute errors and coverage to the real file, not this copy
	$src =~ s{\A(.*\n)}{$1#line 2 "$KupTest::TOPDIR/kup-server"\n}
		or KupTest::xbail('kup-server has no #! line');
	$self->{server} = "$dir/kup-server";
	KupTest::write_file($self->{server}, $src);

	$self;
}

sub gitolite_setup {
	my ($self) = @_;
	my $gitolite = KupTest::require_gitolite();
	my $home = "$self->{dir}/gitolite";
	mkdir($home) or croak "mkdir $home: $!";
	my %env = (HOME => $home, GIT_CONFIG_NOSYSTEM => 1,
		   GIT_CONFIG_GLOBAL => '/dev/null');
	my $run = sub {
		my ($out, $err);
		KupTest::spawn([ $gitolite, @_ ], \%env,
			       { 1 => \$out, 2 => \$err })
			or KupTest::xbail("gitolite @_ failed: $err");
		$out;
	};
	$run->(qw(setup -a admin));
	my ($bindir, $libdir) = map {
		my $v = $run->('query-rc', $_);
		chomp($v);
		$v;
	} qw(GL_BINDIR GL_LIBDIR);
	$self->{gitolite} = {
		run => $run,
		env => { HOME => $home, GL_BINDIR => $bindir,
			 GL_LIBDIR => $libdir },
	};
	$self->{git} = "$home/repositories";
	$self->{cfg_vals}{'paths.git_path'} = $self->{git};
	$self->{cfg_vals}{'auth.backend'} = 'gitolite';
}

# Replace the gitolite rules (other than gitolite-admin's) and compile them
sub gitolite_conf {
	my ($self, $rules) = @_;
	my $gl = $self->{gitolite} or croak 'not a gitolite env';
	KupTest::write_file("$gl->{env}{HOME}/.gitolite/conf/gitolite.conf",
			    "repo gitolite-admin\n    RW+ = admin\n\n$rules");
	$gl->{run}->('compile');
}

# What the server finds in its environment, apart from PATH and the like
sub server_env {
	my ($self) = @_;
	my $gl = $self->{gitolite} or return {};
	return { %{$gl->{env}}, GL_USER => $self->{user} };
}

# Return what kup-server logged since the last call, one line per
# message, as "level: message"
sub syslog_take {
	my ($self) = @_;
	return '' if !-e $self->{syslog};
	my $log = KupTest::read_file($self->{syslog});
	unlink($self->{syslog}) or croak "unlink $self->{syslog}: $!";
	$log;
}

# Merge %vals into the server config and rewrite it
sub set_cfg {
	my ($self, %vals) = @_;
	my $c = $self->{cfg_vals};
	%$c = (%$c, %vals);
	my %sect;
	while (my ($k, $v) = each %$c) {
		next if !defined $v;
		my ($s, $key) = ($k =~ /\A([^.]+)\.(.+)\z/) or
			croak "bad config key: $k";
		$sect{$s}{$key} = $v;
	}
	my %known = map { $_ => 1 } @CFG_SECTIONS;
	my $out = '';
	for my $s (grep({ $sect{$_} } @CFG_SECTIONS),
		   sort(grep { !$known{$_} } keys %sect)) {
		$out .= "[$s]\n";
		$out .= "$_ = $sect{$s}{$_}\n" for sort keys %{$sect{$s}};
		$out .= "\n";
	}
	KupTest::write_file($self->{cfg}, $out);
}

sub gpg {
	my ($self, $args, $opt) = @_;
	KupTest::spawn([ 'gpg', '--batch', '--quiet', '--no-tty',
			 '--pinentry-mode', 'loopback', '--passphrase', '',
			 @$args ],
		       { GNUPGHOME => $self->{gpg_home} }, $opt);
}

# Generate a signing key and return its fingerprint.  $expire is gpg's
# expiry ("never" if undef); $when, like "20200101T000000", makes the key
# as if it were that time (gpg's --faked-system-time).
sub gen_key {
	my ($self, $name, $expire, $when) = @_;
	KupTest::require_cmd('gpg');
	my $uid = "$name <$name\@example.org>";
	my $err;
	$self->gpg([ (defined($when) ? ('--faked-system-time', "$when!") : ()),
		     '--quick-generate-key', $uid, 'ed25519', 'sign',
		     $expire // 'never' ], { 2 => \$err })
		or KupTest::xbail("gpg key generation failed: $err");
	my $out;
	$self->gpg([ '--with-colons', '--list-keys', "=$uid" ],
		   { 1 => \$out });
	my ($fpr) = ($out =~ /^fpr:(?:[^:]*:){8}([0-9A-F]{40,}):/m)
		or KupTest::xbail("no fingerprint for $uid");
	$self->{gpg_used} = 1;
	$fpr;
}

# Make @fprs the only keys allowed to sign uploads for the current user:
# <user>.gpg for gpgv and <user>.asc for sq, with the same keys
sub authorize {
	my ($self, @fprs) = @_;
	for my $ext ('gpg', 'asc') {
		my ($ring, $err);
		$self->gpg([ '--export', ($ext eq 'asc' ? '--armor' : ()), @fprs ],
			   { 1 => \$ring, 2 => \$err })
			or KupTest::xbail("gpg export failed: $err");
		KupTest::write_file("$self->{dir}/pgp/$self->{user}.$ext", $ring);
	}
}

# Create a bare repo at git_path/$name.git with tags v1 and v2.
# Returns the path to the bare repo.
sub git_repo {
	my ($self, $name) = @_;
	KupTest::require_cmd('git');
	my $work = "$self->{dir}/work-$name";
	my $bare = "$self->{git}/$name.git";
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
