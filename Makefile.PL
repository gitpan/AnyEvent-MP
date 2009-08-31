use ExtUtils::MakeMaker;

use 5.010; # smartmatching

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text MP.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "AnyEvent::MP",
    VERSION_FROM => "MP/Kernel.pm",
    EXE_FILES    => ["bin/aemp"],
    PREREQ_PM    => {
       AnyEvent           => 5.11,
       AnyEvent::Watchdog => 0.1,
       Digest::MD6        => 0,
       Digest::HMAC_MD6   => 0,
       MIME::Base64       => 3,
       JSON::XS           => 2.25,
       Net::Interface     => 1.011,
       common::sense      => 0,
    },
});

$mm->flush;

