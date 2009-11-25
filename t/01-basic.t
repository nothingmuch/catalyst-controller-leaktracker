#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib "t/lib";

BEGIN { use_ok 'Catalyst::Test', 'Catalyst::Controller::LeakTracker::Test' }

ok( request('/list_requests')->is_success, 'empty list request succeeded' );

ok( request('/leak_something')->is_success, 'leaking request succeeded' );

my $list = request('/list_requests');
ok( $list->is_success, 'list request succeeded' );
like( $list->content, qr/leak_something/, "mentions leaked request" );
like( $list->content, qr{http://\S*?/request/\d+}, "link to request page" );

my ( $request ) = ( $list->content =~ m{(http://\S*?/request/\d+)} );

my $req_analysis = request($request);

ok( $req_analysis->is_success, "request analysis succeeed" );
like( $req_analysis->content, qr/LeakedClass/, "leaked class detected" );
like( $req_analysis->content, qr{http://\S*?/leak/\d+/\d+}, "link to leak page" );

my ( $leak ) = ( $req_analysis->content =~ m{http://\S*?(/leak/\d+/\d+)} );

my $leak_analysis = request($leak);

ok( $leak_analysis->is_success, "leak analysis succeeded" );
like( $leak_analysis->content, qr/LeakedClass/, "leaked class in dump" );
like( $leak_analysis->content, qr{Catalyst/Controller/LeakTracker/Test/Controller/Root\.pm}, "offending file listed" );

done_testing;
