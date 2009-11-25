#!/usr/bin/perl -w

use strict;

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME         => 'Catalyst::Controller::LeakTracker',
	VERSION_FROM => 'lib/Catalyst/Controller/LeakTracker.pm',
	INSTALLDIRS  => 'site',
	PL_FILES     => { },
	PREREQ_PM    => {
        'Catalyst::Runtime' => 5.8,
        'Devel::Size' => 0,
        'Devel::Cycle' => 0,
        'Catalyst::Plugin::LeakTracker' => 0,
        'Data::Dumper' => 0,
        'Template::Declare' => 0.42,
        'Number::Bytes::Human' => 0.07,
        'Test::More' => 0.88,
        'Test::use::ok' => 0,
	},
);

