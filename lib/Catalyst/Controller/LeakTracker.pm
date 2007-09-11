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

        my $leaked = $trackers->{$id}->live_objects;

        use Devel::Size;
        my $size = Devel::Size::total_size([ keys %$leaked ]) - Devel::Size::total_size([]);

        $req = {
            id     => $id,
            time   => $req{time},
            uri    => $dispatch{uri},
            action => $dispatch{action_name},
            leaks  => scalar( keys %$leaked ),
            size   => $size,
        };
    }

    my @fields = qw(id time action leaks size uri);

    my %fmt = map { $_ => sub { $_[0] } } @fields;

    $fmt{id} = sub {
        my $id = shift;
        return sprintf q{<a href="%s">%s</a>}, $c->uri_for("/request/$id"), $id;
    };

    $fmt{time} = sub {
        localtime(int(shift));
    };

    $fmt{size} = sub {
        use Number::Bytes::Human;
        my $h = Number::Bytes::Human->new;
        $h->set_options(zero => '-');
        $h->format(shift);
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

sub object : Local {
    my ( $self, $c, $request_id, $id ) = @_;

    my $log = $c->devel_events_log;

    my $trackers = $c->object_tracker_hash;

    my @events = $log->limit( from => { request_id => $request_id }, to => { id => $id } );

    my @stack;
    foreach my $event ( @events ) {
        my ( $type, %data ) = @$event;

        if ( $type eq 'enter_action' ) {
            push @stack, \%data;
        } elsif ( $type eq 'leave_action' ) {
            pop @stack;
        }
    }

    my ( undef, %obj_event ) = @{ $events[-1] };

    my $stack_dump = join("\n",
        "$obj_event{file} line $obj_event{line} (package $obj_event{package})",
        map {"  in action $_->{action_name} (controller $_->{class})" } reverse @stack
    );

    my %objs_by_id = map { $_->{id} => $_->{object} } values %{ $trackers->{$request_id}->live_objects };

    my $obj = $objs_by_id{$id};

    use Data::Dumper;
    my $obj_dump = Dumper($obj);

    my @diags;
    my $cycle_no;

    # Callback function that is called once for each memory cycle found.
    my $callback = sub {
        my $path = shift;
        $cycle_no++;
        push( @diags, "Cycle #$cycle_no" );
        foreach (@$path) {
            my ($type,$index,$ref,$value) = @$_;

            my $str = 'Unknown! This should never happen!';
            my $refdisp = _ref_shortname( $ref );
            my $valuedisp = _ref_shortname( $value );

            $str = sprintf( '    %s => %s', $refdisp, $valuedisp )               if $type eq 'SCALAR';
            $str = sprintf( '    %s => %s', "${refdisp}->[$index]", $valuedisp ) if $type eq 'ARRAY';
            $str = sprintf( '    %s => %s', "${refdisp}->{$index}", $valuedisp ) if $type eq 'HASH';
            $str = sprintf( '    closure %s => %s', "${refdisp}, $index", $valuedisp ) if $type eq 'CODE';

            push( @diags, $str );
        }
    };

    use Devel::Cycle;
    Devel::Cycle::find_cycle( $obj, $callback );

    my $cycles = join("\n", @diags);

    $c->response->content_type("text/html");
    $c->response->body(qq{
<h1>Stack</h1>
<pre>
$stack_dump
</pre>
<h1>Cycles</h1>
<pre>
$cycles
</pre>
<h1>Object</h1>
<pre>
$obj_dump
</pre>
        });
}

my %shortnames;
my $new_shortname = "A";

sub _ref_shortname {
    my $ref = shift;
    my $refstr = "$ref";
    my $refdisp = $shortnames{ $refstr };
    if ( !$refdisp ) {
        my $sigil = ref($ref) . " ";
        $sigil = '%' if $sigil eq "HASH ";
        $sigil = '@' if $sigil eq "ARRAY ";
        $sigil = '$' if $sigil eq "REF ";
        $sigil = '&' if $sigil eq "CODE ";
        $refdisp = $shortnames{ $refstr } = $sigil . $new_shortname++;
    }

    return $refdisp;
}




sub request : Local {
    my ( $self, $c, $request_id ) = @_;

    my $log = $c->devel_events_log;

    my $trackers = $c->object_tracker_hash;

    my @events = $log->limit( from => { request_id => $request_id }, to => "request_end" );

    use YAML::Syck qw/Dump/;

    my $log_output = Dump(@events);

    my @leaks = map {
        my %rec = %$_;
        $rec{size} = Devel::Size::total_size($_->{object});
        $rec{class} = ref($_->{object});
        \%rec,
    } sort { $a->{id} <=> $b->{id} } values %{ $trackers->{$request_id}->live_objects };


    my @fields = qw/id size class/;

    my %fmt = map { $_ => sub { $_[0] } } @fields;

    $fmt{id} = sub {
        my $id = shift;
        return sprintf q{<a href="%s">%s</a>}, $c->uri_for("/object/$request_id/$id"), $id;
    };

    $fmt{size} = sub {
        use Number::Bytes::Human;
        my $h = Number::Bytes::Human->new;
        $h->set_options(zero => '-');
        $h->format(shift);
    };

    my $leaks = join "\n",
        q{<table border="1" style="border: 1px solid black; padding: 0.3em">},
            join('', "<tr>", ( map { qq{<th style="padding: 0.2em">$_</th>} } @fields ), "</tr>"),
            ( map { my $leak = $_;
                join ( '', "<tr>",
                    ( map { '<td style="padding: 0.2em">' . $fmt{$_}->($leak->{$_}) . "</td>" } @fields ),
                "</tr>" );
            } @leaks ),
        "</table>";


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
    my ( $self, $c, $n ) = @_;

    $n ||= 1;

    $n = 300 if $n > 300;

    for ( 1 .. $n ) {
        my $object = bless {}, "class::a";
        $object->{foo}{self} = $object;
    }

    use Scalar::Util qw/weaken/;
    my $object2 = bless {}, "class::b";
    $object2->{foo}{self} = $object2;
    weaken($object2->{foo}{self});

    my $object3 = bless [], "class::c";
    push @$object3, $object3, map { [ 1 .. $n ] } 1 .. $n;

    $c->res->body("it leaks " . ( $n + 1 ) . " objects");
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


