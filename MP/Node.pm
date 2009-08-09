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

use base Exporter::;

sub new {
   my ($class, $noderef) = @_;

   bless { noderef => $noderef }, $class
}

package AnyEvent::MP::Node::Direct;

use base "AnyEvent::MP::Node";

sub send {
   my ($self, $msg) = @_;

   if ($self->{transport}) {
      $self->{transport}->send ($msg);
   } elsif ($self->{queue}) {
      push @{ $self->{queue} }, $msg;
   } else {
      $self->{queue} = [$msg];
      $self->connect;
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

sub set_transport {
   my ($self, $transport) = @_;

   $self->clr_transport
      if $self->{transport};

   delete $self->{trial};
   delete $self->{retry};
   delete $self->{next_connect};

   $self->{transport} = $transport;

   $transport->send ($_)
      for @{ delete $self->{queue} || [] };
}

sub fail {
   my ($self, @reason) = @_;

   delete $self->{queue};

   if (my $mon = delete $self->{lmon}) {
      $_->(@reason) for map @$_, values %$mon;
   }
}

sub clr_transport {
   my ($self, @reason) = @_;

   delete $self->{transport};
   $self->connect;
}

sub connect {
   my ($self) = @_;

   Scalar::Util::weaken $self;

   $self->{retry} ||= [split /,/, $self->{noderef}];

   my $endpoint = shift @{ $self->{retry} };

   if (defined $endpoint) {
      $self->{trial}{$endpoint} ||= do {
         my ($host, $port) = AnyEvent::Socket::parse_hostport $endpoint
            or return $AnyEvent::MP::Base::WARN->("$self->{noderef}: not a resolved node reference.");

         my ($w, $g);

         $w = AE::timer $AnyEvent::MP::Base::CONNECT_TIMEOUT, 0, sub {
            delete $self->{trial}{$endpoint};
         };
         $g = AnyEvent::MP::Transport::mp_connect
            $host, $port,
            sub {
               delete $self->{trial}{$endpoint}
                  unless @_;
               $g = shift;
            };
         ;

         [$w, \$g]
      };
   } else {
      $self->fail (transport_error => $self->{noderef}, "unable to connect");
   }

   $self->{next_connect} = AE::timer $AnyEvent::MP::Base::CONNECT_INTERVAL, 0, sub {
      delete $self->{retry};
      $self->connect;
   };
}

package AnyEvent::MP::Node::Slave;

use base "AnyEvent::MP::Node::Direct";

sub connect {
   my ($self) = @_;

   $self->fail (transport_error => $self->{noderef}, "unable to connect to slave node");
}

package AnyEvent::MP::Node::Self;

use base "AnyEvent::MP::Node";

sub set_transport {
   Carp::confess "FATAL error, set_transport was called on local node";
}

sub send {
   local $AnyEvent::MP::Base::SRCNODE = $_[0];
   AnyEvent::MP::Base::_inject (@{ $_[1] });
}

sub kill {
   my ($self, $port, @reason) = @_;

   delete $AnyEvent::MP::Base::PORT{$port};
   delete $AnyEvent::MP::Base::PORT_DATA{$port};

   my $mon = delete $AnyEvent::MP::Base::LMON{$port}
      or !@reason
      or $AnyEvent::MP::Base::WARN->("unmonitored local port $port died with reason: @reason");

   $_->(@reason) for values %$mon;
}

sub monitor {
   my ($self, $portid, $cb) = @_;

   return $cb->(no_such_port => "cannot monitor nonexistent port")
      unless exists $AnyEvent::MP::Base::PORT{$portid};

   $AnyEvent::MP::Base::LMON{$portid}{$cb+0} = $cb;
}

sub unmonitor {
   my ($self, $portid, $cb) = @_;

   delete $AnyEvent::MP::Base::LMON{$portid}{$cb+0};
}

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

