#!/usr/bin/perl

package Catalyst::Controller::LeakTracker;
use base qw/Catalyst::Controller/;

use strict;
use warnings;

sub default : Private {
    my ( $self, $c ) = @_;

    $c->forward('list_requests');
}

sub list_requests : Local {
    my ( $self, $c ) = @_;

    my $log = $c->devel_events_log;

    my $trackers = $c->object_tracker_hash;

    my @requests = $log->grep("request_begin");

    pop @requests; # current request

    foreach my $req ( @requests ) {
        my %req = ( type => @$req );

        my $id = $req{request_id};

        my @events = $log->limit( from => { request_id => $id }, to => "request_end" );

        #$req = \@events;
        #next;

        my %dispatch = ( type => @{ ($log->grep( dispatch => \@events ))[0] || [ "dispatch" ] } );

        $req = {
            id     => $id,
            time   => $req{time},
            uri    => $dispatch{uri},
            action => $dispatch{action_name},
            leaks  => scalar( keys %{ $trackers->{$id}->live_objects } ),
        };
    }

    my @fields = qw(id time action leaks uri);

    my %fmt = map { $_ => sub { $_[0] } } @fields;

    $fmt{id} = sub {
        my $id = shift;
        return sprintf q{<a href="%s">%s</a>}, $c->uri_for("/request/$id"), $id;
    };

    $fmt{time} = sub {
        localtime(int(shift));
    };

    $c->response->body( join "\n",
        q{<table border="1" style="border: 1px solid black; padding: 0.3em">},
            join('', "<tr>", ( map { qq{<th style="padding: 0.2em">$_</th>} } @fields ), "</tr>"),
            ( map { my $req = $_;
                join ( '', "<tr>",
                    ( map { '<td style="padding: 0.2em">' . $fmt{$_}->($req->{$_}) . "</td>" } @fields ),
                "</tr>" );
            } @requests),
        "</table>"
    );

    $c->res->content_type("text/html");
}

sub request : Local {
    my ( $self, $c, $id ) = @_;

    my $log = $c->devel_events_log;

    my $trackers = $c->object_tracker_hash;

    my @events = $log->limit( from => { request_id => $id }, to => "request_end" );

    use Data::Dumper;
    my $log_output = Dumper(@events);

    my $leaks = Dumper(values %{ $trackers->{$id}->live_objects });

    $c->res->content_type("text/html");

    $c->res->body(qq{
<h1>Leaks</h1>
<pre>
$leaks
</pre>
<h1>Events</h1>
<pre>
$log_output
</pre>
    });
}

sub leak : Local {
    my ( $self, $c ) = @_;

    my $object = bless {}, "class::a";
    $object->{foo}{self} = $object;

    use Scalar::Util qw/weaken/;
    my $object2 = bless {}, "class::b";
    $object2->{foo}{self} = $object2;
    weaken($object2->{foo}{self});

    my $object3 = bless [], "class::c";
    push @$object3,  $object3;

    $c->res->body("it leaks");
}

__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Controller::LeakTracker - Inspect leaks found by L<Catalyst::Plugin::Leaktracker>

=head1 SYNOPSIS

	package MyApp;

	use Catalyst qw/
		LeakTracker
	/;


	####

	package MyApp::Controller::LeakTracker;

	use base qw/Catalyst::Controller::LeakTracker/;

=head1 DESCRIPTION

=cut


