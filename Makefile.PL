use ExtUtils::MakeMaker;

use 5.008002;

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text MP.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "AnyEvent::MP",
    VERSION_FROM => "MP.pm",
    PREREQ_PM    => {
       AnyEvent         => 3.9,
       Digest::MD6      => 0,
       Digest::HMAC_MD6 => 0,
       common::sense    => 0,
    },
});

$mm->flush;

