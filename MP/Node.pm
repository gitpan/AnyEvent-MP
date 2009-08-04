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

our $VERSION = '0.0';

our $DEFAULT_PORT = "4040";

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
         require POSIX;
         my $nodename = (POSIX::uname ())[1];

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

   return $cb->("node failed conenction")
      if $self->{failed};

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

   if (
      exists $self->{remote_uniq}
      && $self->{remote_uniq} ne $transport->{remote_uniq}
   ) {
      # uniq changed, different node
      $self->fail ("node restart detected");
   }

   delete $self->{trial};
   delete $self->{next_connect};
   delete $self->{failed};

   $self->{remote_uniq} = $transport->{remote_uniq};
   $self->{transport}   = $transport;

   $transport->send ($_)
      for @{ delete $self->{queue} || [] };
}

sub fail {
   my ($self, @reason) = @_;

   delete $self->{queue};

   $self->{failed} = 1;

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

   unless (exists $self->{n_noderef}) {
      return if $self->{n_noderef_}++;
      (AnyEvent::MP::Node::normalise_noderef ($self->{noderef}))->cb (sub {
         $self or return;
         delete $self->{n_noderef_};
         my $noderef = shift->recv;

         $self->{n_noderef} = $noderef;

         $AnyEvent::MP::Base::NODE{$_} = $self
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
      delete $self->{retry};
   }

   $self->{next_connect} = AE::timer $AnyEvent::MP::Base::CONNECT_INTERVAL, 0, sub {
      $self->connect;
   };
}

package AnyEvent::MP::Node::Self;

use base "AnyEvent::MP::Node";

sub set_transport {
   die "FATAL error, set_transport was called";
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

   return $cb->()
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

