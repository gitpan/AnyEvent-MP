=head1 NAME

AnyEvent::MP::Node - represent a node

=head1 SYNOPSIS

   use AnyEvent::MP::Node;

=head1 DESCRIPTION

This is an internal utility module, horrible to look at, so don't.

=cut

package AnyEvent::MP::Node;

use common::sense;

use AE ();
use AnyEvent::Util ();
use AnyEvent::Socket ();

use AnyEvent::MP::Transport ();

sub new {
   my ($self, $id) = @_;

   $self = bless { id => $id }, $self;

   $self->init;
   $self->transport_reset;

   $self
}

sub init {
   #
}

sub send {
   &{ shift->{send} }
}

# nodes reachable via the network
package AnyEvent::MP::Node::External;

use base "AnyEvent::MP::Node";

# called at init time, mostly sets {send}
sub transport_reset {
   my ($self) = @_;

   delete $self->{transport};

   Scalar::Util::weaken $self;

   $self->{send} = sub {
      push @{$self->{queue}}, shift;
      $self->connect;
   };
}

# called each time we fail to establish a connection,
# or the existing connection failed
sub transport_error {
   my ($self, @reason) = @_;

   my $no_transport = !$self->{transport};

   delete $self->{connect_w};
   delete $self->{connect_to};

   delete $self->{queue};
   $self->transport_reset;

   if (my $mon = delete $self->{lmon}) {
      $_->(@reason) for map @$_, values %$mon;
   }

   AnyEvent::MP::Kernel::_inject_nodeevent ($self, 0, @reason)
      unless $no_transport;

   # if we are here and are idle, we nuke ourselves
   delete $AnyEvent::MP::Kernel::NODE{$self->{id}}
      unless $self->{transport} || $self->{connect_to};
}

# called after handshake was successful
sub transport_connect {
   my ($self, $transport) = @_;

   delete $self->{trial};

   $self->transport_error (transport_error => "switched connections")
      if $self->{transport};

   delete $self->{connect_addr};
   delete $self->{connect_w};
   delete $self->{connect_to};

   $self->{transport} = $transport;

   my $transport_send = $transport->can ("send");

   $self->{send} = sub {
      $transport_send->($transport, $_[0]);
   };

   AnyEvent::MP::Kernel::_inject_nodeevent ($self, 1);

   $transport->send ($_)
      for @{ delete $self->{queue} || [] };
}

sub connect {
   my ($self, @addresses) = @_;

   return if $self->{transport};

   Scalar::Util::weaken $self;

   my $monitor = $AnyEvent::MP::Kernel::CONFIG->{monitor_timeout};

   $self->{connect_to} ||= AE::timer $monitor, 0, sub {
      $self->transport_error (transport_error => $self->{id}, "unable to connect");
   };

   return unless @addresses;

   if ($self->{connect_w}) {
      # sometimes we get told about new addresses after we started to connect
      unshift @{$self->{connect_addr}}, @addresses;
      return;
   }

   $self->{connect_addr} = \@addresses; # a bit weird, but efficient

   $AnyEvent::MP::Kernel::WARN->(9, "connecting to $self->{id} with [@addresses]");

   my $interval = $AnyEvent::MP::Kernel::CONFIG->{connect_interval};

   $interval = ($monitor - $interval) / @addresses
      if ($monitor - $interval) / @addresses < $interval;

   $interval = 0.4 if $interval < 0.4;

   my @endpoints;

   $self->{connect_w} = AE::timer 0.050 * rand, $interval * (0.9 + 0.1 * rand), sub {
      @endpoints = @addresses
         unless @endpoints;

      my $endpoint = shift @endpoints;

      $AnyEvent::MP::Kernel::WARN->(9, "connecting to $self->{id} at $endpoint");

      $self->{trial}{$endpoint} ||= do {
         my ($host, $port) = AnyEvent::Socket::parse_hostport $endpoint
            or return $AnyEvent::MP::Kernel::WARN->(1, "$self->{id}: not a resolved node reference.");

         AnyEvent::MP::Transport::mp_connect
            $host, $port,
            sub { delete $self->{trial}{$endpoint} },
      };
   };
}

sub kill {
   my ($self, $port, @reason) = @_;

   $self->send (["", kil => $port, @reason]);
}

sub monitor {
   my ($self, $portid, $cb) = @_;

   my $list = $self->{lmon}{$portid} ||= [];

   $self->send (["", mon1 => $portid])
      unless @$list || !length $portid;

   push @$list, $cb;
}

sub unmonitor {
   my ($self, $portid, $cb) = @_;

   my $list = $self->{lmon}{$portid}
      or return;

   @$list = grep $_ != $cb, @$list;

   unless (@$list) {
      $self->send (["", mon0 => $portid]);
      delete $self->{monitor}{$portid};
   }
}

# used for direct slave connections as well
package AnyEvent::MP::Node::Direct;

use base "AnyEvent::MP::Node::External";

package AnyEvent::MP::Node::Self;

use base "AnyEvent::MP::Node";

sub connect {
   # we are trivially connected
}

# delay every so often to avoid recursion, also used to delay after spawn
our $DELAY = -50;
our @DELAY;
our $DELAY_W;

sub _send_delayed {
   local $AnyEvent::MP::Kernel::SRCNODE = $AnyEvent::MP::Kernel::NODE{""};
   (shift @DELAY)->()
      while @DELAY;
   undef $DELAY_W;
   $DELAY = -50;
}

sub transport_reset {
   my ($self) = @_;

   Scalar::Util::weaken $self;

   $self->{send} = sub {
      if ($DELAY++ >= 0) {
         my $msg = $_[0];
         push @DELAY, sub { AnyEvent::MP::Kernel::_inject (@$msg) };
         $DELAY_W ||= AE::timer 0, 0, \&_send_delayed;
         return;
      }

      local $AnyEvent::MP::Kernel::SRCNODE = $self;
      AnyEvent::MP::Kernel::_inject (@{ $_[0] });
   };
}

sub transport_connect {
   my ($self, $tp) = @_;

   $AnyEvent::MP::Kernel::WARN->(9, "I refuse to talk to myself ($tp->{peerhost}:$tp->{peerport})");
}

sub kill {
   my ($self, $port, @reason) = @_;

   my $delay_cb = sub {
      delete $AnyEvent::MP::Kernel::PORT{$port}
         or return; # killing nonexistent ports is O.K.
      delete $AnyEvent::MP::Kernel::PORT_DATA{$port};

      my $mon = delete $AnyEvent::MP::Kernel::LMON{$port}
         or !@reason
         or $AnyEvent::MP::Kernel::WARN->(8, "unmonitored local port $port died with reason: @reason");

      $_->(@reason) for values %$mon;
   };

   # we _always_ delay kil's, to avoid calling mon callbacks
   # from anything but the event loop context.
   $DELAY = 1;
   push @DELAY, $delay_cb;
   $DELAY_W ||= AE::timer 0, 0, \&_send_delayed;
}

sub monitor {
   my ($self, $portid, $cb) = @_;

   my $delay_cb = sub {
      return $cb->(no_such_port => "cannot monitor nonexistent port", "$self->{id}#$portid")
         unless exists $AnyEvent::MP::Kernel::PORT{$portid};

      $AnyEvent::MP::Kernel::LMON{$portid}{$cb+0} = $cb;
   };

   $DELAY_W ? push @DELAY, $delay_cb : &$delay_cb;
}

sub unmonitor {
   my ($self, $portid, $cb) = @_;

   my $delay_cb = sub {
      delete $AnyEvent::MP::Kernel::LMON{$portid}{$cb+0};
   };

   $DELAY_W ? push @DELAY, $delay_cb : &$delay_cb;
}

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

