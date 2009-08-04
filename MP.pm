=head1 NAME

AnyEvent::MP - multi-processing/message-passing framework

=head1 SYNOPSIS

   use AnyEvent::MP;

   $NODE      # contains this node's noderef
   NODE       # returns this node's noderef
   NODE $port # returns the noderef of the port

   snd $port, type => data...;

   $SELF      # receiving/own port id in rcv callbacks

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

For an introduction to this module family, see the L<AnyEvent::MP::Intro>
manual page.

At the moment, this module family is severly broken and underdocumented,
so do not use. This was uploaded mainly to reserve the CPAN namespace -
stay tuned! The basic API should be finished, however.

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

our $VERSION = '0.1';
our @EXPORT = qw(
   NODE $NODE *SELF node_of _any_
   become_slave become_public
   snd rcv mon kil reg psub
   port
);

our $SELF;

sub _self_die() {
   my $msg = $@;
   $msg =~ s/\n+$// unless ref $msg;
   kil $SELF, die => $msg;
}

=item $thisnode = NODE / $NODE

The C<NODE> function returns, and the C<$NODE> variable contains
the noderef of the local node. The value is initialised by a call
to C<become_public> or C<become_slave>, after which all local port
identifiers become invalid.

=item $noderef = node_of $portid

Extracts and returns the noderef from a portid or a noderef.

=item $SELF

Contains the current port id while executing C<rcv> callbacks or C<psub>
blocks.

=item SELF, %SELF, @SELF...

Due to some quirks in how perl exports variables, it is impossible to
just export C<$SELF>, all the symbols called C<SELF> are exported by this
module, but only C<$SELF> is currently used.

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

=item kil $portid[, @reason]

Kill the specified port with the given C<@reason>.

If no C<@reason> is specified, then the port is killed "normally" (linked
ports will not be kileld, or even notified).

Otherwise, linked ports get killed with the same reason (second form of
C<mon>, see below).

Runtime errors while evaluating C<rcv> callbacks or inside C<psub> blocks
will be reported as reason C<< die => $@ >>.

Transport/communication errors are reported as C<< transport_error =>
$message >>.

=item $guard = mon $portid, $cb->(@reason)

=item $guard = mon $portid, $otherport

=item $guard = mon $portid, $otherport, @msg

Monitor the given port and do something when the port is killed.

In the first form, the callback is simply called with any number
of C<@reason> elements (no @reason means that the port was deleted
"normally"). Note also that I<< the callback B<must> never die >>, so use
C<eval> if unsure.

In the second form, the other port will be C<kil>'ed with C<@reason>, iff
a @reason was specified, i.e. on "normal" kils nothing happens, while
under all other conditions, the other port is killed with the same reason.

In the last form, a message of the form C<@msg, @reason> will be C<snd>.

Example: call a given callback when C<$port> is killed.

   mon $port, sub { warn "port died because of <@_>\n" };

Example: kill ourselves when C<$port> is killed abnormally.

   mon $port, $self;

Example: send us a restart message another C<$port> is killed.

   mon $port, $self => "restart";

=cut

sub mon {
   my ($noderef, $port, $cb) = ((split /#/, shift, 2), shift);

   my $node = $NODE{$noderef} || add_node $noderef;

   #TODO: ports must not be references
   if (!ref $cb or "AnyEvent::MP::Port" eq ref $cb) {
      if (@_) {
         # send a kill info message
         my (@msg) = ($cb, @_);
         $cb = sub { snd @msg, @_ };
      } else {
         # simply kill other port
         my $port = $cb;
         $cb = sub { kil $port, @_ if @_ };
      }
   }

   $node->monitor ($port, $cb);

   defined wantarray
      and AnyEvent::Util::guard { $node->unmonitor ($port, $cb) }
}

=item $guard = mon_guard $port, $ref, $ref...

Monitors the given C<$port> and keeps the passed references. When the port
is killed, the references will be freed.

Optionally returns a guard that will stop the monitoring.

This function is useful when you create e.g. timers or other watchers and
want to free them when the port gets killed:

  $port->rcv (start => sub {
     my $timer; $timer = mon_guard $port, AE::timer 1, 1, sub {
        undef $timer if 0.9 < rand;
     });
  });

=cut

sub mon_guard {
   my ($port, @refs) = @_;

   mon $port, sub { 0 && @refs }
}

=item lnk $port1, $port2

Link two ports. This is simply a shorthand for:

   mon $port1, $port2;
   mon $port2, $port1;

It means that if either one is killed abnormally, the other one gets
killed as well.

=item $local_port = port

Create a new local port object that supports message matching.

=item $portid = port { my @msg = @_; $finished }

Creates a "mini port", that is, a very lightweight port without any
pattern matching behind it, and returns its ID.

The block will be called for every message received on the port. When the
callback returns a true value its job is considered "done" and the port
will be destroyed. Otherwise it will stay alive.

The message will be passed as-is, no extra argument (i.e. no port id) will
be passed to the callback.

If you need the local port id in the callback, this works nicely:

   my $port; $port = miniport {
      snd $otherport, reply => $port;
   };

=cut

sub port(;&) {
   my $id = "$UNIQ." . $ID++;
   my $port = "$NODE#$id";

   if (@_) {
      my $cb = shift;
      $PORT{$id} = sub {
         local $SELF = $port;
         eval {
            &$cb
               and kil $id;
         };
         _self_die if $@;
      };
   } else {
      my $self = bless {
         id    => "$NODE#$id",
      }, "AnyEvent::MP::Port";

      $PORT_DATA{$id} = $self;
      $PORT{$id} = sub {
         local $SELF = $port;

         eval {
            for (@{ $self->{rc0}{$_[0]} }) {
               $_ && &{$_->[0]}
                  && undef $_;
            }

            for (@{ $self->{rcv}{$_[0]} }) {
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
         _self_die if $@;
      };
   }

   $port
}

=item reg $portid, $name

Registers the given port under the name C<$name>. If the name already
exists it is replaced.

A port can only be registered under one well known name.

A port automatically becomes unregistered when it is killed.

=cut

sub reg(@) {
   my ($portid, $name) = @_;

   $REG{$name} = $portid;
}

=item rcv $portid, tagstring        => $callback->(@msg), ...

=item rcv $portid, $smartmatch      => $callback->(@msg), ...

=item rcv $portid, [$smartmatch...] => $callback->(@msg), ...

Register callbacks to be called on matching messages on the given port.

The callback has to return a true value when its work is done, after
which is will be removed, or a false value in which case it will stay
registered.

The global C<$SELF> (exported by this module) contains C<$portid> while
executing the callback.

Runtime errors wdurign callback execution will result in the port being
C<kil>ed.

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
   my ($noderef, $port) = split /#/, shift, 2;

   ($NODE{$noderef} || add_node $noderef) == $NODE{""}
      or Carp::croak "$noderef#$port: rcv can only be called on local ports, caught";

   my $self = $PORT_DATA{$port}
      or Carp::croak "$noderef#$port: rcv can only be called on message matching ports, caught";

   "AnyEvent::MP::Port" eq ref $self
      or Carp::croak "$noderef#$port: rcv can only be called on message matching ports, caught";

   while (@_) {
      my ($match, $cb) = splice @_, 0, 2;

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
}

=item $closure = psub { BLOCK }

Remembers C<$SELF> and creates a closure out of the BLOCK. When the
closure is executed, sets up the environment in the same way as in C<rcv>
callbacks, i.e. runtime errors will cause the port to get C<kil>ed.

This is useful when you register callbacks from C<rcv> callbacks:

   rcv delayed_reply => sub {
      my ($delay, @reply) = @_;
      my $timer = AE::timer $delay, 0, psub {
         snd @reply, $SELF;
      };
   };

=cut

sub psub(&) {
   my $cb = shift;

   my $port = $SELF
      or Carp::croak "psub can only be called from within rcv or psub callbacks, not";

   sub {
      local $SELF = $port;

      if (wantarray) {
         my @res = eval { &$cb };
         _self_die if $@;
         @res
      } else {
         my $res = eval { &$cb };
         _self_die if $@;
         $res
      }
   }
}

=back

=head1 FUNCTIONS FOR NODES

=over 4

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

=item lookup => $name, @reply

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

