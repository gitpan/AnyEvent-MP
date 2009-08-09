=head1 NAME

AnyEvent::MP - multi-processing/message-passing framework

=head1 SYNOPSIS

   use AnyEvent::MP;

   $NODE      # contains this node's noderef
   NODE       # returns this node's noderef
   NODE $port # returns the noderef of the port

   $SELF      # receiving/own port id in rcv callbacks

   # ports are message endpoints

   # sending messages
   snd $port, type => data...;
   snd $port, @msg;
   snd @msg_with_first_element_being_a_port;

   # miniports
   my $miniport = port { my @msg = @_; 0 };

   # full ports
   my $port = port;
   rcv $port, smartmatch => $cb->(@msg);
   rcv $port, ping => sub { snd $_[0], "pong"; 0 };
   rcv $port, pong => sub { warn "pong received\n"; 0 };

   # remote ports
   my $port = spawn $node, $initfunc, @initdata;

   # more, smarter, matches (_any_ is exported by this module)
   rcv $port, [child_died => $pid] => sub { ...
   rcv $port, [_any_, _any_, 3] => sub { .. $_[2] is 3

   # monitoring
   mon $port, $cb->(@msg)      # callback is invoked on death
   mon $port, $otherport       # kill otherport on abnormal death
   mon $port, $otherport, @msg # send message on death

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

A port is something you can send messages to (with the C<snd> function).

Some ports allow you to register C<rcv> handlers that can match specific
messages. All C<rcv> handlers will receive messages they match, messages
will not be queued.

=item port id - C<noderef#portname>

A port id is normaly the concatenation of a noderef, a hash-mark (C<#>) as
separator, and a port name (a printable string of unspecified format). An
exception is the the node port, whose ID is identical to its node
reference.

=item node

A node is a single process containing at least one port - the node
port. You can send messages to node ports to find existing ports or to
create new ports, among other things.

Nodes are either private (single-process only), slaves (connected to a
master node only) or public nodes (connectable from unrelated nodes).

=item noderef - C<host:port,host:port...>, C<id@noderef>, C<id>

A node reference is a string that either simply identifies the node (for
private and slave nodes), or contains a recipe on how to reach a given
node (for public nodes).

This recipe is simply a comma-separated list of C<address:port> pairs (for
TCP/IP, other protocols might look different).

Node references come in two flavours: resolved (containing only numerical
addresses) or unresolved (where hostnames are used instead of addresses).

Before using an unresolved node reference in a message you first have to
resolve it.

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

our $VERSION = $AnyEvent::MP::Base::VERSION;

our @EXPORT = qw(
   NODE $NODE *SELF node_of _any_
   resolve_node initialise_node
   snd rcv mon kil reg psub spawn
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

=item $noderef = node_of $port

Extracts and returns the noderef from a portid or a noderef.

=item initialise_node $noderef, $seednode, $seednode...

=item initialise_node "slave/", $master, $master...

Before a node can talk to other nodes on the network it has to initialise
itself - the minimum a node needs to know is it's own name, and optionally
it should know the noderefs of some other nodes in the network.

This function initialises a node - it must be called exactly once (or
never) before calling other AnyEvent::MP functions.

All arguments are noderefs, which can be either resolved or unresolved.

There are two types of networked nodes, public nodes and slave nodes:

=over 4

=item public nodes

For public nodes, C<$noderef> must either be a (possibly unresolved)
noderef, in which case it will be resolved, or C<undef> (or missing), in
which case the noderef will be guessed.

Afterwards, the node will bind itself on all endpoints and try to connect
to all additional C<$seednodes> that are specified. Seednodes are optional
and can be used to quickly bootstrap the node into an existing network.

=item slave nodes

When the C<$noderef> is the special string C<slave/>, then the node will
become a slave node. Slave nodes cannot be contacted from outside and will
route most of their traffic to the master node that they attach to.

At least one additional noderef is required: The node will try to connect
to all of them and will become a slave attached to the first node it can
successfully connect to.

=back

This function will block until all nodes have been resolved and, for slave
nodes, until it has successfully established a connection to a master
server.

Example: become a public node listening on the default node.

   initialise_node;

Example: become a public node, and try to contact some well-known master
servers to become part of the network.

   initialise_node undef, "master1", "master2";

Example: become a public node listening on port C<4041>.

   initialise_node 4041;

Example: become a public node, only visible on localhost port 4044.

   initialise_node "locahost:4044";

Example: become a slave node to any of the specified master servers.

   initialise_node "slave/", "master1", "192.168.13.17", "mp.example.net";

=item $cv = resolve_node $noderef

Takes an unresolved node reference that may contain hostnames and
abbreviated IDs, resolves all of them and returns a resolved node
reference.

In addition to C<address:port> pairs allowed in resolved noderefs, the
following forms are supported:

=over 4

=item the empty string

An empty-string component gets resolved as if the default port (4040) was
specified.

=item naked port numbers (e.g. C<1234>)

These are resolved by prepending the local nodename and a colon, to be
further resolved.

=item hostnames (e.g. C<localhost:1234>, C<localhost>)

These are resolved by using AnyEvent::DNS to resolve them, optionally
looking up SRV records for the C<aemp=4040> port, if no port was
specified.

=back

=item $SELF

Contains the current port id while executing C<rcv> callbacks or C<psub>
blocks.

=item SELF, %SELF, @SELF...

Due to some quirks in how perl exports variables, it is impossible to
just export C<$SELF>, all the symbols called C<SELF> are exported by this
module, but only C<$SELF> is currently used.

=item snd $port, type => @data

=item snd $port, @msg

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

=item $local_port = port

Create a new local port object that can be used either as a pattern
matching port ("full port") or a single-callback port ("miniport"),
depending on how C<rcv> callbacks are bound to the object.

=item $port = port { my @msg = @_; $finished }

Creates a "miniport", that is, a very lightweight port without any pattern
matching behind it, and returns its ID. Semantically the same as creating
a port and calling C<rcv $port, $callback> on it.

The block will be called for every message received on the port. When the
callback returns a true value its job is considered "done" and the port
will be destroyed. Otherwise it will stay alive.

The message will be passed as-is, no extra argument (i.e. no port id) will
be passed to the callback.

If you need the local port id in the callback, this works nicely:

   my $port; $port = port {
      snd $otherport, reply => $port;
   };

=cut

sub rcv($@);

sub port(;&) {
   my $id = "$UNIQ." . $ID++;
   my $port = "$NODE#$id";

   if (@_) {
      rcv $port, shift;
   } else {
      $PORT{$id} = sub { }; # nop
   }

   $port
}

=item reg $port, $name

=item reg $name

Registers the given port (or C<$SELF><<< if missing) under the name
C<$name>. If the name already exists it is replaced.

A port can only be registered under one well known name.

A port automatically becomes unregistered when it is killed.

=cut

sub reg(@) {
   my $port = @_ > 1 ? shift : $SELF || Carp::croak 'reg: called with one argument only, but $SELF not set,';

   $REG{$_[0]} = $port;
}

=item rcv $port, $callback->(@msg)

Replaces the callback on the specified miniport (after converting it to
one if required).

=item rcv $port, tagstring        => $callback->(@msg), ...

=item rcv $port, $smartmatch      => $callback->(@msg), ...

=item rcv $port, [$smartmatch...] => $callback->(@msg), ...

Register callbacks to be called on matching messages on the given full
port (after converting it to one if required) and return the port.

The callback has to return a true value when its work is done, after
which is will be removed, or a false value in which case it will stay
registered.

The global C<$SELF> (exported by this module) contains C<$port> while
executing the callback.

Runtime errors during callback execution will result in the port being
C<kil>ed.

If the match is an array reference, then it will be matched against the
first elements of the message, otherwise only the first element is being
matched.

Any element in the match that is specified as C<_any_> (a function
exported by this module) matches any single element of the message.

While not required, it is highly recommended that the first matching
element is a string identifying the message. The one-string-only match is
also the most efficient match (by far).

Example: create a port and bind receivers on it in one go.

  my $port = rcv port,
     msg1 => sub { ...; 0 },
     msg2 => sub { ...; 0 },
  ;

Example: create a port, bind receivers and send it in a message elsewhere
in one go:

   snd $otherport, reply =>
      rcv port,
         msg1 => sub { ...; 0 },
         ...
   ;

=cut

sub rcv($@) {
   my $port = shift;
   my ($noderef, $portid) = split /#/, $port, 2;

   ($NODE{$noderef} || add_node $noderef) == $NODE{""}
      or Carp::croak "$port: rcv can only be called on local ports, caught";

   if (@_ == 1) {
      my $cb = shift;
      delete $PORT_DATA{$portid};
      $PORT{$portid} = sub {
         local $SELF = $port;
         eval {
            &$cb
               and kil $port;
         };
         _self_die if $@;
      };
   } else {
      my $self = $PORT_DATA{$portid} ||= do {
         my $self = bless {
            id    => $port,
         }, "AnyEvent::MP::Port";

         $PORT{$portid} = sub {
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

         $self
      };

      "AnyEvent::MP::Port" eq ref $self
         or Carp::croak "$port: rcv can only be called on message matching ports, caught";

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

   $port
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

=item $guard = mon $port, $cb->(@reason)

=item $guard = mon $port, $rcvport

=item $guard = mon $port

=item $guard = mon $port, $rcvport, @msg

Monitor the given port and do something when the port is killed or
messages to it were lost, and optionally return a guard that can be used
to stop monitoring again.

C<mon> effectively guarantees that, in the absence of hardware failures,
that after starting the monitor, either all messages sent to the port
will arrive, or the monitoring action will be invoked after possible
message loss has been detected. No messages will be lost "in between"
(after the first lost message no further messages will be received by the
port). After the monitoring action was invoked, further messages might get
delivered again.

In the first form (callback), the callback is simply called with any
number of C<@reason> elements (no @reason means that the port was deleted
"normally"). Note also that I<< the callback B<must> never die >>, so use
C<eval> if unsure.

In the second form (another port given), the other port (C<$rcvport>)
will be C<kil>'ed with C<@reason>, iff a @reason was specified, i.e. on
"normal" kils nothing happens, while under all other conditions, the other
port is killed with the same reason.

The third form (kill self) is the same as the second form, except that
C<$rvport> defaults to C<$SELF>.

In the last form (message), a message of the form C<@msg, @reason> will be
C<snd>.

As a rule of thumb, monitoring requests should always monitor a port from
a local port (or callback). The reason is that kill messages might get
lost, just like any other message. Another less obvious reason is that
even monitoring requests can get lost (for exmaple, when the connection
to the other node goes down permanently). When monitoring a port locally
these problems do not exist.

Example: call a given callback when C<$port> is killed.

   mon $port, sub { warn "port died because of <@_>\n" };

Example: kill ourselves when C<$port> is killed abnormally.

   mon $port;

Example: send us a restart message when another C<$port> is killed.

   mon $port, $self => "restart";

=cut

sub mon {
   my ($noderef, $port) = split /#/, shift, 2;

   my $node = $NODE{$noderef} || add_node $noderef;

   my $cb = @_ ? shift : $SELF || Carp::croak 'mon: called with one argument only, but $SELF not set,';

   unless (ref $cb) {
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

   #TODO: mon-less form?

   mon $port, sub { 0 && @refs }
}

=item kil $port[, @reason]

Kill the specified port with the given C<@reason>.

If no C<@reason> is specified, then the port is killed "normally" (linked
ports will not be kileld, or even notified).

Otherwise, linked ports get killed with the same reason (second form of
C<mon>, see below).

Runtime errors while evaluating C<rcv> callbacks or inside C<psub> blocks
will be reported as reason C<< die => $@ >>.

Transport/communication errors are reported as C<< transport_error =>
$message >>.

=cut

=item $port = spawn $node, $initfunc[, @initdata]

Creates a port on the node C<$node> (which can also be a port ID, in which
case it's the node where that port resides).

The port ID of the newly created port is return immediately, and it is
permissible to immediately start sending messages or monitor the port.

After the port has been created, the init function is
called. This function must be a fully-qualified function name
(e.g. C<MyApp::Chat::Server::init>). To specify a function in the main
program, use C<::name>.

If the function doesn't exist, then the node tries to C<require>
the package, then the package above the package and so on (e.g.
C<MyApp::Chat::Server>, C<MyApp::Chat>, C<MyApp>) until the function
exists or it runs out of package names.

The init function is then called with the newly-created port as context
object (C<$SELF>) and the C<@initdata> values as arguments.

A common idiom is to pass your own port, monitor the spawned port, and
in the init function, monitor the original port. This two-way monitoring
ensures that both ports get cleaned up when there is a problem.

Example: spawn a chat server port on C<$othernode>.

   # this node, executed from within a port context:
   my $server = spawn $othernode, "MyApp::Chat::Server::connect", $SELF;
   mon $server;

   # init function on C<$othernode>
   sub connect {
      my ($srcport) = @_;

      mon $srcport;

      rcv $SELF, sub {
         ...
      };
   }

=cut

sub _spawn {
   my $port = shift;
   my $init = shift;

   local $SELF = "$NODE#$port";
   eval {
      &{ load_func $init }
   };
   _self_die if $@;
}

sub spawn(@) {
   my ($noderef, undef) = split /#/, shift, 2;

   my $id = "$RUNIQ." . $ID++;

   $_[0] =~ /::/
      or Carp::croak "spawn init function must be a fully-qualified name, caught";

   ($NODE{$noderef} || add_node $noderef)
      ->send (["", "AnyEvent::MP::_spawn" => $id, @_]);

   "$noderef#$id"
}

=back

=head1 NODE MESSAGES

Nodes understand the following messages sent to them. Many of them take
arguments called C<@reply>, which will simply be used to compose a reply
message - C<$reply[0]> is the port to reply to, C<$reply[1]> the type and
the remaining arguments are simply the message data.

While other messages exist, they are not public and subject to change.

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

=head1 AnyEvent::MP vs. Distributed Erlang

AnyEvent::MP got lots of its ideas from distributed Erlang (Erlang node
== aemp node, Erlang process == aemp port), so many of the documents and
programming techniques employed by Erlang apply to AnyEvent::MP. Here is a
sample:

   http://www.Erlang.se/doc/programming_rules.shtml
   http://Erlang.org/doc/getting_started/part_frame.html # chapters 3 and 4
   http://Erlang.org/download/Erlang-book-part1.pdf      # chapters 5 and 6
   http://Erlang.org/download/armstrong_thesis_2003.pdf  # chapters 4 and 5

Despite the similarities, there are also some important differences:

=over 4

=item * Node references contain the recipe on how to contact them.

Erlang relies on special naming and DNS to work everywhere in the
same way. AEMP relies on each node knowing it's own address(es), with
convenience functionality.

This means that AEMP requires a less tightly controlled environment at the
cost of longer node references and a slightly higher management overhead.

=item * Erlang uses processes and a mailbox, AEMP does not queue.

Erlang uses processes that selctively receive messages, and therefore
needs a queue. AEMP is event based, queuing messages would serve no useful
purpose.

(But see L<Coro::MP> for a more Erlang-like process model on top of AEMP).

=item * Erlang sends are synchronous, AEMP sends are asynchronous.

Sending messages in Erlang is synchronous and blocks the process. AEMP
sends are immediate, connection establishment is handled in the
background.

=item * Erlang can silently lose messages, AEMP cannot.

Erlang makes few guarantees on messages delivery - messages can get lost
without any of the processes realising it (i.e. you send messages a, b,
and c, and the other side only receives messages a and c).

AEMP guarantees correct ordering, and the guarantee that there are no
holes in the message sequence.

=item * In Erlang, processes can be declared dead and later be found to be
alive.

In Erlang it can happen that a monitored process is declared dead and
linked processes get killed, but later it turns out that the process is
still alive - and can receive messages.

In AEMP, when port monitoring detects a port as dead, then that port will
eventually be killed - it cannot happen that a node detects a port as dead
and then later sends messages to it, finding it is still alive.

=item * Erlang can send messages to the wrong port, AEMP does not.

In Erlang it is quite possible that a node that restarts reuses a process
ID known to other nodes for a completely different process, causing
messages destined for that process to end up in an unrelated process.

AEMP never reuses port IDs, so old messages or old port IDs floating
around in the network will not be sent to an unrelated port.

=item * Erlang uses unprotected connections, AEMP uses secure
authentication and can use TLS.

AEMP can use a proven protocol - SSL/TLS - to protect connections and
securely authenticate nodes.

=item * The AEMP protocol is optimised for both text-based and binary
communications.

The AEMP protocol, unlike the Erlang protocol, supports both
language-independent text-only protocols (good for debugging) and binary,
language-specific serialisers (e.g. Storable).

It has also been carefully designed to be implementable in other languages
with a minimum of work while gracefully degrading fucntionality to make the
protocol simple.

=item * AEMP has more flexible monitoring options than Erlang.

In Erlang, you can chose to receive I<all> exit signals as messages
or I<none>, there is no in-between, so monitoring single processes is
difficult to implement. Monitoring in AEMP is more flexible than in
Erlang, as one can choose between automatic kill, exit message or callback
on a per-process basis.

=item * Erlang tries to hide remote/local connections, AEMP does not.

Monitoring in Erlang is not an indicator of process death/crashes,
as linking is (except linking is unreliable in Erlang).

In AEMP, you don't "look up" registered port names or send to named ports
that might or might not be persistent. Instead, you normally spawn a port
on the remote node. The init function monitors the you, and you monitor
the remote port. Since both monitors are local to the node, they are much
more reliable.

This also saves round-trips and avoids sending messages to the wrong port
(hard to do in Erlang).

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

