=head1 NAME

AnyEvent::MP::Transport - actual transport protocol

=head1 SYNOPSIS

   use AnyEvent::MP::Transport;

=head1 DESCRIPTION

This is the superclass for MP transports, most of which is considered an
implementation detail.

Future versions might document the actual protocol.

=head1 FUNCTIONS/METHODS

=over 4

=cut

package AnyEvent::MP::Transport;

use common::sense;

use Scalar::Util;
use MIME::Base64 ();
use Storable ();
use JSON::XS ();

use AE ();
use AnyEvent::Socket ();
use AnyEvent::Handle ();

use AnyEvent::MP::Util ();

use base Exporter::;

our $VERSION = '0.0';
our $PROTOCOL_VERSION = 0;

=item $listener = mp_listener $host, $port, <constructor-args>, $cb->($transport)

Creates a listener on the given host/port using
C<AnyEvent::Socket::tcp_server>.

See C<new>, below, for constructor arguments.

Defaults for peerhost, peerport, fh and tls are provided.

=cut

sub mp_server($$@) {
   my $cb = pop;
   my ($host, $port, @args) = @_;

   AnyEvent::Socket::tcp_server $host, $port, sub {
      my ($fh, $host, $port) = @_;

      $cb->(new AnyEvent::MP::Transport
         fh       => $fh,
         peerhost => $host,
         peerport => $port,
         tls      => "accept",
         @args,
      );
   }
}

=item $guard = mp_connect $host, $port, <constructor-args>, $cb->($transport)

=cut

sub mp_connect {
   my $cb = pop;
   my ($host, $port, @args) = @_;

   AnyEvent::Socket::tcp_connect $host, $port, sub {
      my ($fh, $nhost, $nport) = @_;

      return $cb->() unless $fh;

      $cb->(new AnyEvent::MP::Transport
         fh       => $fh,
         peername => $host,
         peerhost => $nhost,
         peerport => $nport,
         tls      => "accept",
         @args,
      );
   }
}

=item new AnyEvent::MP::Transport

   # immediately starts negotiation
   my $transport = new AnyEvent::MP::Transport
      # mandatory
      fh       => $filehandle,
      local_id => $identifier,
      on_recv  => sub { receive-callback },
      on_error => sub { error-callback },

      # optional
      secret   => "shared secret",
      on_eof   => sub { clean-close-callback },
      on_connect => sub { successful-connect-callback },
      greeting => { key => value },

      # tls support
      tls      => "accept|connect",
      tls_ctx  => AnyEvent::TLS,
      peername => $peername, # for verification
   ;

=cut

sub new {
   my ($class, %arg) = @_;

   my $self = bless \%arg, $class;

   $self->{queue} = [];

   {
      Scalar::Util::weaken (my $self = $self);

      if (exists $arg{connect}) {
         $arg{tls}     ||= "connect";
         $arg{tls_ctx} ||= { sslv2 => 0, sslv3 => 0, tlsv1 => 1, verify => 1 };
      }

      $arg{secret} = AnyEvent::MP::default_secret ()
         unless exists $arg{secret};

      $self->{hdl} = new AnyEvent::Handle
         fh       => delete $arg{fh},
         rbuf_max => 64 * 1024,
         on_error => sub {
            $self->error ($_[2]);
         },
         peername => delete $arg{peername},
      ;

      my $secret = $arg{secret};
      my $greeting_kv = $self->{greeting} ||= {};
      $greeting_kv->{"tls1.0"} ||= $arg{tls}
         if exists $arg{tls} && $arg{tls_ctx};
      $greeting_kv->{provider} = "AE-$VERSION";

      # send greeting
      my $lgreeting = "aemp;$PROTOCOL_VERSION;$PROTOCOL_VERSION" # version, min
                    . ";$AnyEvent::MP::UNIQ"
                    . ";$AnyEvent::MP::NODE"
                    . ";" . (MIME::Base64::encode_base64 AnyEvent::MP::Util::nonce 33, "")
                    . ";hmac_md6_64_256" # hardcoded atm.
                    . ";json" # hardcoded atm.
                    . ";$self->{peerhost};$self->{peerport}"
                    . (join "", map ";$_=$greeting_kv->{$_}", keys %$greeting_kv);

      $self->{hdl}->push_write ("$lgreeting\012");

      # expect greeting
      $self->{hdl}->push_read (line => sub {
         my $rgreeting = $_[1];

         my ($aemp, $version, $version_min, $uniq, $rnode, undef, $auth, $framing, $peerport, $peerhost, @kv) = split /;/, $rgreeting;

         if ($aemp ne "aemp") {
            return $self->error ("unparsable greeting");
         } elsif ($version_min > $PROTOCOL_VERSION) {
            return $self->error ("version mismatch (we: $PROTOCOL_VERSION, they: $version_min .. $version)");
         } elsif ($auth ne "hmac_md6_64_256") {
            return $self->error ("unsupported auth method ($auth)");
         } elsif ($framing ne "json") {
            return $self->error ("unsupported framing method ($auth)");
         }

         $self->{remote_uniq} = $uniq;
         $self->{remote_node} = $rnode;

         $self->{remote_greeting} = {
            map /^([^=]+)(?:=(.*))?/ ? ($1 => $2) : (),
               @kv
         };

         if (exists $self->{tls} and $self->{tls_ctx} and exists $self->{remote_greeting}{"tls1.0"}) {
            if ($self->{tls} ne $self->{remote_greeting}{"tls1.0"}) {
               return $self->error ("TLS server/client mismatch");
            }
            $self->{hdl}->starttls ($self->{tls}, $self->{tls_ctx});
         }

         # auth
         require Digest::MD6;
         require Digest::HMAC_MD6;

         my $key   = Digest::MD6::md6_hex ($secret);
         my $lauth = Digest::HMAC_MD6::hmac_md6_base64 ($key, "$lgreeting\012$rgreeting", 64, 256);
         my $rauth = Digest::HMAC_MD6::hmac_md6_base64 ($key, "$rgreeting\012$lgreeting", 64, 256);

         $lauth ne $rauth # echo attack?
            or return $self->error ("authentication error");

         $self->{hdl}->push_write ("$auth;$lauth;$framing\012");

         $self->{hdl}->rbuf_max (64); # enough for 44 reply bytes or so
         $self->{hdl}->push_read (line => sub {
            my ($hdl, $rline) = @_;

            my ($auth_method, $rauth2, $r_framing) = split /;/, $rline;

            if ($rauth2 ne $rauth) {
               return $self->error ("authentication failure/shared secret mismatch");
            }

            $self->{s_framing} = "json";#d#

            $hdl->rbuf_max (undef);
            my $queue = delete $self->{queue}; # we are connected

            $self->connected;

            $hdl->push_write ($self->{s_framing} => $_)
               for @$queue;

            my $rmsg; $rmsg = sub  {
               $_[0]->push_read ($r_framing => $rmsg);

               AnyEvent::MP::_inject ($_[1]);
            };
            $hdl->push_read ($r_framing => $rmsg);
         });
      });
   }

   $self
}

sub error {
   my ($self, $msg) = @_;

   $self->{on_error}($self, $msg);
   $self->{hdl}->destroy;
}

sub connected {
   my ($self) = @_;

   (AnyEvent::MP::add_node ($self->{remote_node}))
      ->set_transport ($self);
}

sub send {
   $_[0]{hdl}->push_write ($_[0]{s_framing} => $_[1]);
}

sub destroy {
   my ($self) = @_;

   $self->{hdl}->destroy
      if $self->{hdl};
}

sub DESTROY {
   my ($self) = @_;

   $self->destroy;
}

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

