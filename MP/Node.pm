=head1 NAME

AnyEvent::MP::Node - a single processing node (CPU/process...)

=head1 SYNOPSIS

   use AnyEvent::MP::Node;

=head1 DESCRIPTION

=cut

package AnyEvent::MP::Node;

use common::sense;

use AE ();
use AnyEvent::Util ();
use AnyEvent::Socket ();

use AnyEvent::MP::Transport ();

sub new {
   my ($self, $noderef) = @_;

   $self = bless { noderef => $noderef }, $self;

   $self->transport_reset;

   $self
}

sub send {
   &{ shift->{send} }
}

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

# called only after successful handshake
sub transport_error {
   my ($self, @reason) = @_;

   my $no_transport = !$self->{transport};

   delete $self->{connect_w};
   delete $self->{connect_to};

   delete $self->{queue};
   $self->transport_reset;

   AnyEvent::MP::Kernel::_inject_nodeevent ($self, 0, @reason)
      unless $no_transport;

   if (my $mon = delete $self->{lmon}) {
      $_->(@reason) for map @$_, values %$mon;
   }
}

# called after handshake was successful
sub transport_connect {
   my ($self, $transport) = @_;

   $self->transport_error (transport_error => "switched connections")
      if $self->{transport};

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
   my ($self) = @_;

   Scalar::Util::weaken $self;

   $self->{connect_to} ||= AE::timer
      $AnyEvent::MP::Config::CFG{monitor_timeout} || $AnyEvent::MP::Kernel::MONITOR_TIMEOUT,
      0,
      sub {
         $self->transport_error (transport_error => $self->{noderef}, "unable to connect");
      };

   unless ($self->{connect_w}) {
      my @endpoints;
      my %trial;

      $self->{connect_w} = AE::timer
         0,
         $AnyEvent::MP::Config::CFG{connect_interval} || $AnyEvent::MP::Kernel::CONNECT_INTERVAL,
         sub {
            @endpoints = split /,/, $self->{noderef}
               unless @endpoints;

            my $endpoint = shift @endpoints;

            $trial{$endpoint} ||= do {
               my ($host, $port) = AnyEvent::Socket::parse_hostport $endpoint
                  or return $AnyEvent::MP::Kernel::WARN->("$self->{noderef}: not a resolved node reference.");

               AnyEvent::MP::Transport::mp_connect
                  $host, $port,
                  sub { delete $trial{$endpoint} }
               ;
            };
         }
      ;
   }
}

sub kill {
   my ($self, $port, @reason) = @_;

   $self->send (["", kil => $port, @reason]);
}

sub monitor {
   my ($self, $portid, $cb) = @_;

   my $list = $self->{lmon}{$portid} ||= [];

   $self->send (["", mon1 => $portid])
      unless @$list;

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

package AnyEvent::MP::Node::Direct;

use base "AnyEvent::MP::Node::External";

package AnyEvent::MP::Node::Indirect;

use base "AnyEvent::MP::Node::Direct";

sub transport_reset {
   my ($self) = @_;

   # as an optimisation, immediately nuke slave nodes
   delete $AnyEvent::MP::Kernel::NODE{$self->{noderef}}
      if $self->{transport};

   $self->SUPER::transport_reset;
}

sub connect {
   my ($self) = @_;

   $self->transport_error (transport_error => $self->{noderef}, "unable to connect to indirect node");
}

package AnyEvent::MP::Node::Self;

use base "AnyEvent::MP::Node";

sub connect {
   # we are trivially connected
}

sub transport_reset {
   my ($self) = @_;

   Scalar::Util::weaken $self;

   $self->{send} = sub {
      local $AnyEvent::MP::Kernel::SRCNODE = $self;
      AnyEvent::MP::Kernel::_inject (@{ $_[0] });
   };
}

sub kill {
   my ($self, $port, @reason) = @_;

   delete $AnyEvent::MP::Kernel::PORT{$port};
   delete $AnyEvent::MP::Kernel::PORT_DATA{$port};

   my $mon = delete $AnyEvent::MP::Kernel::LMON{$port}
      or !@reason
      or $AnyEvent::MP::Kernel::WARN->("unmonitored local port $port died with reason: @reason");

   $_->(@reason) for values %$mon;
}

sub monitor {
   my ($self, $portid, $cb) = @_;

   return $cb->(no_such_port => "cannot monitor nonexistent port")
      unless exists $AnyEvent::MP::Kernel::PORT{$portid};

   $AnyEvent::MP::Kernel::LMON{$portid}{$cb+0} = $cb;
}

sub unmonitor {
   my ($self, $portid, $cb) = @_;

   delete $AnyEvent::MP::Kernel::LMON{$portid}{$cb+0};
}

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

