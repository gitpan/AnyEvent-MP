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

use AnyEvent::MP::Util ();
use AnyEvent::MP::Node;
use AnyEvent::MP::Transport;

use utf8;
use common::sense;

use Carp ();

use AE ();

use base "Exporter";

our $VERSION = '0.01';
our @EXPORT = qw(NODE $NODE $PORT snd rcv _any_);

our $DEFAULT_SECRET;
our $DEFAULT_PORT = "4040";

our $CONNECT_INTERVAL =  5; # new connect every 5s, at least
our $CONNECT_TIMEOUT  = 30; # includes handshake

sub default_secret {
   unless (defined $DEFAULT_SECRET) {
      if (open my $fh, "<$ENV{HOME}/.aemp-secret") {
         sysread $fh, $DEFAULT_SECRET, -s $fh;
      } else {
         $DEFAULT_SECRET = AnyEvent::MP::Util::nonce 32;
      }
   }

   $DEFAULT_SECRET
}

=item NODE / $NODE

The C<NODE ()> function and the C<$NODE> variable contain the noderef of
the local node. The value is initialised by a call to C<become_public> or
C<become_slave>, after which all local port identifiers become invalid.

=cut

our $UNIQ = sprintf "%x.%x", $$, time; # per-process/node unique cookie
our $ID   = "a0";
our $PUBLIC = 0;
our $NODE;
our $PORT;

our %NODE; # node id to transport mapping, or "undef", for local node
our %PORT; # local ports
our %LISTENER; # local transports

sub NODE() { $NODE }

{
   use POSIX ();
   my $nodename = (POSIX::uname)[1];
   $NODE = "$$\@$nodename";
}

sub _ANY_() { 1 }
sub _any_() { \&_ANY_ }

sub add_node {
   my ($noderef) = @_;

   return $NODE{$noderef}
      if exists $NODE{$noderef};

   for (split /,/, $noderef) {
      return $NODE{$noderef} = $NODE{$_}
         if exists $NODE{$_};
   }

   # for indirect sends, use a different class
   my $node = new AnyEvent::MP::Node::Direct $noderef;

   $NODE{$_} = $node
      for $noderef, split /,/, $noderef;

   $node
}

=item snd $portid, type => @data

=item snd $portid, @msg

Send the given message to the given port ID, which can identify either a
local or a remote port.

While the message can be about anything, it is highly recommended to use
a constant string as first element.

The message data effectively becomes read-only after a call to this
function: modifying any argument is not allowed and can cause many
problems.

The type of data you can transfer depends on the transport protocol: when
JSON is used, then only strings, numbers and arrays and hashes consisting
of those are allowed (no objects). When Storable is used, then anything
that Storable can serialise and deserialise is allowed, and for the local
node, anything can be passed.

=cut

sub snd(@) {
   my ($noderef, $port) = split /#/, shift, 2;

   add_node $noderef
      unless exists $NODE{$noderef};

   $NODE{$noderef}->send (["$port", [@_]]);
}

=item rcv $portid, type => $callback->(@msg)

=item rcv $portid, $smartmatch => $callback->(@msg)

=item rcv $portid, [$smartmatch...] => $callback->(@msg)

Register a callback on the port identified by C<$portid>, which I<must> be
a local port.

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
   my ($port, $match, $cb) = @_;

   my $port = $PORT{$port}
      or do {
         my ($noderef, $lport) = split /#/, $port;
         "AnyEvent::MP::Node::Self" eq ref $NODE{$noderef}
            or Carp::croak "$port: can only rcv on local ports";

         $PORT{$lport}
            or Carp::croak "$port: port does not exist";
            
         $PORT{$port} = $PORT{$lport} # also return
      };

   if (!ref $match) {
      push @{ $port->{rc0}{$match}      }, [$cb];
   } elsif (("ARRAY" eq ref $match && !ref $match->[0])) {
      my ($type, @match) = @$match;
      @match
         ? push @{ $port->{rcv}{$match->[0]} }, [$cb, \@match]
         : push @{ $port->{rc0}{$match->[0]} }, [$cb];
   } else {
      push @{ $port->{any}              }, [$cb, $match];
   }
}

sub _inject {
   my ($port, $msg) = @{+shift};

   $port = $PORT{$port}
      or return;

   @_ = @$msg;

   for (@{ $port->{rc0}{$msg->[0]} }) {
      $_ && &{$_->[0]}
         && undef $_;
   }

   for (@{ $port->{rcv}{$msg->[0]} }) {
      $_ && [@_[1..$#{$_->[1]}]] ~~ $_->[1]
         && &{$_->[0]}
         && undef $_;
   }

   for (@{ $port->{any} }) {
      $_ &&           [@_[0..$#{$_->[1]}]] ~~ $_->[1]
         && &{$_->[0]}
         && undef $_;
   }
}

sub normalise_noderef($) {
   my ($noderef) = @_;

   my $cv = AE::cv;
   my @res;

   $cv->begin (sub {
      my %seen;
      my @refs;
      for (sort { $a->[0] <=> $b->[0] } @res) {
         push @refs, $_->[1] unless $seen{$_->[1]}++
      }
      shift->send (join ",", @refs);
   });

   $noderef = $DEFAULT_PORT unless length $noderef;

   my $idx;
   for my $t (split /,/, $noderef) {
      my $pri = ++$idx;
      
      #TODO: this should be outside normalise_noderef and in become_public
      if ($t =~ /^\d*$/) {
         my $nodename = (POSIX::uname)[1];

         $cv->begin;
         AnyEvent::Socket::resolve_sockaddr $nodename, $t || "aemp=$DEFAULT_PORT", "tcp", 0, undef, sub {
            for (@_) {
               my ($service, $host) = AnyEvent::Socket::unpack_sockaddr $_->[3];
               push @res, [
                  $pri += 1e-5,
                  AnyEvent::Socket::format_hostport AnyEvent::Socket::format_address $host, $service
               ];
            }
            $cv->end;
         };

#         my (undef, undef, undef, undef, @ipv4) = gethostbyname $nodename;
#
#         for (@ipv4) {
#            push @res, [
#               $pri,
#               AnyEvent::Socket::format_hostport AnyEvent::Socket::format_address $_, $t || $DEFAULT_PORT,
#            ];
#         }
      } else {
         my ($host, $port) = AnyEvent::Socket::parse_hostport $t, "aemp=$DEFAULT_PORT"
            or Carp::croak "$t: unparsable transport descriptor";

         $cv->begin;
         AnyEvent::Socket::resolve_sockaddr $host, $port, "tcp", 0, undef, sub {
            for (@_) {
               my ($service, $host) = AnyEvent::Socket::unpack_sockaddr $_->[3];
               push @res, [
                  $pri += 1e-5,
                  AnyEvent::Socket::format_hostport AnyEvent::Socket::format_address $host, $service
               ];
            }
            $cv->end;
         }
      }
   }

   $cv->end;

   $cv
}

sub become_public {
   return if $PUBLIC;

   my $noderef = join ",", ref $_[0] ? @{+shift} : shift;
   my @args = @_;

   $NODE = (normalise_noderef $noderef)->recv;

   for my $t (split /,/, $NODE) {
      $NODE{$t} = $NODE{""};

      my ($host, $port) = AnyEvent::Socket::parse_hostport $t;

      $LISTENER{$t} = AnyEvent::MP::Transport::mp_server $host, $port,
         @args,
         on_error   => sub {
            die "on_error<@_>\n";#d#
         },
         on_connect => sub {
            my ($tp) = @_;

            $NODE{$tp->{remote_id}} = $_[0];
         },
         sub {
            my ($tp) = @_;

            $NODE{"$tp->{peerhost}:$tp->{peerport}"} = $tp;
         },
      ;
   }

   $PUBLIC = 1;
}

=back

=head1 NODE MESSAGES

Nodes understand the following messages sent to them. Many of them take
arguments called C<@reply>, which will simply be used to compose a reply
message - C<$reply[0]> is the port to reply to, C<$reply[1]> the type and
the remaining arguments are simply the message data.

=over 4

=cut

#############################################################################
# self node code

sub _new_port($) {
   my ($name) = @_;

   my ($noderef, $portname) = split /#/, $name;

   $PORT{$name} =
   $PORT{$portname} = {
      names => [$name, $portname],
   };
}

$NODE{""} = new AnyEvent::MP::Node::Self noderef => $NODE;
_new_port "";

=item relay => $port, @msg

Simply forwards the message to the given port.

=cut

rcv "", relay => \&snd;

=item eval => $string[ @reply]

Evaluates the given string. If C<@reply> is given, then a message of the
form C<@reply, $@, @evalres> is sent.

Example: crash another node.

   snd $othernode, eval => "exit";

=cut

rcv "", eval => sub {
   my (undef, $string, @reply) = @_;
   my @res = eval $string;
   snd @reply, "$@", @res if @reply;
};

=item time => @reply

Replies the the current node time to C<@reply>.

Example: tell the current node to send the current time to C<$myport> in a
C<timereply> message.

   snd $NODE, time => $myport, timereply => 1, 2;
   # => snd $myport, timereply => 1, 2, <time>

=cut

rcv "", time  => sub { shift; snd @_, AE::time };

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

