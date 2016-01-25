package Seco::Multipkg;
# Copyright (c) 2011 Yahoo! Inc. All rights reserved.
use strict;
use constant MULTIPKG_VERSION => '__MULTIPKG_BUILD_VERSION__';
use File::Spec;
use File::Basename;
use Cwd;

use base qw/Seco::Class/;

BEGIN {
  __PACKAGE__->_accessors(
    startdir      => undef,
    directory     => undef,
    confdir       => '__MULTIPKG_CONFIG_DIR__',
    info          => undef,
    cleanup       => 0,
    cwd           => undef,
    overrides     => {},
    meta          => undef,
    force         => 0,
    platform      => undef,
    warn_on_error => 0,
    verbose       => 0
  );
  __PACKAGE__->_requires(qw/directory/);
}

sub _init {
  my $self = shift;
  my $cwd  = getcwd;
  $self->cwd($cwd);
  $self->{directory} =~ s/\/$//;
  $self->{directory} = File::Spec->rel2abs( $self->{directory} );
  return $self->error( "No such directory " . $self->directory . "." )
    unless ( -d $self->directory );

  $self->{confdir} =~ s/\/$//;
  $self->{confdir} = File::Spec->rel2abs( $self->{confdir} );
  return $self->error( "No such directory " . $self->confdir )
    unless ( -d $self->confdir );

  $self->info(
    Seco::Multipkg::Info->new(
      overrides => $self->overrides,
      platform  => $self->platform,
      directory => $self->directory,
      confdir   => $self->confdir,
      verbose   => $self->verbose,
      meta      => $self->meta
    )
  );
}

sub build {
  my $self = shift;

  my $builder;

  $builder = Seco::Multipkg::Builder::Gem->new(
    verbose => $self->verbose,
    info    => $self->info,
    force   => $self->force,
    cwd     => $self->cwd
  ) if ( $self->info->data->{packagetype} eq 'gem' );
  $builder = Seco::Multipkg::Builder::Rpm->new(
    verbose => $self->verbose,
    info    => $self->info,
    force   => $self->force,
    cwd     => $self->cwd
  ) if ( $self->info->data->{packagetype} eq 'rpm' );
  $builder = Seco::Multipkg::Builder::Deb->new(
    verbose => $self->verbose,
    info    => $self->info,
    force   => $self->force,
    cwd     => $self->cwd
  ) if ( $self->info->data->{packagetype} eq 'deb' );
  $builder = Seco::Multipkg::Builder::Tarball->new(
    verbose => $self->verbose,
    info    => $self->info,
    force   => $self->force,
    cwd     => $self->cwd
  ) if ( $self->info->data->{packagetype} eq 'tarball' );

  $builder->build;
  $builder->copyroot;
  $builder->transform;
  $builder->verify_data
    or $builder->forceok("Finished package contains no files");

  # build action log
  my $multipkg_build_meta = {
    actionlog => [
      { 'time'    => time(),
        'type'    => 'build',
        'actor'   => $self->info->data->{'whoami'},
        'actions' => [
          { 'summary' => 'Seco::Multipkg build complete',
            'text'    => "multipkg version: " . MULTIPKG_VERSION . "\n",
          },
        ],
      },
    ],
  };
  $self->info->mergemeta($multipkg_build_meta);

  my $pkg = $builder->makepackage;

  if ( $self->cleanup ) {
    $builder->cleanup;
  }
  else {
    warn "Not cleaning up: " . $builder->tmpdir . "\n";
  }
  return $pkg;
}

package Seco::Multipkg::Builder;
use File::Find qw/find/;
use File::Temp qw/tempfile tempdir/;
use File::Copy;
use IPC::Open3;
use FileHandle;
use Fcntl ':mode';

use constant MULTIPKG_VERSION => '__MULTIPKG_BUILD_VERSION__';

use base qw/Seco::Class/;

BEGIN {
  __PACKAGE__->_accessors(
    info       => undef,
    verbose    => 0,
    tmpdir     => undef,
    force      => 0,
    builddir   => undef,
    cwd        => undef,
    installdir => undef
  );
  __PACKAGE__->_requires(qw/info/);
}

sub _init {
  my $self = shift;

  $self->{_vars} = {};

  $self->tmpdir( tempdir( CLEANUP => 0 ) );
  $self->infomsg( "Using tmpdir " . $self->tmpdir );

  my $builddir = $self->tmpdir . "/build";
  mkdir($builddir) or die "Unable to mkdir $builddir: $!";
  $self->builddir($builddir);

  my $installdir = $self->tmpdir . "/install";
  mkdir($installdir) or die "Unable to mkdir $installdir: $!";
  chmod 0755, $installdir;
  $self->installdir($installdir);

  $self->setrelease;

  $self->{_rules} = [ $self->get_file_rules ];
}

sub taroption {
  my $self = shift;
  my $tarball = shift;

  return 'zxf' if $tarball =~ /\.(tar\.gz|tgz)$/;
  return 'jxf' if $tarball =~ /\.(tar\.bz2|tbz)$/;
  return 'Jxf' if $tarball =~ /\.(tar\.xz)$/;
}

sub setrelease {
  my $self = shift;

  # When release is not provided, we must be making a test build.
  # Use "0.time()" as release version to avoid ever conflicting with an actual
  # build from source checkout
  $self->info->data->{release} = sprintf "0.%u", time()
    unless ( defined $self->info->data->{release} );
  $self->info->data->{release} .= "." . $self->info->data->{os}
    if (defined($self->info->data->{os}));
}

sub pkgverid {
  my $self = shift;

  return join '-', $self->info->data->{'name'},
    $self->info->data->{'version'},
    $self->info->data->{'release'};
}

sub forceok {
  my $self = shift;
  my $msg  = shift;
  die "FATAL (use --force to override): $msg\n" unless ( $self->force );
  warn "WARN: $msg\n";
}

sub template_file {
  my $self  = shift;
  my $from  = shift;
  my $to    = shift;
  my $chmod = shift;

  my $str = $self->template_string($from);
  open my $f, ">$to";
  print $f $str;
  close $f;

  chmod $chmod, $to if ( defined $chmod );
}

# XXX: dumb variable substitution, intended for use for expanding relative
# strings in index.yaml parameters, etc
sub substvars {
  my $self = shift;
  my $buf  = shift;

  for my $v ( keys %{ $self->{_vars} } ) {
    my $retxt = quotemeta( '$(' . $v . ')' );
    my $re    = qr/$retxt/;

    $buf =~ s/$re/$self->{_vars}->{$v}/gm;
  }
  return $buf;
}

sub template_string {
  my $self = shift;
  my $from = shift;

  open my $f, "<$from" or die "$from: $!";
  my $ret = '';

  my $skipping = 0;
  for (<$f>) {
    # XXX: use of '%' prefix potentially conflicts with RPM specfile syntax
    if (/^%%ifscript\(([A-Za-z\.]+)\)$/) {
      my $script = $1;

      # increase nesting count for every nested %%if statement when we are inside an
      # %%if which evaluated false.
      if ($skipping) {
        $skipping++;
        next;
      }

      # start skipping lines once we hit a false %%if statement.
      if ( !$self->info->scripts->{$script} ) {
        $skipping++;
      }
      next;
    }

    # XXX: use of '%' prefix potentially conflicts with RPM specfile syntax
    if (/^%%ifset\(([A-Za-z\.]+)\)$/) {
      my $match = $1;

      # increase nesting count for every nested %%if statement when we are inside an
      # %%if which evaluated false.
      if ($skipping) {
        $skipping++;
        next;
      }

      # start skipping lines once we hit a false %%if statement.
      if ( !$self->info->data->{$match} ) {
        $skipping++;
      }
      next;
    }

    # reduce the nesting count for each %%endif until we leave the original %%if
    # that evaluated false.
    if (/^%%endif$/) {
      if ($skipping) {
        $skipping--;
      }
      next;
    }

    # skip lines if we are inside an %if that evaluated false.
    if ($skipping) {
      next;
    }

    while (/%([A-Za-z_-]+)%/) {
      my $match = $1;
      if ( defined( my $repl = $self->info->data->{$match} ) ) {
        s/%$match%/$repl/;
      }
      else {
        s/%$match%/UNKNOWN/;
        $self->infomsg("WARN: $match not defined for $from");
      }
    }

    while (/%%([A-Za-z\.]+)%%/) {
      my $match = $1;
      if (  ( my $f = $self->info->scripts->{$match} )
        and ( -f $f ) )
      {
        my $script = $self->template_string($f);
        s/%%$match%%/$script/;
      }
      else {
        s/%%$match%%//;
      }
    }

    $ret .= $_;
  }

  close $f;
  return $ret;
}

sub makepackage {
  my $self = shift;
  die "makepackage not implemented";
}

sub install_gemspec {
  my $self = shift;

  # shove the file list into $self->info->data->{filelist}
  my $installdir = $self->installdir;
  my $buildprefix = $self->info->data->{buildprefix};
  my @filelist;

  my $geminstalldir = [$self->runcmd("gem environment gemdir")]->[0];
  return $self->error("Can't run: $@") if($@);
  
  chomp $geminstalldir;
  my $fullinstalldir = $geminstalldir . "/gems/" . 
    $self->info->data->{name} . "-" .
      $self->info->data->{version};
  foreach ($self->listdir("$installdir/$fullinstalldir")) {
    if (-f "$installdir/$fullinstalldir/$_") {
      s#^$installdir/$fullinstalldir/##;
      s#^$buildprefix/##;
      push @filelist, "\"$_\"";
    }
  }
  $self->info->data->{filelist} = join ",", @filelist;
  # generate the gemspec file based on that

  my $name = $self->info->data->{'name'};
  my $version = $self->info->data->{'version'};
  
  $self->runcmd("mkdir -p $installdir/$geminstalldir/specifications");
  $self->template_file($self->info->confdir . "/templates/gemspec.template",
                       "$installdir/$geminstalldir/specifications/" .
                       "$name-$version.gemspec");
}

sub cleanup {
  my $self = shift;
#  my $tmpdir = $ENV{TMPDIR} || '/tmp';
#  $tmpdir =~ s/\/$//;
#  die "Unsafe to clean up " . $self->tmpdir
#    unless ( $self->tmpdir =~ /^$tmpdir\/\w/ );

  $self->infomsg( "Cleaning up " . $self->tmpdir );
  system( "rm -rf " . $self->tmpdir );
}

sub _listfile {
  my ( $path, $parent, $found_root ) = @_;

  # the root must be a directory
  if ( $path eq $parent ) {
    lstat($parent) or die "can't lstat parent ($parent)";
    die "parent ($parent) is not a directory" unless ( -d _ );
    $$found_root = 1;
    return;
  }

  # otherwise the path must be a child of the parent
  die "path ($path) outside parent ($parent)"
    unless ( substr( $path, 0, length($parent) + 1 ) eq "$parent/" );

  my $name = substr( $path, length($parent) + 1 );
  die "invalid path ($path)" unless ( length($name) );

  # return relative path
  return $name;
}

# Strips the leading directory path and returns the relative path name of the
# contents of '$dir'
sub listdir {
  my $self = shift;
  my $dir  = shift;

  my @ret        = ();
  my $found_root = 0;

  find(
    { wanted   => sub { push @ret, _listfile( $_, $dir, \$found_root ); },
      no_chdir => 1,
    },
    $dir
  );

  die "find failed on path ($dir)" unless ($found_root);

  # preserve daemontools log dirs, not needed with new logrun
  #@ret = ($dir) if(scalar @ret == 0 and $dir eq 'main');
  return @ret;
}

# XXX: maybe keep a "global log of all command output" in the builder object,
# so we can toss that into the generated package too for tracability?
sub runcmd {
  my $self  = shift;
  my $cmd   = shift;
  my $count = shift;
  $count ||= 10;

  $self->infomsg("RUNNING: $cmd");

  my @last   = ();
  my $writer = FileHandle->new;
  my $reader = FileHandle->new;

  my $pid = open3( $writer, $reader, undef, $cmd );
  close $writer;
  while (<$reader>) {
    print if ( $self->verbose );
    push @last, $_;
    shift @last if ( @last > $count );
  }
  close $reader;

  waitpid $pid, 0;

  die "Build failed: @last" if ( $? >> 8 );

  return @last;
}

sub fetch {
  my $self = shift;
  my $target;

  # build cpan module
  if ( $target = $self->info->data->{'cpan-module'} ) {

    eval { require Seco::CPAN; };
    die "Seco::CPAN required to install cpan modules" if ($@);
    $self->infomsg("Fetching $target from CPAN");
    my $agent = Seco::CPAN->new(
      depositdir => ( $self->tmpdir . "/cpan" ),
      tmpdir     => $self->tmpdir
    );

    my $hash = $agent->pull($target)
      or die "Unable to pull $target: $!";
    my $name = lc $hash->{name};
    my $loc  = $hash->{tarball};
    my $version = $hash->{version};

    if ( $name ne $self->info->data->{name} ) {
      $self->forceok( "Package wants to be called $name, "
          . "you asked for "
          . $self->info->data->{name}
          . "\n" );
    }

    $self->info->data->{sourcetar} = $loc;
    $self->info->data->{version}   = $version;

  } 
  # build from http
  elsif ( $target = $self->info->data->{'http'} ) {

    eval { require Seco::HTTP; };
    die "Seco::HTTP required to build package from web: $@" if ($@);
    $self->infomsg("Fetching $target");
    my $agent = Seco::HTTP->new(
      xfercmd    => $self->info->data->{xfercmd},
      depositdir => ( $self->tmpdir . "/source" ),
      tmpdir     => $self->tmpdir
    );

    my $hash = $agent->pull($target)
      or die "Unable to pull $target: $!";
    my $loc  = $hash->{tarball};

    $self->info->data->{sourcetar} = $loc;

  }
}

sub build {
  my $self = shift;

  chdir $self->info->directory;
  my $realbuild = $self->builddir;

  # fetch source from remote
  $self->fetch();

  # build the source if there is any
  if ( $self->info->data->{sourcedir} and -d $self->info->data->{sourcedir} ) {
    $self->infomsg( "Building from " . $self->info->data->{sourcedir} );
    system( "cd "
        . $self->info->data->{sourcedir} . " && "
        . "tar cf - . | tar xf - -C $self->{builddir}" );
  }
  elsif ( $self->info->data->{sourcetar}
    and -f $self->info->data->{sourcetar} )
  {
    $self->infomsg( "Building from " . $self->info->data->{sourcetar} );
    my $tar_opt = $self->taroption($self->info->data->{sourcetar});
    system( "tar $tar_opt $self->{info}->{data}->{sourcetar} " . "-C $self->{builddir}" );
    my $d;
    opendir $d, $self->builddir;
    foreach ( readdir $d ) {
      next if /^\./;
      if ( -d $self->builddir . "/$_" ) {
        $realbuild = $self->builddir . "/$_";
        last;
      }
    }
    closedir $d;
  }
  else {
    return;
  }

  my $destdir = $self->installdir;
  my $prefix  = $self->info->data->{buildprefix}?$self->info->data->{buildprefix}:"/usr";
  my $perl    = $self->info->data->{perl}?$self->info->data->{perl}:"/usr/bin/perl";

  chdir $realbuild;
  $self->{_vars}{BUILDDIR} = $realbuild;

  my $patchdir = $self->info->directory . "/patches";
  if ( -d $patchdir ) {
    $self->infomsg("Applying patches");
    my $d;
    opendir $d, $patchdir;
    my @patches = sort { $a cmp $b }
      grep { $_ !~ /^\./ and -f "$patchdir/$_" } readdir $d;
    closedir $d;

    for my $patch (@patches) {
      $self->infomsg("Applying $patch");
      $self->runcmd("patch --ignore-whitespace -p 1 -d . < $patchdir/$patch");
    }
  }

  $self->infomsg("Building source");

  if($self->info->data->{gem} and
     $self->info->scripts->{gembuild}) {
    # FATAL ON ERRORS
    $self->runcmd( "PERL=$perl INSTALLROOT=$destdir DESTDIR=$destdir "
		   . "PREFIX=$prefix PKGVERID=" 
		   . $self->pkgverid . " "
		   . "PACKAGEVERSION=" . $self->info->data->{version} . " "
		   . "PACKAGENAME=" . $self->info->data->{name} . " "
		   . $self->info->scripts->{build} );
    return $self->error("Error running: $@") if($@);
  } else {
    # FATAL ON ERRORS
    $self->runcmd( "PERL=$perl INSTALLROOT=$destdir DESTDIR=$destdir "
		   . "PREFIX=$prefix PKGVERID=" 
		   . $self->pkgverid . " "
		   . "PACKAGEVERSION=" . $self->info->data->{version} . " "
		   . "PACKAGENAME=" . $self->info->data->{name} . " "
		   . $self->info->scripts->{build} );
    return $self->error("Error running: $@") if($@);
  }
  chdir $self->cwd;
}

# verifies that installroot got some data
sub verify_data {
  my $self = shift;
  my $root = shift;
  $root = $self->installdir unless defined($root);
  my $dir;
  opendir $dir, $root;
  while ( my $f = readdir $dir ) {
    next if ( $f eq '.' or $f eq '..' );
    return 1 if ( -f "$root/$f" );
    if ( -d "$root/$f" ) {
      return 1 if $self->verify_data("$root/$f");
    }
  }
  closedir $dir;
  return 0;
}

# change #!/usr/bin/wrongperl to the one you asked for in index.yaml
sub shebangmunge {
  my $self    = shift;
  my $dirname = shift;
  if ( !defined($dirname) ) {
    $dirname = $self->installdir;
  }

  my $dir;
  opendir $dir, $dirname or die "Can't open $dirname";
  while ( my $f = readdir $dir ) {
    next if ( $f eq '.' or $f eq '..' );
    if ( -f "$dirname/$f" ) {
      my $out = `file $dirname/$f`;
      next unless ( $out =~ /text/ );

      open my $g, "$dirname/$f";
      my $firstline = <$g>;
      next unless ( $firstline =~ m#^\#\!(/.*/)(\w+)\s+?(.*)# );
      my ( $path, $interpreter, $options ) = ( $1, $2, $3 );

      if ( $self->info->data->{$interpreter} ) {
        $self->infomsg("SHEBANG-MUNGING $interpreter: $dirname/$f");
        my $newinterp = $self->info->data->{$interpreter};

        $firstline =~ s/$path$interpreter/$newinterp/;
        open my $h, ">" . $self->tmpdir . "/temp-munge"
          or die "Can't open " . $self->tmpdir . "/temp-munge";
        print $h $firstline;
        while (<$g>) {
          print $h $_;
        }
        close $g;
        close $h;

        my $mode = ( stat("$dirname/$f") )[2];
        rename $self->tmpdir . "/temp-munge" => "$dirname/$f";
        chmod $mode, "$dirname/$f";
      }
    }
    elsif ( -d "$dirname/$f" ) {
      $self->shebangmunge("$dirname/$f");
    }
  }

  closedir $dir;
}

# process filetransforms (s/// on files) and dirtransforms
# (moving directories around)
sub transform {
  my $self       = shift;
  my $installdir = $self->installdir;

  $self->shebangmunge if ( $self->info->data->{shebangmunge} );

  if ( $self->info->data->{filetransforms} ) {
    for my $file ( keys %{ $self->info->data->{filetransforms} } ) {
      my ( $fh, $filename ) = tempfile( 'tempXXXXX', DIR => $self->tmpdir );
      $self->infomsg("TRANSFORMING: $installdir/$file");
      open my $g, "$installdir/$file" or next;
      while (<$g>) {
        for my $trans ( @{ $self->info->data->{filetransforms}->{$file} } ) {
          for my $from ( keys %$trans ) {
            my $to = $trans->{$from};
            s/$from/$to/g;
          }
        }
        print $fh $_;
      }
      close $g;
      close $fh;
      rename $filename => "$installdir/$file";
    }
  }

  if ( $self->info->data->{dirtransforms} ) {
    foreach my $transform ( @{ $self->info->data->{dirtransforms} } ) {
      my $from = $transform->{from};
      my $to   = $transform->{to};

      $self->runcmd("mkdir -p '$installdir/$to'");
      $self->runcmd("mv $installdir/$from/* $installdir/$to || echo fine");
      $self->runcmd( "rmdir -p --ignore-fail-on-non-empty " . "$installdir/$from || echo fine" );
    }
  }

  if($self->info->scripts->{transform}) {
    $self->runcmd( "INSTALLDIR=$installdir "
        . "PKGVERID="
        . $self->pkgverid . " "
        . $self->info->scripts->{transform} );
  }
}

sub copyroot {
  my $self = shift;

  my $installdir = $self->installdir;

  # copy root/ or root.tar.gz into installdir
  if ( $self->info->data->{rootdir} and -d $self->info->data->{rootdir} ) {
    $self->infomsg( "Using " . $self->info->data->{rootdir} );
    system( "cd "
        . $self->info->data->{rootdir} . " && "
        . "tar cf - --exclude \.svn . | tar xf - -C $self->{installdir}" );
  }
  elsif ( $self->info->data->{roottar}
    and -f $self->info->data->{roottar} )
  {
    $self->infomsg( "Using " . $self->info->data->{roottar} );
    my $tar_opt = $self->taroption($self->info->data->{roottar});
    system( "tar $tar_opt $self->{info}->{data}->{roottar} " . " -C $self->{installdir}" );
  }

  # install daemontools service
  if (  $self->info->scripts->{run}
    and $self->info->scripts->{logrun} )
  {
    $self->info->data->{service} ||= $self->info->data->{name};
    my $service = $self->info->data->{service};

    $self->infomsg("Installing daemontools service $service");

    for (
      "etc",                  "etc/service",
      "etc/service/$service", "etc/service/$service/log",
      "etc/service/$service/log/main"
      )
    {
      mkdir "$installdir/$_" unless ( -d "$installdir/$_" );
    }

    copy( $self->info->scripts->{run},    "$installdir/etc/service/$service/run" );
    copy( $self->info->scripts->{logrun}, "$installdir/etc/service/$service/log/run" );
    chmod 0755, "$installdir/etc/service/$service/run", "$installdir/etc/service/$service/log/run";
    my $uid = ( getpwnam('nobody') )[2];
    my $gid = ( getpwnam('nobody') )[3];
    chown $uid, $gid, "$installdir/etc/service/$service/log/main";
  }
}

sub _find_attributes {
  my $name  = shift;
  my $rules = shift;

  # return the last match
  my @found = ( grep { $_->{name} eq $name } (@$rules) );
  return pop(@found);
}

sub _find_match_attributes {
  my $name  = shift;
  my $rules = shift;

  # return the last shell pattern match
  my @found = ( grep { _fnmatch( $_->{name}, $name ) } (@$rules) );
  return pop(@found);
}

# pure-perl implementation of File::FnMatch::fnmatch with 'FNM_PATHNAME' argument
sub _fnmatch {
  my $pat = shift;
  my $str = shift;

  #dots are literal dots
  $pat =~ s{\.}{\\\.}g;

  #internal slashes must be escaped
  $pat =~ s{/}{\\/}g;

  #asterisks are everything but slash
  $pat =~ s{\*}{[^\/]*}g;

  #anchor it
  $pat =~ s{^}{\^};
  $pat =~ s{$}{\$};

  return $str =~ m/$pat/;
}

sub _find_parent_attributes {
  my $name  = shift;
  my $rules = shift;

  my @found;
  for my $r (@$rules) {
    # syntax for "include all children of dir" is '/dir/...'
    next unless ( $r->{name} =~ /^(.+)\/\.\.\.$/ );
    my $parent = quotemeta($1);

    push @found, $r
      if ( $name =~ /^$parent\/.+/ );
  }

  return pop @found;
}

sub get_file_rules {
  my $self = shift;

  my @rules;
  for my $p ( @{ $self->info->data->{files} } ) {
    for my $f ( sort keys %$p ) {
      # remove any leading /, as a convenience for writing the files
      # configuration (->listdir() returns all contents using relative
      # paths)
      ( my $n = $f ) =~ s/^\/*//;
      # XXX: it could be useful to call ->substvars() here, so that a
      # single set of file rules would work for both rpm and yinst, etc
      $p->{$f}{name} = $n;
      if ( exists( $p->{$f}{perm} ) ) {
        die "perm was not octal for $f"
          unless ( $p->{$f}{perm} =~ /^0/ );
      }
      push @rules, $p->{$f};
    }
  }

  return @rules;
}

# Look up attribute
sub get_file_attributes {
  my $self = shift;
  my $name = shift;

  my $attribs = undef;

  # first try to find a rule for the exact path name
  $attribs = _find_attributes( $name, $self->{_rules} );
  return $attribs if ( defined($attribs) );

  # next try matching via shell patterns
  $attribs = _find_match_attributes( $name, $self->{_rules} );
  return $attribs if ( defined($attribs) );

  # finally try matching for subtrees
  $attribs = _find_parent_attributes( $name, $self->{_rules} );
  return $attribs;
}

package Seco::Multipkg::Builder::Rpm;
use base qw/Seco::Multipkg::Builder/;

use POSIX qw/strftime/;

BEGIN {
  __PACKAGE__->_accessors( stagedir => undef );
}

sub makepackage {
  my $self = shift;

  mkdir $self->tmpdir . "/rpm";
  mkdir $self->tmpdir . "/rpm/rpmtop";
  mkdir $self->tmpdir . "/rpm/rpmtop/BUILD";
  mkdir $self->tmpdir . "/rpm/rpmtop/RPMS";
  mkdir $self->tmpdir . "/rpm/rpmtemp";
  mkdir $self->tmpdir . "/rpm/rpmbuild";

  $self->info->data->{rpmtemprepo} = $self->tmpdir . "/rpm";

  if ( !$self->info->data->{arch} ) {
    $self->info->data->{arch} = `arch`;
    chomp $self->info->data->{arch};
  }

  $self->template_file( $self->info->confdir . "/templates/spec.template", 
                        $self->tmpdir . "/spec" );

  open my $f, ">>" . $self->tmpdir . "/spec";
  print $f "%files\n";
  print $f "%defattr(-,root,root)\n";
  my $installdir = $self->installdir;
  if($self->info->data->{gem}) {
    $self->install_gemspec;
  }
  
  foreach ( $self->listdir($installdir) ) {
    my $path = "$installdir/$_";
    next if m{/\.packlist$};    # XXX: cleanup in build, not here

    # get attributes string
    my ( $rpmattr, $is_removed ) = $self->get_rpm_file_attributes($_);

    # skip directories unless .keep exists, in which case use %dir
    # skip .keep files
    next if (/\.keep$/);
    lstat($path) or die "can't lstat $path";

    # ignore files pruned via the 'remove' attribute
    if ($is_removed) {
      # non-directories must actually be deleted, else RPM's check-files
      # script will abort the build
      unless ( -d _ ) {
        unlink($path) or die "cannot remove $path : $!";
      }
      next;
    }

    if ( -d _ ) {
      print $f $rpmattr . "\%dir /$_\n" if ( -e "$path/.keep" );
    }
    else {
      print $f $rpmattr . "/$_\n";
    }
  }

  print $f "\n%changelog\n";
  $self->writechangelog($f);

  close $f;

  open my $g, ">" . $self->tmpdir . "/spec.tmp";
  open $f, "<" . $self->tmpdir . "/spec";
  while ( my $line = <$f> ) {
    print $g $line
      unless ( $line =~ /^Conflicts:\s*$/
      or $line =~ /^Requires:\s*$/
      or $line =~ /^Obsoletes:\s*$/
      or $line =~ /^Provides:\s*$/ );
  }

  close $f;
  close $g;
  rename $self->tmpdir . "/spec.tmp" => $self->tmpdir . "/spec";

  # remove any '.packlist' files created by makemaker
  $self->runcmd( "find " . $self->tmpdir . " -name .packlist -exec rm {} \\;" );
  # remove .keep files
  $self->runcmd( "find " . $self->tmpdir . " -name .keep -exec rm {} \\;" );

  my $rpm;
  my @ten;
  # FATAL ON ERRORS
  my $setarch = '';
  if($self->info->data->{arch} eq 'i686') {
      $setarch = " setarch " . $self->info->data->{arch};
  }

  @ten = $self->runcmd(
    "INSTALLROOT=" . $self->installdir . $setarch .
    " rpmbuild -bb --define '_topdir " .  $self->tmpdir . "/rpm/rpmtop" .
    "' --buildroot " . $self->installdir . " " .
    $self->tmpdir . "/spec" );
  # return $self->error("Can't run: $@") if($@);

  for my $rpmline (@ten) {
    if ( $rpmline =~ /Wrote: (.*\.rpm)/ ) {
      $rpm = $1;
    }
  }
  unless ($rpm) {
    return $self->error("Can't find rpm name");
  }

  my $myrpm = File::Basename::basename $rpm;
  File::Copy::copy( $rpm, $self->cwd . "/$myrpm" )
    or die "Unable to copy rpm to cwd: $!";
  return $myrpm;
}

sub get_rpm_file_attributes {
  my $self = shift;
  my $name = shift;

  my $attr = $self->get_file_attributes($name);
  return ( '', 0 ) unless ( defined($attr) );

  # convert attribs to rpm syntax
  my @rpmattrs;

  if ( exists( $attr->{config} ) ) {
    push @rpmattrs, '%config';
  }
  if ( exists( $attr->{owner} ) || exists( $attr->{group} ) || exists( $attr->{perm} ) ) {
    my $mode  = ( exists( $attr->{perm} ) )  ? "$attr->{perm}" : '-';
    my $user  = ( exists( $attr->{owner} ) ) ? $attr->{owner}  : 'root';
    my $group = ( exists( $attr->{group} ) ) ? $attr->{group}  : 'root';

    push @rpmattrs, "\%attr($mode, $user, $group)";
  }
  my $is_removed = ( exists( $attr->{remove} ) ) ? $attr->{remove} : 0;

  my $rpmattr = (@rpmattrs) ? ( join( ' ', @rpmattrs ) . ' ' ) : '';
  return ( $rpmattr, $is_removed );
}

sub writechangelog {
  my $self   = shift;
  my $output = shift;

  my $meta = $self->info->{'meta'};

  my $fd;
  if ( ref($output) ) {
    $fd = $output;
  }
  else {
    open $fd, '>', $output or die "can't open for writing: $output";
  }

  # rpm changelog happens in reverse
  for my $c ( reverse( @{ $meta->{'actionlog'} } ) ) {
    my @gmt = gmtime( $c->{'time'} );
    my $timestr = strftime( '%a %b %d %Y %H:%M:%S', @gmt );

    printf $fd "* \%s \%s \n", $timestr, $c->{'actor'};
    for my $m ( @{ $c->{'actions'} } ) {
      printf $fd "- \%s\n", $m->{'summary'};
      for ( split( "\n", $m->{'text'} ) ) {
        s/\%/\%\%/g;    # XXX: need to escape '%' in spec file
        printf $fd "  - \%s\n", $_;
      }
    }
    print $fd "\n";
  }

  close($fd) unless ref($output);
}

package Seco::Multipkg::Builder::Deb;
use base qw/Seco::Multipkg::Builder/;

BEGIN {

}

sub makepackage {
  my $self = shift;

  mkdir $self->installdir . "/DEBIAN"
    unless ( -d $self->installdir . "/DEBIAN" );

  if ( !$self->info->data->{arch} ) {
    $self->info->data->{arch} = `dpkg --print-architecture`;
    chomp $self->info->data->{arch};
  }

  $self->template_file( $self->info->confdir . "/templates/control.template",
    $self->installdir . "/DEBIAN/control" );

  my %trans = (
    'pre.sh'    => 'preinst',
    'post.sh'   => 'postinst',
    'preun.sh'  => 'prerm',
    'postun.sh' => 'postrm'
  );

  for (qw/pre.sh post.sh preun.sh postun.sh/) {
    $self->template_file( $self->info->scripts->{$_},
      $self->installdir . "/DEBIAN/" . $trans{$_}, 0755 )
      if ( $self->info->scripts->{$_}
      and -f $self->info->scripts->{$_} );
  }

  chdir( $self->cwd );
  my $deb = undef;
  my @ten;
  # FATAL ON ERRORS
  @ten = $self->runcmd( "fakeroot dpkg-deb -b " . $self->installdir . " ." );
  # return $self->error("Cant run: $@") if($@);

  my $debline = pop @ten;
  if ( $debline =~ /([^\/]+\.deb)'/ ) {
    $deb = $1;
  }

  return $deb;
}

package Seco::Multipkg::Builder::Gem;
use base qw/Seco::Multipkg::Builder/;

sub makepackage {
  my $self = shift;

  # shove the file list into $self->info->data->{filelist}
  my $installdir = $self->installdir;
  my $buildprefix = $self->info->data->{buildprefix};
  my @filelist;

  my $geminstalldir = `gem environment gemdir`;
  chomp $geminstalldir;
  my $fullinstalldir = $geminstalldir . "/gems/" .
    $self->info->data->{name} . "-" .
      $self->info->data->{version};
  foreach ($self->listdir("$installdir/$fullinstalldir")) {
    if (-f "$installdir/$fullinstalldir/$_") {
      s#^$installdir/$fullinstalldir/##;
      s#^$buildprefix/##;
      push @filelist, "\"$_\"";
    }
  }
  $self->info->data->{filelist} = join ",", @filelist;
  
  # generate the gemspec file based on that
  my $name = $self->info->data->{name};
  my $version = $self->info->data->{version};
  
  $self->runcmd("mkdir -p $installdir/$geminstalldir/specifications");
  
  $self->template_file($self->info->confdir . "/templates/gemspec.template",
                       "$installdir/$geminstalldir/specifications/" .
                       "$name-$version.gemspec");
  
  chdir($installdir . "/" . $fullinstalldir);
  my $gem = undef;
  my @ten = $self->runcmd("gem build $installdir/$geminstalldir/" .
                          "specifications/$name-$version.gemspec");
  for my $gemline (@ten) {
    if ($gemline =~ /File: (.*\.gem)/) {
      $gem = $1;
    }
  }

  unless ($gem) {
    return $self->error("Can't find gem name");
  }
  File::Copy::copy($gem, $self->cwd . "/$gem")
   or die "Unable to copy gem to cwd: $!";

  return $gem;
}

package Seco::Multipkg::Builder::Tarball;
use base qw/Seco::Multipkg::Builder/;

sub makepackage {
  my $self = shift;

  my $tarname =
      $self->info->data->{name} . '-'
    . $self->info->data->{version} . '-'
    . $self->info->data->{release}
    . '.tar.gz';
  my @ten;
  chdir( $self->installdir );
  eval { @ten = $self->runcmd( "tar zcvf '" . $self->cwd . "/$tarname' ." ); };
  chdir( $self->cwd );
  return $self->error("Can't run: $@") if ($@);

  return $tarname;
}

package Seco::Multipkg::Info;
use YAML::Syck;
use File::Spec;
use base qw/Seco::Class/;

use constant MULTIPKG_VERSION => '__MULTIPKG_BUILD_VERSION__';

BEGIN {
  __PACKAGE__->_accessors(
    directory => undef,
    confdir   => '__MULTIPKG_CONFIG_DIR__',
    scripts   => undef,
    platform  => undef,
    overrides => {},
    data      => undef,
    meta      => undef,
  );
  __PACKAGE__->_requires(qw/directory/);
}

sub _init {
  my $self = shift;

  my $data;

  # try to load from YAML

  for ( $self->confdir . "/default.yaml", $self->directory . "/index.yaml" ) {
    next unless ( -e $_ );

    my $table;
    eval { $table = YAML::Syck::LoadFile($_); };
    return $self->error("$_ exists but is malformed: $@") if $@;
    $self->infomsg( "LOADING " . $_ );

    foreach my $key ( keys %$table ) {
      $data->{$key} ||= {};
      foreach my $key2 ( keys %{ $table->{$key} } ) {
        $data->{$key}->{$key2} = $table->{$key}->{$key2};
      }
    }
  }

  # try to piece together the remaining data
  my $dirname = $self->directory;
  $self->directory =~ m/([^\/]+)?$/;
  $data->{default}->{name} ||= $1 if ($1);

  my @platforms = $self->platforms;

  # look inside the directories, pick out good defaults
  foreach my $base (@platforms) {
    my $basedir = $self->directory . "/$base";
    $basedir = $self->directory if ( $base eq 'default' );
    $basedir = File::Spec->rel2abs($basedir);

    my $dir;

    if ( opendir $dir, $basedir ) {
      my $name = $data->{$base}->{name};
      foreach ( readdir $dir ) {
        next if /^\./;

        if ( -f "$basedir/$_" ) {
          if (/^$name-([\d\.]+)\.tar\.(gz|bz2)/) {
            $data->{$base}->{sourcetar} ||= "$basedir/$_";
            $data->{$base}->{version}   ||= $1;
          }
        }

        if ( -d "$basedir/$_" ) {
          if (/^$name-([\d\.]+)$/) {
            $data->{$base}->{sourcedir} ||= "$basedir/$_";
            $data->{$base}->{version}   ||= $1;
          }
        }
      }
    }

    $data->{$base}->{sourcedir} ||= "$basedir/source"
      if ( -d "$basedir/source" );
    $data->{$base}->{rootdir} ||= "$basedir/root"
      if ( -d "$basedir/root" );

    my @suffix = qw(.tar.gz .tgz .tar.bz2 .tbz .tar.xz);
    my @sourcetar = grep { -f } map { "$basedir/source$_" } @suffix;
    my @roottar = grep { -f } map { "$basedir/root$_" } @suffix;
    $data->{$base}->{sourcetar} ||= shift @sourcetar if @sourcetar;
    $data->{$base}->{roottar} ||= shift @roottar if @roottar;

    for (qw/sourcedir rootdir/) {
      next unless ( $data->{$base} and $data->{$base}->{$_} );
      next if ( $data->{$base}->{$_} =~ m!/! );
      $data->{$base}->{$_} = "$basedir/" . $data->{$base}->{$_}
        if ( -d "$basedir/" . $data->{$base}->{$_} );
    }

    for (qw/sourcetar roottar/) {
      next unless ( $data->{$base} and $data->{$base}->{$_} );
      next if ( $data->{$base}->{$_} =~ m!/! );
      $data->{$base}->{$_} = "$basedir/" . $data->{$base}->{$_}
        if ( -f "$basedir/" . $data->{$base}->{$_} );
    }
  }

  my $finaldata;

  for (@platforms) {
    if ( my $platdata = $data->{$_} ) {
      foreach my $key ( keys %$platdata ) {
        $finaldata->{$key} = $platdata->{$key};
      }
    }
  }

  if ( !$finaldata->{packagetype} ) {
    for ( reverse @platforms ) {
      $finaldata->{packagetype} ||= 'gem'
        if ( $_ eq 'gem' );
      $finaldata->{packagetype} ||= 'rpm'
        if ( $_ eq 'rpm' );
      $finaldata->{packagetype} ||= 'deb'
        if ( $_ eq 'deb' );
    }
    $finaldata->{packagetype} ||= 'tarball';
  }

  # get scripts
  my @scriptdirs = map { $self->directory . "/$_/scripts" }
    grep { $_ ne 'default' } @platforms;

  unshift @scriptdirs, $self->directory . "/scripts";
  unshift @scriptdirs, $self->confdir . "/scripts";

  my $scripts;

  for my $dir (@scriptdirs) {
    $dir = File::Spec->rel2abs($dir);
    if ( -d $dir ) {
      my $d;
      opendir $d, $dir;
      for ( readdir $d ) {
        next if (/^\./);
        next unless ( -f "$dir/$_" );
        $scripts->{$_} = "$dir/$_";
      }
    }
  }

  $finaldata->{conflicts} ||= [];
  $finaldata->{provides}  ||= [];
  $finaldata->{requires}  ||= [];
  $finaldata->{obsoletes} ||= [];
  if ( $scripts->{run} ) {
    push @{ $finaldata->{requires} }, 'daemontools';
    $scripts->{'post.sh'}  ||= $scripts->{'supervisepost.sh'};
    $scripts->{'preun.sh'} ||= $scripts->{'supervisepreun.sh'};
  }

  my %new = map { $_ => 1 } @{ $finaldata->{conflicts} };
  my @cfl = keys %new;
  $finaldata->{conflicts} = \@cfl;

  %new = map { $_ => 1 } @{ $finaldata->{requires} };
  my @req = keys %new;
  $finaldata->{requires} = \@req;

  %new = map { $_ => 1 } @{ $finaldata->{obsoletes} };
  my @obs = keys %new;
  $finaldata->{obsoletes} = \@obs;

  %new = map { $_ => 1 } @{ $finaldata->{provides} };
  my @prov = keys %new;
  $finaldata->{provides} = \@prov;

  $finaldata->{conflictlist} = join ', ', @{ $finaldata->{conflicts} };
  $finaldata->{providelist}  = join ', ', @{ $finaldata->{provides} };
  $finaldata->{requirelist}  = join ', ', @{ $finaldata->{requires} };
  $finaldata->{obsoletelist} = join ', ', @{ $finaldata->{obsoletes} };

  foreach my $k ( %{ $self->overrides } ) {
    $finaldata->{$k} = $self->overrides->{$k};
  }

  $finaldata->{author} = 'nobody@null'
    unless ( defined( $finaldata->{author} ) );

  $finaldata->{url} = $finaldata->{srcurl}
    if ( !( defined( $finaldata->{url} ) ) && defined( $finaldata->{srcurl} ) );

  $finaldata->{url} = ''
    unless ( defined( $finaldata->{url} ) );

  $finaldata->{whoami} = _whoami();

  $self->data($finaldata);
  $self->scripts($scripts);

  # read in metadata from the package dir
  my $init_meta = $self->meta;
  $self->meta( {} );

  my $mdir = $self->directory . '/meta';
  if ( -d $mdir ) {
    my $d;
    opendir $d, $mdir or die;
    for ( sort grep { ( -f "$mdir/$_" ) } readdir $d ) {
      $self->mergemeta("$mdir/$_");
    }
  }

  # meta passed to the constructor overrides anything loaded
  $self->mergemeta($init_meta) if ($init_meta);

  # initial action log
  my $multipkg_init_meta = {
    actionlog => [
      { 'time'    => time(),
        'type'    => 'build',
        'actor'   => $finaldata->{'whoami'},
        'actions' => [
          { 'summary' => 'Seco::Multipkg::Info initialization',
            'text'    => "multipkg version: " . MULTIPKG_VERSION() . "\n",
          },
        ],
      },
    ],
  };
  $self->mergemeta($multipkg_init_meta);
  1;
}

sub findpath {
  my $self = shift;
  my $file = shift;

  my @platforms = $self->platforms;

  for my $root ( $self->directory, $self->confdir ) {
    for ( reverse @platforms ) {
      if ( -f "$root/$_/$file" ) {
        $self->infomsg("Using $root/$_/$file");
        return "$root/$_/$file";
      }
    }
    if ( -f "$root/$file" ) {
      $self->infomsg("Using $root/$file");
      return "$root/$file";
    }
  }

  return undef;
}

sub platforms {
  my $self = shift;

  return @{ $self->{platforms} } if ( $self->{platforms} );
  my @platforms;

  if ( -f '/etc/platforms' ) {
    open my $f, "/etc/platforms";
    while (<$f>) {
      chomp;
      push @platforms, $_;
    }
    close $f;
  }

  my $uname = `uname`;
  chomp $uname;
  push @platforms, lc $uname;

  my $arch = `uname -m`;
  chomp $arch;
  $arch =~ s/686/386/;
  push @platforms, $arch;

  if ( -f '/etc/debian_version' ) {
    push @platforms, 'debian';
    push @platforms, 'deb';
  }

  if ( -f '/etc/redhat-release' ) {
    push @platforms, 'redhat';
    push @platforms, 'rpm';
    open my $f, "/etc/redhat-release";
    my $rel = <$f>;
    close $f;

    if ( $rel =~ /Red Hat Enterprise Linux AS release (\S+)/ ) {
      push @platforms, "rhel-$1";
    }

    if ( $rel =~ /Red Hat Linux Advanced Server release (\S+)/ ) {
      push @platforms, "rhas-$1";
    }

    if ( $rel =~ /Red Hat Linux release (\S+)/ ) {
      push @platforms, "redhat-$1";
    }
  }
  push @platforms, 'override';
  push @platforms, $self->platform
    if ( defined( $self->platform ) );

  unshift @platforms, 'default';
  $self->{platforms} = \@platforms;
  return @platforms;
}

sub mergemeta {
  my $self  = shift;
  my $merge = shift;

  my $d = ( ref($merge) ) ? $merge : YAML::Syck::LoadFile($merge);
  _merge_tree( $self->meta, $d );
}

# dumb data merger: recurses into hash trees
# array types are concatenated, scalars overwrite each other
sub _merge_tree {
  my ( $into, $from ) = @_;

  for ( keys %$from ) {
    if ( ref( $from->{$_} ) eq 'HASH' ) {
      $into->{$_} = {} unless exists( $into->{$_} );
      die "can't merge hash into non hash"
        unless ( ref( $into->{$_} ) eq 'HASH' );
      _merge_tree( $into->{$_}, $from->{$_} );
    }
    elsif ( ref( $from->{$_} ) eq 'ARRAY' ) {
      $into->{$_} = [] unless exists( $into->{$_} );
      die "can't merge array into non array"
        unless ( ref( $into->{$_} ) eq 'ARRAY' );
      push @{ $into->{$_} }, @{ $from->{$_} };
    }
    else {
      $into->{$_} = $from->{$_};
    }
  }
}

# generate identifying string for this host/user
sub _whoami {
  my $name;
  eval {
    require Sys::Hostname;

    my $user = getpwuid($<);
    $user = 'unknown' unless ( defined($user) );

    $name = $user . '@' . Sys::Hostname->hostname();
  };
  $name = 'unknown' if ($@);

  return $name;
}

1;
