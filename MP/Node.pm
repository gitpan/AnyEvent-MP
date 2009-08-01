=head1 NAME

AnyEvent::MP::Node - a single processing node (CPU/process...)

=head1 SYNOPSIS

   use AnyEvent::MP::Node;

=head1 DESCRIPTION

=cut

package AnyEvent::MP::Node;

use common::sense;

use AE ();
use AnyEvent::Socket ();

use AnyEvent::MP::Transport ();

use base Exporter::;

our $VERSION = '0.0';

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

sub set_transport {
   my ($self, $transport) = @_;

   delete $self->{trial};
   delete $self->{next_connect};

   if (
      exists $self->{remote_uniq}
      && $self->{remote_uniq} ne $transport->{remote_uniq}
   ) {
      # uniq changed, drop queue
      delete $self->{queue};
      #TODO: "DOWN"
   }

   $self->{remote_uniq} = $transport->{remote_uniq};
   $self->{transport}   = $transport;

   $transport->send ($_)
      for @{ delete $self->{queue} || [] };
}

sub clr_transport {
   my ($self) = @_;

   delete $self->{transport};
   warn "clr_transport\n";
}

sub connect {
   my ($self) = @_;

   Scalar::Util::weaken $self;

   unless (exists $self->{n_noderef}) {
      (AnyEvent::MP::normalise_noderef ($self->{noderef}))->cb (sub {
         $self or return;
         my $noderef = shift->recv;

         $self->{n_noderef} = $noderef;

         $AnyEvent::MP::NODE{$_} = $self
            for split /,/, $noderef;

         $self->connect;
      });
      return;
   }

   $self->{retry} ||= [split /,/, $self->{n_noderef}];

   my $endpoint = shift @{ $self->{retry} };

   if (defined $endpoint) {
      $self->{trial}{$endpoint} ||= do {
         my ($host, $port) = AnyEvent::Socket::parse_hostport $endpoint
            or return;

         my ($w, $g);

         $w = AE::timer $AnyEvent::MP::CONNECT_TIMEOUT, 0, sub {
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
      delete $self->{retry};
   }

   $self->{next_connect} = AE::timer $AnyEvent::MP::CONNECT_INTERVAL, 0, sub {
      $self->connect;
   };
}

package AnyEvent::MP::Node::Self;

use base "AnyEvent::MP::Node";

sub set_transport {
   die "FATAL error, set_transport was called";
}

sub send {
   AnyEvent::MP::_inject ($_[1]);
}

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

