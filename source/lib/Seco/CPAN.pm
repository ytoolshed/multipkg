package Seco::CPAN;
# Copyright (c) 2011 Yahoo! Inc. All rights reserved.

use strict;
use base qw(Seco::Class);

use File::Copy qw(copy);
use File::Temp qw/tempfile tempdir/;
use Cwd;
use Getopt::Long qw/:config require_order gnu_compat/;

BEGIN {
    __PACKAGE__->_accessors(mirror => 'http://www.perl.com/CPAN',
                            depositdir => undef,
                            tmpdir => undef);
    __PACKAGE__->_requires(qw/depositdir/);
}

sub _init {
    my $self = shift;
    mkdir $self->depositdir;
    $self->tmpdir(tempdir(CLEANUP => 0))
      unless(-d $self->tmpdir);
    return 1;
}

sub pull {
    my $self = shift;
    my $module = shift;

    my $basedir = $self->tmpdir . "/cpanbuild";
    mkdir $basedir unless(-d $basedir);
    my $tarball;
    
    require CPAN;
    
    $INC{'CPAN/Config.pm'} = '/dev/null';
    
    $CPAN::Config->{cpan_home} = "$basedir";
    $CPAN::Config->{build_dir} = "$basedir/build";
    $CPAN::Config->{build_cache} = q[10];
    $CPAN::Config->{cache_metadata} = q[1];
    $CPAN::Config->{cpan_version_check} = q[1];
    $CPAN::Config->{ftp} = q[/usr/bin/ftp];
    $CPAN::Config->{ftp_proxy} = q[];
    
    $CPAN::Config->{getcwd} = q[cwd];
    $CPAN::Config->{gpg} = q[/usr/bin/gpg];
    $CPAN::Config->{gzip} = q[/bin/gzip];
    $CPAN::Config->{histsize} = q[100];
    $CPAN::Config->{http_proxy} = q[];
    $CPAN::Config->{inactivity_timeout} = q[0];
    $CPAN::Config->{index_expire} = q[1];
    $CPAN::Config->{inhibit_startup_message} = q[0];
    $CPAN::Config->{lynx} = q[];
    $CPAN::Config->{make} = q[/usr/bin/make];
    $CPAN::Config->{make_arg} = q[];
    $CPAN::Config->{make_install_arg} = q[];
    $CPAN::Config->{makepl_arg} = q[INSTALLDIRS=site];
    $CPAN::Config->{ncftpget} = q[/usr/bin/ncftpget];
    $CPAN::Config->{no_proxy} = q[];
    $CPAN::Config->{pager} = q[/usr/bin/less];
    $CPAN::Config->{prerequisites_policy} = q[ask];
    $CPAN::Config->{scan_cache} = q[atstart];
    $CPAN::Config->{shell} = q[/bin/bash];
    $CPAN::Config->{tar} = q[/bin/tar];
    $CPAN::Config->{term_is_latin} = q[1];
    $CPAN::Config->{unzip} = q[/usr/bin/unzip];
    $CPAN::Config->{wget} = q[/usr/bin/wget];
    
    unshift @{$CPAN::Config->{'urllist'}}, $self->mirror;
    $CPAN::Config->{histfile} = "$basedir/history";
    $CPAN::Config->{keep_source_where} = "$basedir/source";
    $CPAN::Config->{prerequisites_policy} = 'ignore';
    $CPAN::Config->{cpan_version_check} = 0;
    
    # CPAN is very loud :(
    open REAL, ">&STDOUT";
    open STDOUT, ">/dev/null";
    
    my $mod = CPAN::Shell->expand('Module', '/^'.$module.'$/')
      or do { open STDOUT, ">&REAL"; die "Can't find $module on CPAN"; };
    my $version = $mod->cpan_version;
    
    my $dist = $CPAN::META->instance('CPAN::Distribution',
                                     $mod->cpan_file);
    $dist->get or do {
        open STDOUT, ">&REAL"; die "Cannot get ", $mod->cpan_file, "\n";
    };
    my $name = $mod->{ID};
    $tarball = $dist->{localfile};
    open STDOUT, ">&REAL";
    
    system('cp', $tarball, $self->depositdir);
    return undef if($? >> 8);
    $tarball =~ s/^.*\///;
    $name =~ s/::/-/g;
    return { tarball => $self->depositdir . "/" . $tarball,
             name => 'cpan-' . $name,
             version => $version };
}

1;
