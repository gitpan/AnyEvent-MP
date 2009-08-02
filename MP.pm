=head1 NAME

AnyEvent::MP - multi-processing/message-passing framework

=head1 SYNOPSIS

   use AnyEvent::MP;

   NODE    # returns this node identifier
   $NODE   # contains this node identifier

   snd $port, type => data...;

   rcv $port, smartmatch => $cb->($port, @msg);

   # examples:
   rcv $port2, ping => sub { snd $_[0], "pong"; 0 };
   rcv $port1, pong => sub { warn "pong received\n" };
   snd $port2, ping => $port1;

   # more, smarter, matches (_any_ is exported by this module)
   rcv $port, [child_died => $pid] => sub { ...
   rcv $port, [_any_, _any_, 3] => sub { .. $_[2] is 3

=head1 DESCRIPTION

This module (-family) implements a simple message passing framework.

Despite its simplicity, you can securely message other processes running
on the same or other hosts.

At the moment, this module family is severly brokena nd underdocumented,
so do not use. This was uploaded mainly to resreve the CPAN namespace -
stay tuned!

=head1 CONCEPTS

=over 4

=item port

A port is something you can send messages to with the C<snd> function, and
you can register C<rcv> handlers with. All C<rcv> handlers will receive
messages they match, messages will not be queued.

=item port id - C<noderef#portname>

A port id is always the noderef, a hash-mark (C<#>) as separator, followed
by a port name (a printable string of unspecified format).

=item node

A node is a single process containing at least one port - the node
port. You can send messages to node ports to let them create new ports,
among other things.

Initially, nodes are either private (single-process only) or hidden
(connected to a master node only). Only when they epxlicitly "become
public" can you send them messages from unrelated other nodes.

=item noderef - C<host:port,host:port...>, C<id@noderef>, C<id>

A noderef is a string that either uniquely identifies a given node (for
private and hidden nodes), or contains a recipe on how to reach a given
node (for public nodes).

=back

=head1 VARIABLES/FUNCTIONS

=over 4

=cut

package AnyEvent::MP;

use AnyEvent::MP::Base;

use common::sense;

use Carp ();

use AE ();

use base "Exporter";

our $VERSION = '0.02';
our @EXPORT = qw(
   NODE $NODE $PORT snd rcv _any_
   create_port create_port_on
   become_slave become_public
);

=item NODE / $NODE

The C<NODE ()> function and the C<$NODE> variable contain the noderef of
the local node. The value is initialised by a call to C<become_public> or
C<become_slave>, after which all local port identifiers become invalid.

=item snd $portid, type => @data

=item snd $portid, @msg

Send the given message to the given port ID, which can identify either
a local or a remote port, and can be either a string or soemthignt hat
stringifies a sa port ID (such as a port object :).

While the message can be about anything, it is highly recommended to use a
string as first element (a portid, or some word that indicates a request
type etc.).

The message data effectively becomes read-only after a call to this
function: modifying any argument is not allowed and can cause many
problems.

The type of data you can transfer depends on the transport protocol: when
JSON is used, then only strings, numbers and arrays and hashes consisting
of those are allowed (no objects). When Storable is used, then anything
that Storable can serialise and deserialise is allowed, and for the local
node, anything can be passed.

=item $local_port = create_port

Create a new local port object. See the next section for allowed methods.

=cut

sub create_port {
   my $id = "$AnyEvent::MP::Base::UNIQ." . ++$AnyEvent::MP::Base::ID;

   my $self = bless {
      id    => "$NODE#$id",
      names => [$id],
   }, "AnyEvent::MP::Port";

   $AnyEvent::MP::Base::PORT{$id} = sub {
      unshift @_, $self;

      for (@{ $self->{rc0}{$_[1]} }) {
         $_ && &{$_->[0]}
            && undef $_;
      }

      for (@{ $self->{rcv}{$_[1]} }) {
         $_ && [@_[1 .. @{$_->[1]}]] ~~ $_->[1]
            && &{$_->[0]}
            && undef $_;
      }

      for (@{ $self->{any} }) {
         $_ && [@_[0 .. $#{$_->[1]}]] ~~ $_->[1]
            && &{$_->[0]}
            && undef $_;
      }
   };

   $self
}

package AnyEvent::MP::Port;

=back

=head1 METHODS FOR PORT OBJECTS

=over 4

=item "$port"

A port object stringifies to its port ID, so can be used directly for
C<snd> operations.

=cut

use overload
   '""'     => sub { $_[0]{id} },
   fallback => 1;

=item $port->rcv (type => $callback->($port, @msg))

=item $port->rcv ($smartmatch => $callback->($port, @msg))

=item $port->rcv ([$smartmatch...] => $callback->($port, @msg))

Register a callback on the given port.

The callback has to return a true value when its work is done, after
which is will be removed, or a false value in which case it will stay
registered.

If the match is an array reference, then it will be matched against the
first elements of the message, otherwise only the first element is being
matched.

Any element in the match that is specified as C<_any_> (a function
exported by this module) matches any single element of the message.

While not required, it is highly recommended that the first matching
element is a string identifying the message. The one-string-only match is
also the most efficient match (by far).

=cut

sub rcv($@) {
   my ($self, $match, $cb) = @_;

   if (!ref $match) {
      push @{ $self->{rc0}{$match}      }, [$cb];
   } elsif (("ARRAY" eq ref $match && !ref $match->[0])) {
      my ($type, @match) = @$match;
      @match
         ? push @{ $self->{rcv}{$match->[0]} }, [$cb, \@match]
         : push @{ $self->{rc0}{$match->[0]} }, [$cb];
   } else {
      push @{ $self->{any}              }, [$cb, $match];
   }
}

=item $port->register ($name)

Registers the given port under the well known name C<$name>. If the name
already exists it is replaced.

A port can only be registered under one well known name.

=cut

sub register {
   my ($self, $name) = @_;

   $self->{wkname} = $name;
   $AnyEvent::MP::Base::WKP{$name} = "$self";
}

=item $port->destroy

Explicitly destroy/remove/nuke/vaporise the port.

Ports are normally kept alive by there mere existance alone, and need to
be destroyed explicitly.

=cut

sub destroy {
   my ($self) = @_;

   delete $AnyEvent::MP::Base::WKP{ $self->{wkname} };

   delete $AnyEvent::MP::Base::PORT{$_}
      for @{ $self->{names} };
}

=back

=head1 FUNCTIONS FOR NODES

=over 4

=item mon $noderef, $callback->($noderef, $status, $)

Monitors the given noderef.

=item become_public endpoint...

Tells the node to become a public node, i.e. reachable from other nodes.

If no arguments are given, or the first argument is C<undef>, then
AnyEvent::MP tries to bind on port C<4040> on all IP addresses that the
local nodename resolves to.

Otherwise the first argument must be an array-reference with transport
endpoints ("ip:port", "hostname:port") or port numbers (in which case the
local nodename is used as hostname). The endpoints are all resolved and
will become the node reference.

=cut

=back

=head1 NODE MESSAGES

Nodes understand the following messages sent to them. Many of them take
arguments called C<@reply>, which will simply be used to compose a reply
message - C<$reply[0]> is the port to reply to, C<$reply[1]> the type and
the remaining arguments are simply the message data.

=over 4

=cut

=item wkp => $name, @reply

Replies with the port ID of the specified well-known port, or C<undef>.

=item devnull => ...

Generic data sink/CPU heat conversion.

=item relay => $port, @msg

Simply forwards the message to the given port.

=item eval => $string[ @reply]

Evaluates the given string. If C<@reply> is given, then a message of the
form C<@reply, $@, @evalres> is sent.

Example: crash another node.

   snd $othernode, eval => "exit";

=item time => @reply

Replies the the current node time to C<@reply>.

Example: tell the current node to send the current time to C<$myport> in a
C<timereply> message.

   snd $NODE, time => $myport, timereply => 1, 2;
   # => snd $myport, timereply => 1, 2, <time>

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

