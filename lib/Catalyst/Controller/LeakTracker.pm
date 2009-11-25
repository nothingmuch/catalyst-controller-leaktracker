#!/usr/bin/perl

package Catalyst::Controller::LeakTracker;
use parent qw(Catalyst::Controller);

use Moose;

our $VERSION = "0.04";

use Data::Dumper ();
use Devel::Cycle ();
use Devel::Size ();
use Tie::RefHash::Weak ();
use YAML::Syck ();
use Scalar::Util qw(weaken);

use namespace::clean -except => "meta";

{
    package Catalyst::Controller::LeakTracker::Template;

    use Template::Declare::Tags 'HTML'; # conflicts with Moose
}

my $size_of_empty_array = Devel::Size::total_size([]);

sub end : Private { } # don't get Root's one

sub list_requests : Chained {
    my ( $self, $c ) = @_;

    my $only_leaking = !$c->request->param("all");

    my $log = $c->devel_events_log; # FIXME used for repping, switch to exported when that api is available.

    my @request_ids = $c->get_all_request_ids;

    pop @request_ids; # current request

    my @requests;

    foreach my $request_id ( @request_ids ) {
        my $tracker = $c->get_object_tracker_by_id($request_id) || next;
        my $leaked = $tracker->live_objects;

        my $n_leaks = scalar( keys %$leaked );

        next if $only_leaking and $n_leaks == 0;

        my @events = $c->get_request_events($request_id);

        my ( undef, %req ) = @{ $events[0] };

        my (undef, %dispatch) = $log->matcher->first( match => "dispatch", events => \@events );
        scalar keys %dispatch or next;

        my $size = ( Devel::Size::total_size([ keys %$leaked ]) - $size_of_empty_array );

        push @requests, {
            id     => $request_id,
            time   => $req{time},
            uri    => $dispatch{uri},
            action => $dispatch{action_name},
            leaks  => $n_leaks,
            size   => $size,
        }
    }


    my @fields = qw(id time action leaks size uri);

    my %fmt = map { $_ => sub { $_[0] } } @fields;

    $fmt{id} = sub {
        package Catalyst::Controller::LeakTracker::Template;
        my $id = shift;
        return a { attr { href => $c->uri_for( $self->action_for("request"), $id ) } $id };
    };

    $fmt{time} = sub {
        scalar localtime(int(shift));
    };

    $fmt{size} = sub {
        use Number::Bytes::Human;
        my $h = Number::Bytes::Human->new;
        $h->set_options(zero => '-');
        $h->format(shift);
    };

    $c->response->body( "" . do { package Catalyst::Controller::LeakTracker::Template;
        html {
            head { }
            body {
                table {
                    attr { border => 1, style => "border: 1px solid black; padding: 0.3em" };
                    row { map { th { $_ } } @fields };

                    foreach my $req ( @requests ) {
                        row {
                            foreach my $field (@fields) {
                                my $formatter = $fmt{$field};

                                cell {
                                    attr { style => "padding: 0.2em" }
                                    $formatter->( $req->{$field} );
                                }
                            }
                        }
                    }
                }
            }
        }
    });

    $c->res->content_type("text/html");
}

sub leak : Chained {
    my ( $self, $c, $request_id, $id ) = @_;

    my $obj_entry = $c->get_object_entry_by_id($request_id, $id) || die "No such object: $id";

    my $obj = $obj_entry->{object};

    my @stack = $c->generate_stack_for_event( $request_id, $id );

    @stack = reverse @stack[2..$#stack]; # skip _DISPATCH and _ACTION

    my $stack_dump = "$obj_entry->{file} line $obj_entry->{line} (package $obj_entry->{package})\n"
        . join("\n", map {"  in action $_->{action_name} $obj_entry->{file} line $obj_entry->{line} (controller $_->{class})" } @stack);

    local $Data::Dumper::Maxdepth = $c->request->param("maxdepth") || 0;
    my $obj_dump = Data::Dumper::Dumper($obj);

    my $cycles = $self->_cycle_report($obj);

    $c->response->content_type("text/html");
    $c->response->body( "" . do { package Catalyst::Controller::LeakTracker::Template;
        html {
            head { }
            body {
                h1 { "Stack" }
                pre { $stack_dump }
                h1 { "Cycles" }
                pre { $cycles }
                h1 { "Object" }
                pre { $obj_dump }
            }
        }
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



sub request : Chained {
    my ( $self, $c, $request_id ) = @_;

    my $log = $c->request->param("event_log");

    my $log_output = $log && YAML::Syck::Dump($c->get_request_events($request_id));

    my $tracker = $c->get_object_tracker_by_id($request_id);
    my $live_objects = $tracker->live_objects;

    my @leaks = map {
        my $object = $_->{object};

        +{
            %$_,
            size => Devel::Size::total_size($object),
            class => ref $object,
        }
    } sort { $a->{id} <=> $b->{id} } values %$live_objects;


    my @fields = qw/id size class/;

    my %fmt = map { $_ => sub { $_[0] } } @fields;

    $fmt{id} = sub {
        package Catalyst::Controller::LeakTracker::Template;
        my $id = shift;
        return a { attr { href => $c->uri_for( $self->action_for("leak"), $request_id, $id ) } $id };
    };

    $fmt{size} = sub {
        use Number::Bytes::Human;
        my $h = Number::Bytes::Human->new;
        $h->set_options(zero => '-');
        $h->format(shift);
    };

    my $leaks = sub {
        package Catalyst::Controller::LeakTracker::Template;
        table {
            attr { border => "1", style => "border: 1px solid black; padding: 0.3em" }
            row { map { th { attr { style => "padding: 0.2em" }; $_ } } @fields };

            foreach my $leak ( @leaks ) {
                row {
                    foreach my $field ( @fields ) {
                        my $formatter = $fmt{$field};

                        cell {
                            attr { style => "padding: 0.2em" }
                            $formatter->($leak->{$field});
                        }
                    }
                }
            }
        }
    };

    $c->res->content_type("text/html");

    $c->res->body( "" . do { package Catalyst::Controller::LeakTracker::Template;
        html {
            head { }
            body {
                h1 { "Leaks" }
                pre { $leaks->() }

                $log ? (
                    h1 { "Events" }
                    pre { $log_output }
                ) : ()
            }
        }
    });
}

sub make_leak : Chained {
    my ( $self, $c, $n ) = @_;

    $n ||= 1;

    $n = 300 if $n > 300;

    for ( 1 .. $n ) {
        my $object = bless {}, "class::a";
        $object->{foo}{self} = $object;
    }

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

Catalyst::Controller::LeakTracker - Inspect leaks found by L<Catalyst::Plugin::LeakTracker>

=head1 SYNOPSIS

    # in MyApp.pm

	package MyApp;

	use Catalyst qw(
		LeakTracker
	);

	#### in SomeController.pm

	package MyApp::Controller::Leaks;
    use Moose;

    use parent qw(Catalyst::Controller::LeakTracker);

    sub index :Path :Args(0) {
        my ( $self, $c ) = @_;
        $c->forward("list_requests"); # redirect to request listing view
    }

=head1 DESCRIPTION

This controller uses L<Catalyst::Controller::LeakTracker> to display leak info
on a per request basis.

=head1 ACTIONS

=over 4

=item list_requests

List the leaking requests this process has handled so far.

If the C<all> parameter is set to a true value, then all requests (even non
leaking ones) are listed.

=item request $request_id

Detail the leaks for a given request, and also dump the event log for that request.

=item object $request_id $event_id

Detail the object created in $event_id.

Displays a stack dump, a L<Devel::Cycle> report, and a L<Data::Dumper> output.

If the C<maxdepth> param is set, C<$Data::Dumper::Maxdepth> is set to that value.

=item make_leak [ $how_many ]

Artificially leak some objects, to make sure everything is working properly

=back

=head1 CAVEATS

In forking environments each child will have it's own leak tracking. To avoid
confusion run your apps under the development server or temporarily configure
fastcgi or whatever to only use one child process.

=head1 TODO

This is yucky example code. But it's useful. Patches welcome.

=over 4

=item L<Template::Declare>

Instead of yucky HTML strings

=item CSS

I can't do that well, I didn't bother trying

=item Nicer displays

    <pre> ... </pre>

Only goes so far...

The event log is in most dire need for this.

=item Sorting, filtering etc

Of objects, requests, etc. Javascript or serverside, it doesn't matter.

=item JSON/YAML/XML feeds

Maybe it's useful for someone.

=back

=head1 SEE ALSO

L<Devel::Events>, L<Catalyst::Plugin::Leaktracker>,
L<http://blog.jrock.us/articles/Plugging%20a%20leaky%20whale.pod>,
L<Devel::Size>, L<Devel::Cycle>

=head1 VERSION CONTROL

L<http://github.com/nothingmuch/Catalyst-Controller-Leaktracker>

=head1 AUTHOR

Yuval Kogman <nothingmuch@woobling.org>

=head1 COPYRIGHT & LICENSE

	Copyright (c) 2007 Yuval Kogman. All rights reserved
	This program is free software; you can redistribute it and/or modify it
	under the terms of the MIT license or the same terms as Perl itself.

=cut


