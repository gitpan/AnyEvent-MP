=head1 NAME

AnyEvent::MP - multi-processing/message-passing framework

=head1 SYNOPSIS

   use AnyEvent::MP;

   $NODE      # contains this node's noderef
   NODE       # returns this node's noderef
   NODE $port # returns the noderef of the port

   $SELF      # receiving/own port id in rcv callbacks

   # initialise the node so it can send/receive messages
   initialise_node;                  # -OR-
   initialise_node "localhost:4040"; # -OR-
   initialise_node "slave/", "localhost:4040"

   # ports are message endpoints

   # sending messages
   snd $port, type => data...;
   snd $port, @msg;
   snd @msg_with_first_element_being_a_port;

   # creating/using ports, the simple way
   my $simple_port = port { my @msg = @_; 0 };

   # creating/using ports, tagged message matching
   my $port = port;
   rcv $port, ping => sub { snd $_[0], "pong"; 0 };
   rcv $port, pong => sub { warn "pong received\n"; 0 };

   # create a port on another node
   my $port = spawn $node, $initfunc, @initdata;

   # monitoring
   mon $port, $cb->(@msg)      # callback is invoked on death
   mon $port, $otherport       # kill otherport on abnormal death
   mon $port, $otherport, @msg # send message on death

=head1 CURRENT STATUS

   AnyEvent::MP            - stable API, should work
   AnyEvent::MP::Intro     - outdated
   AnyEvent::MP::Kernel    - WIP
   AnyEvent::MP::Transport - mostly stable

   stay tuned.

=head1 DESCRIPTION

This module (-family) implements a simple message passing framework.

Despite its simplicity, you can securely message other processes running
on the same or other hosts.

For an introduction to this module family, see the L<AnyEvent::MP::Intro>
manual page.

At the moment, this module family is severly broken and underdocumented,
so do not use. This was uploaded mainly to reserve the CPAN namespace -
stay tuned!

=head1 CONCEPTS

=over 4

=item port

A port is something you can send messages to (with the C<snd> function).

Ports allow you to register C<rcv> handlers that can match all or just
some messages. Messages will not be queued.

=item port id - C<noderef#portname>

A port ID is the concatenation of a noderef, a hash-mark (C<#>) as
separator, and a port name (a printable string of unspecified format). An
exception is the the node port, whose ID is identical to its node
reference.

=item node

A node is a single process containing at least one port - the node port,
which provides nodes to manage each other remotely, and to create new
ports.

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

use AnyEvent::MP::Kernel;

use common::sense;

use Carp ();

use AE ();

use base "Exporter";

our $VERSION = $AnyEvent::MP::Kernel::VERSION;

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

The C<NODE> function returns, and the C<$NODE> variable contains the
noderef of the local node. The value is initialised by a call to
C<initialise_node>.

=item $noderef = node_of $port

Extracts and returns the noderef from a port ID or a noderef.

=item initialise_node $noderef, $seednode, $seednode...

=item initialise_node "slave/", $master, $master...

Before a node can talk to other nodes on the network it has to initialise
itself - the minimum a node needs to know is it's own name, and optionally
it should know the noderefs of some other nodes in the network.

This function initialises a node - it must be called exactly once (or
never) before calling other AnyEvent::MP functions.

All arguments (optionally except for the first) are noderefs, which can be
either resolved or unresolved.

The first argument will be looked up in the configuration database first
(if it is C<undef> then the current nodename will be used instead) to find
the relevant configuration profile (see L<aemp>). If none is found then
the default configuration is used. The configuration supplies additional
seed/master nodes and can override the actual noderef.

There are two types of networked nodes, public nodes and slave nodes:

=over 4

=item public nodes

For public nodes, C<$noderef> (supplied either directly to
C<initialise_node> or indirectly via a profile or the nodename) must be a
noderef (possibly unresolved, in which case it will be resolved).

After resolving, the node will bind itself on all endpoints and try to
connect to all additional C<$seednodes> that are specified. Seednodes are
optional and can be used to quickly bootstrap the node into an existing
network.

=item slave nodes

When the C<$noderef> (either as given or overriden by the config file)
is the special string C<slave/>, then the node will become a slave
node. Slave nodes cannot be contacted from outside and will route most of
their traffic to the master node that they attach to.

At least one additional noderef is required (either by specifying it
directly or because it is part of the configuration profile): The node
will try to connect to all of them and will become a slave attached to the
first node it can successfully connect to.

=back

This function will block until all nodes have been resolved and, for slave
nodes, until it has successfully established a connection to a master
server.

Example: become a public node listening on the guessed noderef, or the one
specified via C<aemp> for the current node. This should be the most common
form of invocation for "daemon"-type nodes.

   initialise_node;

Example: become a slave node to any of the the seednodes specified via
C<aemp>.  This form is often used for commandline clients.

   initialise_node "slave/";

Example: become a slave node to any of the specified master servers. This
form is also often used for commandline clients.

   initialise_node "slave/", "master1", "192.168.13.17", "mp.example.net";

Example: become a public node, and try to contact some well-known master
servers to become part of the network.

   initialise_node undef, "master1", "master2";

Example: become a public node listening on port C<4041>.

   initialise_node 4041;

Example: become a public node, only visible on localhost port 4044.

   initialise_node "localhost:4044";

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
a local or a remote port, and must be a port ID.

While the message can be about anything, it is highly recommended to use a
string as first element (a port ID, or some word that indicates a request
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

Create a new local port object and returns its port ID. Initially it has
no callbacks set and will throw an error when it receives messages.

=item $local_port = port { my @msg = @_ }

Creates a new local port, and returns its ID. Semantically the same as
creating a port and calling C<rcv $port, $callback> on it.

The block will be called for every message received on the port, with the
global variable C<$SELF> set to the port ID. Runtime errors will cause the
port to be C<kil>ed. The message will be passed as-is, no extra argument
(i.e. no port ID) will be passed to the callback.

If you want to stop/destroy the port, simply C<kil> it:

   my $port = port {
      my @msg = @_;
      ...
      kil $SELF;
   };

=cut

sub rcv($@);

sub _kilme {
   die "received message on port without callback";
}

sub port(;&) {
   my $id = "$UNIQ." . $ID++;
   my $port = "$NODE#$id";

   rcv $port, shift || \&_kilme;

   $port
}

=item rcv $local_port, $callback->(@msg)

Replaces the default callback on the specified port. There is no way to
remove the default callback: use C<sub { }> to disable it, or better
C<kil> the port when it is no longer needed.

The global C<$SELF> (exported by this module) contains C<$port> while
executing the callback. Runtime errors during callback execution will
result in the port being C<kil>ed.

The default callback received all messages not matched by a more specific
C<tag> match.

=item rcv $local_port, tag => $callback->(@msg_without_tag), ...

Register (or replace) callbacks to be called on messages starting with the
given tag on the given port (and return the port), or unregister it (when
C<$callback> is C<$undef> or missing). There can only be one callback
registered for each tag.

The original message will be passed to the callback, after the first
element (the tag) has been removed. The callback will use the same
environment as the default callback (see above).

Example: create a port and bind receivers on it in one go.

  my $port = rcv port,
     msg1 => sub { ... },
     msg2 => sub { ... },
  ;

Example: create a port, bind receivers and send it in a message elsewhere
in one go:

   snd $otherport, reply =>
      rcv port,
         msg1 => sub { ... },
         ...
   ;

Example: temporarily register a rcv callback for a tag matching some port
(e.g. for a rpc reply) and unregister it after a message was received.

   rcv $port, $otherport => sub {
      my @reply = @_;

      rcv $SELF, $otherport;
   };

=cut

sub rcv($@) {
   my $port = shift;
   my ($noderef, $portid) = split /#/, $port, 2;

   ($NODE{$noderef} || add_node $noderef) == $NODE{""}
      or Carp::croak "$port: rcv can only be called on local ports, caught";

   while (@_) {
      if (ref $_[0]) {
         if (my $self = $PORT_DATA{$portid}) {
            "AnyEvent::MP::Port" eq ref $self
               or Carp::croak "$port: rcv can only be called on message matching ports, caught";

            $self->[2] = shift;
         } else {
            my $cb = shift;
            $PORT{$portid} = sub {
               local $SELF = $port;
               eval { &$cb }; _self_die if $@;
            };
         }
      } elsif (defined $_[0]) {
         my $self = $PORT_DATA{$portid} ||= do {
            my $self = bless [$PORT{$port} || sub { }, { }, $port], "AnyEvent::MP::Port";

            $PORT{$portid} = sub {
               local $SELF = $port;

               if (my $cb = $self->[1]{$_[0]}) {
                  shift;
                  eval { &$cb }; _self_die if $@;
               } else {
                  &{ $self->[0] };
               }
            };

            $self
         };

         "AnyEvent::MP::Port" eq ref $self
            or Carp::croak "$port: rcv can only be called on message matching ports, caught";

         my ($tag, $cb) = splice @_, 0, 2;

         if (defined $cb) {
            $self->[1]{$tag} = $cb;
         } else {
            delete $self->[1]{$tag};
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

   snd_to_func $noderef, "AnyEvent::MP::_spawn" => $id, @_;

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

=item * Erlang has a "remote ports are like local ports" philosophy, AEMP
uses "local ports are like remote ports".

The failure modes for local ports are quite different (runtime errors
only) then for remote ports - when a local port dies, you I<know> it dies,
when a connection to another node dies, you know nothing about the other
port.

Erlang pretends remote ports are as reliable as local ports, even when
they are not.

AEMP encourages a "treat remote ports differently" philosophy, with local
ports being the special case/exception, where transport errors cannot
occur.

=item * Erlang uses processes and a mailbox, AEMP does not queue.

Erlang uses processes that selectively receive messages, and therefore
needs a queue. AEMP is event based, queuing messages would serve no
useful purpose. For the same reason the pattern-matching abilities of
AnyEvent::MP are more limited, as there is little need to be able to
filter messages without dequeing them.

(But see L<Coro::MP> for a more Erlang-like process model on top of AEMP).

=item * Erlang sends are synchronous, AEMP sends are asynchronous.

Sending messages in Erlang is synchronous and blocks the process (and
so does not need a queue that can overflow). AEMP sends are immediate,
connection establishment is handled in the background.

=item * Erlang suffers from silent message loss, AEMP does not.

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

In Erlang it is quite likely that a node that restarts reuses a process ID
known to other nodes for a completely different process, causing messages
destined for that process to end up in an unrelated process.

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

=head1 RATIONALE

=over 4

=item Why strings for ports and noderefs, why not objects?

We considered "objects", but found that the actual number of methods
thatc an be called are very low. Since port IDs and noderefs travel over
the network frequently, the serialising/deserialising would add lots of
overhead, as well as having to keep a proxy object.

Strings can easily be printed, easily serialised etc. and need no special
procedures to be "valid".

And a a miniport consists of a single closure stored in a global hash - it
can't become much cheaper.

=item Why favour JSON, why not real serialising format such as Storable?

In fact, any AnyEvent::MP node will happily accept Storable as framing
format, but currently there is no way to make a node use Storable by
default.

The default framing protocol is JSON because a) JSON::XS is many times
faster for small messages and b) most importantly, after years of
experience we found that object serialisation is causing more problems
than it gains: Just like function calls, objects simply do not travel
easily over the network, mostly because they will always be a copy, so you
always have to re-think your design.

Keeping your messages simple, concentrating on data structures rather than
objects, will keep your messages clean, tidy and efficient.

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

