=head1 NAME

AnyEvent::MP::Global - some network-global services

=head1 SYNOPSIS

   use AnyEvent::MP::Global;

=head1 DESCRIPTION

This module maintains a fully-meshed network, if possible, and tries to
ensure that we are connected to at least one other node.

It also manages named port groups - ports can register themselves in any
number of groups that will be available network-wide, which is great for
discovering services.

Running it on one node will automatically run it on all nodes, although,
at the moment, the global service is started by default anyways.

=head1 GLOBALS AND FUNCTIONS

=over 4

=cut

package AnyEvent::MP::Global;

use common::sense;
use Carp ();
use MIME::Base64 ();

use AnyEvent ();
use AnyEvent::Util ();

use AnyEvent::MP;
use AnyEvent::MP::Kernel;

our $VERSION = $AnyEvent::MP::VERSION;

our %addr; # port ID => [address...] mapping

our %port; # our rendezvous port on the other side
our %lreg; # local registry, name => [pid...]
our %lmon; # local rgeistry monitoring name,pid => mon
our %greg; # global regstry, name => [pid...]

our $nodecnt;

$AnyEvent::MP::Kernel::WARN->(7, "starting global service.");

#############################################################################
# seednodes

our @SEEDS;
our %SEED_CONNECT;
our $SEED_WATCHER;

sub seed_connect {
   my ($seed) = @_;

   my ($host, $port) = AnyEvent::Socket::parse_hostport $seed
      or Carp::croak "$seed: unparsable seed address";

   # ughhh
   $SEED_CONNECT{$seed} ||= AnyEvent::MP::Transport::mp_connect $host, $port,
      seed => $seed,
      sub {
         delete $SEED_CONNECT{$seed};
         after 1, \&more_seeding;
      },
   ;
}

sub more_seeding {
   return if $nodecnt;
   return unless @SEEDS;

   $AnyEvent::MP::Kernel::WARN->(9, "no nodes connected, seeding.");

   seed_connect $SEEDS[rand @SEEDS];
}

sub avoid_seed($) {
   @SEEDS = grep $_ ne $_[0], @SEEDS;
}

sub set_seeds(@) {
   @SEEDS = @_;

   $SEED_WATCHER ||= AE::timer 5, $AnyEvent::MP::Kernel::MONITOR_TIMEOUT, \&more_seeding;

   seed_connect $_
      for @SEEDS;
}

#############################################################################

sub unreg_groups($) {
   my ($node) = @_;

   my $qr = qr/^\Q$node\E(?:#|$)/;

   for my $group (values %greg) {
      @$group = grep $_ !~ $qr, @$group;
   }
}

sub set_groups($$) {
   my ($node, $lreg) = @_;

   while (my ($k, $v) = each %$lreg) {
      push @{ $greg{$k} }, @$v;
   }
}

=item $guard = register $port, $group

Register the given (local!) port in the named global group C<$group>.

The port will be unregistered automatically when the port is destroyed.

When not called in void context, then a guard object will be returned that
will also cause the name to be unregistered when destroyed.

=cut

# register port from any node
sub _register {
   my ($port, $group) = @_;

   push @{ $greg{$group} }, $port;
}

# unregister port from any node
sub _unregister {
   my ($port, $group) = @_;

   @{ $greg{$group} } = grep $_ ne $port, @{ $greg{$group} };
}

# unregister local port
sub unregister {
   my ($port, $group) = @_;

   delete $lmon{"$group\x00$port"};
   @{ $lreg{$group} } = grep $_ ne $port, @{ $lreg{$group} };

   _unregister $port, $group;

   snd $_, reg0 => $port, $group
      for values %port;
}

# register local port
sub register($$) {
   my ($port, $group) = @_;

   port_is_local $port
      or Carp::croak "AnyEvent::MP::Global::register can only be called for local ports, caught";

   $lmon{"$group\x00$port"} = mon $port, sub { unregister $port, $group };
   push @{ $lreg{$group} }, $port;

   snd $_, reg1 => $port, $group
      for values %port;

   _register $port, $group;

   wantarray && AnyEvent::Util::guard { unregister $port, $group }
}

=item $ports = find $group

Returns all the ports currently registered to the given group (as
read-only array reference). When the group has no registered members,
return C<undef>.

=cut

sub find($) {
   @{ $greg{$_[0]} }
      ? $greg{$_[0]}
      : undef
}

sub start_node {
   my ($node) = @_;

   return if exists $port{$node};
   return if $node eq $NODE; # do not connect to ourselves

   # establish connection
   my $port = $port{$node} = spawn $node, "AnyEvent::MP::Global::connect", 0, $NODE;

   mon $port, sub {
      unreg_groups $node;
      delete $port{$node};
   };

   snd $port, addr => $AnyEvent::MP::Kernel::LISTENER;
   snd $port, connect_nodes => \%addr if %addr;
   snd $port, set => \%lreg if %lreg;
}

# other nodes connect via this
sub connect {
   my ($version, $node) = @_;

   # monitor them, silently die
   mon $node, psub { kil $SELF };

   rcv $SELF,
      addr => sub {
         my $addresses = shift;
         $AnyEvent::MP::Kernel::WARN->(9, "$node told us its addresses (@$addresses).");
         $addr{$node} = $addresses;

         # to help listener-less nodes, we broadcast new addresses to them unconditionally
         #TODO: should be done by a node finding out about a listener-less one
         if (@$addresses) {
            for my $other (values %AnyEvent::MP::NODE) {
               if ($other->{transport}) {
                  if ($addr{$other->{id}} && !@{ $addr{$other->{id}} }) {
                     $AnyEvent::MP::Kernel::WARN->(9, "helping $other->{id} to find $node.");
                     snd $port{$other->{id}}, connect_nodes => { $node => $addresses };
                  }
               }
            }
         }
      },
      connect_nodes => sub {
         my ($kv) = @_;

         use JSON::XS;#d#
         my $kv_txt = JSON::XS->new->encode ($kv);#d#
         $AnyEvent::MP::Kernel::WARN->(9, "$node told us it knows about $kv_txt.");#d#

         while (my ($id, $addresses) = each %$kv) {
            my $node = AnyEvent::MP::Kernel::add_node $id;
            $node->connect (@$addresses);
            start_node $id;
         }
      },
      find_node => sub {
         my ($othernode) = @_;

         $AnyEvent::MP::Kernel::WARN->(9, "$node asked us to find $othernode.");
         snd $port{$node}, connect_nodes => { $othernode => $addr{$othernode} }
            if $addr{$othernode};
      },
      set => sub {
         set_groups $node, shift;
      },
      reg1 => \&_register,
      reg0 => \&_unregister,
   ;
}

sub mon_node {
   my ($node, $is_up) = @_;

   if ($is_up) {
      ++$nodecnt;
      start_node $node;
   } else {
      --$nodecnt;
      more_seeding unless $nodecnt;
      unreg_groups $node;

      # forget about the node
      delete $addr{$node};
      # ask other nodes if they know the node
      snd $_, find_node => $node
         for values %port;
   }
   #warn "node<$node,$is_up>\n";#d#
}

mon_node $_, 1
   for up_nodes;

mon_nodes \&mon_node;

=back

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

