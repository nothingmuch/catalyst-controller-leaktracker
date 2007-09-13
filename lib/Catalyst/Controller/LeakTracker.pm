#!/usr/bin/perl

package Catalyst::Controller::LeakTracker;
use base qw/Catalyst::Controller/;

use strict;
use warnings;

use Data::Dump ();
use Devel::Cycle ();
use Devel::Size ();
use Tie::RefHash::Weak ();
use YAML::Syck ();

sub default : Private {
    my ( $self, $c ) = @_;

    $c->forward('list_requests');
}

my $size_of_empty_array = Devel::Size::total_size([]);
tie my %leak_size_cache, 'Tie::RefHash::Weak';

sub list_requests : Local {
    my ( $self, $c ) = @_;

    my $log = $c->devel_events_log; # FIXME used for grepping, switch to exported when that api is available.

    my @request_events = $c->get_all_request_events;

    pop @request_events; # current request

    my @requests;

    foreach my $req_events ( @request_events ) {
        my $request_id = $req_events->{id};
        my $events = $req_events->{events};

        my ( undef, %req ) = @{ $events->[0] };

        my $dispatch = ( $log->grep( dispatch => $events ) )[0] || next;
        my ( undef, %dispatch ) = @$dispatch;

        my $tracker = $c->get_object_tracker_by_id($request_id) || next;
        my $leaked = $tracker->live_objects;

        my $size = $leak_size_cache{$tracker} ||= ( Devel::Size::total_size([ keys %$leaked ]) - $size_of_empty_array );

        push @requests, {
            id     => $request_id,
            time   => $req{time},
            uri    => $dispatch{uri},
            action => $dispatch{action_name},
            leaks  => scalar( keys %$leaked ),
            size   => $size,
        }
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

tie my %cycle_report_cache, 'Tie::RefHash::Weak';
tie my %object_dump_cache, 'Tie::RefHash::Weak';
tie my %stack_dump_cache, 'Tie::RefHash::Weak';

sub object : Local {
    my ( $self, $c, $request_id, $id ) = @_;

    my $obj_entry = $c->get_object_entry_by_id($request_id, $id) || die "No such object: $id";

    my $obj = $obj_entry->{object};

    my $stack_dump = $stack_dump_cache{$obj} ||= do {
        my @stack = $c->generate_stack_for_event( $request_id, $id );

        "$obj_entry->{file} line $obj_entry->{line} (package $obj_entry->{package})\n"
        . join("\n", map {"  in action $_->{action_name} (controller $_->{class})" } reverse @stack[2..$#stack]); # skip _DISPATCH and _ACTION
    };

    my $obj_dump = $object_dump_cache{$obj} ||= Data::Dump::dump($obj);

    my $cycles = $cycle_report_cache{$obj} ||= $self->_cycle_report($obj);

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

# stolen from Test::Memory::Cycle

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

sub _cycle_report {
    my ( $self, $obj ) = @_;

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

    Devel::Cycle::find_cycle( $obj, $callback );

    return join("\n", @diags);
}



tie my %object_size_cache, 'Tie::RefHash::Weak';
my %event_log_dump_cache;


sub request : Local {
    my ( $self, $c, $request_id ) = @_;

    my $log_output = $event_log_dump_cache{$request_id} ||= YAML::Syck::Dump($c->get_request_events($request_id));

    my $tracker = $c->get_object_tracker_by_id($request_id);
    my $live_objects = $tracker->live_objects;

    my @leaks = map {
        my $object = $_->{object};

        +{
            %$_,
            size => ( $object_size_cache{$object} ||= Devel::Size::total_size($object) ),
            class => ref $object,
        }
    } sort { $a->{id} <=> $b->{id} } values %$live_objects;


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


