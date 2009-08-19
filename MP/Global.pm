=head1 NAME

AnyEvent::MP::Global - some network-global services

=head1 SYNOPSIS

   use AnyEvent::MP::Global;
   # -OR-
   aemp addservice AnyEvent::MP::Global::

=head1 DESCRIPTION

This module provides an assortment of network-global functions: group name
registration and non-local locks.

It will also try to build and maintain a full mesh of all network nodes.

While it isn't mandatory to run the global services, running it on one
node will automatically run it on all nodes.

=head1 GLOBALS AND FUNCTIONS

=over 4

=cut

package AnyEvent::MP::Global;

use common::sense;
use Carp ();
use MIME::Base64 ();

use AnyEvent::Util ();

use AnyEvent::MP;
use AnyEvent::MP::Kernel;

our $VERSION = $AnyEvent::MP::VERSION;

our %port; # our rendezvous port on the other side
our %lreg; # local registry, name => [pid...]
our %lmon; # local rgeistry monitoring name,pid => mon
our %greg; # global regstry, name => [pid...]

$AnyEvent::MP::Kernel::WARN->(7, "starting global service.");

sub unreg_groups($) {
   my ($noderef) = @_;

   my $qr = qr/^\Q$noderef\E(?:#|$)/;

   for my $group (values %greg) {
      @$group = grep $_ !~ $qr, @$group;
   }
}

sub set_groups($$) {
   my ($noderef, $lreg) = @_;

   while (my ($k, $v) = each %$lreg) {
      push @{ $greg{$k} }, @$v;
   }
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

sub start_node {
   my ($noderef) = @_;

   return if exists $port{$noderef};
   return if $noderef eq $NODE; # do not connect to ourselves

   # establish connection
   my $port = $port{$noderef} = spawn $noderef, "AnyEvent::MP::Global::connect", 0, $NODE;
   # request any other nodes possibly known to us
   mon $port, sub {
      unreg_groups $noderef;
      delete $port{$noderef};
   };
   snd $port, connect_nodes => up_nodes;
   snd $port, set => \%lreg;
}

# other nodes connect via this
sub connect {
   my ($version, $noderef) = @_;

   # monitor them, silently die
   mon $noderef, psub { kil $SELF };

   rcv $SELF,
      connect_nodes => sub {
         for (@_) {
            connect_node $_;
            start_node $_;
         }
      },
      set => sub {
         set_groups $noderef, shift;
      },
      reg1 => \&_register,
      reg0 => \&_unregister,
   ;
}

sub mon_node {
   my ($noderef, $is_up) = @_;

   if ($is_up) {
      start_node $noderef;
   } else {
      unreg_groups $noderef;
   }
   #warn "node<$noderef,$is_up>\n";#d#
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

