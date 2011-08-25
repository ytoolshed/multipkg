use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'multipkg',
    AUTHOR              => q{m10n-pe <nobody@localhost>},
    VERSION_FROM        => 'lib/Seco/Multipkg.pm',
    ABSTRACT_FROM       => 'lib/Seco/Multipkg.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'multipkg-*' },
);
