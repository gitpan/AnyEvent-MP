=head1 NAME

AnyEvent::MP::Transport - actual transport protocol handler

=head1 SYNOPSIS

   use AnyEvent::MP::Transport;

=head1 DESCRIPTION

This implements the actual transport protocol for MP (it represents a
single link), most of which is considered an implementation detail.

See the "PROTOCOL" section below if you want to write another client for
this protocol.

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

use base Exporter::;

our $VERSION = '0.0';
our $PROTOCOL_VERSION = 0;

=item $listener = mp_listener $host, $port, <constructor-args>, $cb->($transport)

Creates a listener on the given host/port using
C<AnyEvent::Socket::tcp_server>.

See C<new>, below, for constructor arguments.

Defaults for peerhost, peerport and fh are provided.

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
      tls_ctx  => AnyEvent::TLS,
      peername => $peername, # for verification
   ;

=cut

our @FRAMINGS = qw(json storable); # the framing types we accept and send, in order of preference
our @AUTH_SND = qw(hmac_md6_64_256); # auth types we send
our @AUTH_RCV = (@AUTH_SND, qw(cleartext)); # auth types we accept

#AnyEvent::Handle::register_write_type mp_record => sub {
#};

sub new {
   my ($class, %arg) = @_;

   my $self = bless \%arg, $class;

   $self->{queue} = [];

   {
      Scalar::Util::weaken (my $self = $self);

      $arg{tls_ctx_disabled} ||= {
         sslv2  => 0,
         sslv3  => 0,
         tlsv1  => 1,
         verify => 1,
         cert_file => "secret.pem",
         ca_file   => "secret.pem",
         verify_require_client_cert => 1,
      };

      $arg{secret} = AnyEvent::MP::Base::default_secret ()
         unless exists $arg{secret};

      $self->{hdl} = new AnyEvent::Handle
         fh       => delete $arg{fh},
         autocork => 1,
         no_delay => 1,
         on_error => sub {
            $self->error ($_[2]);
         },
         peername => delete $arg{peername},
      ;

      my $secret = $arg{secret};
      my $greeting_kv = $self->{greeting} ||= {};
      $greeting_kv->{"tls"} = "1.0"
         if $arg{tls_ctx};
      $greeting_kv->{provider} = "AE-$VERSION";
      $greeting_kv->{peeraddr} = AnyEvent::Socket::format_hostport $self->{peerhost}, $self->{peerport};

      # send greeting
      my $lgreeting1 = "aemp;$PROTOCOL_VERSION"
                     . ";$AnyEvent::MP::Base::UNIQ"
                     . ";$AnyEvent::MP::Base::NODE"
                     . ";" . (join ",", @AUTH_RCV)
                     . ";" . (join ",", @FRAMINGS)
                     . (join "", map ";$_=$greeting_kv->{$_}", keys %$greeting_kv);

      my $lgreeting2 = MIME::Base64::encode_base64 AnyEvent::MP::Base::nonce (33), "";

      $self->{hdl}->push_write ("$lgreeting1\012$lgreeting2\012");

      # expect greeting
      $self->{hdl}->rbuf_max (4 * 1024);
      $self->{hdl}->push_read (line => sub {
         my $rgreeting1 = $_[1];

         my ($aemp, $version, $uniq, $rnode, $auths, $framings, @kv) = split /;/, $rgreeting1;

         if ($aemp ne "aemp") {
            return $self->error ("unparsable greeting");
         } elsif ($version != $PROTOCOL_VERSION) {
            return $self->error ("version mismatch (we: $PROTOCOL_VERSION, they: $version)");
         }

         my $s_auth;
         for my $auth_ (split /,/, $auths) {
            if (grep $auth_ eq $_, @AUTH_SND) {
               $s_auth = $auth_;
               last;
            }
         }

         defined $s_auth
            or return $self->error ("$auths: no common auth type supported");

         die unless $s_auth eq "hmac_md6_64_256"; # hardcoded atm.

         my $s_framing;
         for my $framing_ (split /,/, $framings) {
            if (grep $framing_ eq $_, @FRAMINGS) {
               $s_framing = $framing_;
               last;
            }
         }

         defined $s_framing
            or return $self->error ("$framings: no common framing method supported");

         $self->{remote_uniq} = $uniq;
         $self->{remote_node} = $rnode;

         $self->{remote_greeting} = {
            map /^([^=]+)(?:=(.*))?/ ? ($1 => $2) : (),
               @kv
         };

         # read nonce
         $self->{hdl}->push_read (line => sub {
            my $rgreeting2 = $_[1];

            if ($self->{tls_ctx} and 1 == int $self->{remote_greeting}{tls}) {
               $self->{tls} = $lgreeting2 lt $rgreeting2 ? "connect" : "accept";
               $self->{hdl}->starttls ($self->{tls}, $self->{tls_ctx});
            }
         
            # auth
            require Digest::MD6;
            require Digest::HMAC_MD6;

            my $key   = Digest::MD6::md6 ($secret);
            my $lauth = Digest::HMAC_MD6::hmac_md6_hex ($key, "$lgreeting1\012$lgreeting2\012$rgreeting1\012$rgreeting2\012", 64, 256);

            my $rauth =
               $s_auth eq "hmac_md6_64_256" ? Digest::HMAC_MD6::hmac_md6_hex ($key, "$rgreeting1\012$rgreeting2\012$lgreeting1\012$lgreeting2\012", 64, 256)
             : $s_auth eq "cleartext"       ? unpack "H*", $secret
             : die;

            $lauth ne $rauth # echo attack?
               or return $self->error ("authentication error");

            $self->{hdl}->push_write ("$s_auth;$lauth;$s_framing\012");

            # reasd the authentication response
            $self->{hdl}->push_read (line => sub {
               my ($hdl, $rline) = @_;

               my ($auth_method, $rauth2, $r_framing) = split /;/, $rline;

               if ($rauth2 ne $rauth) {
                  return $self->error ("authentication failure/shared secret mismatch");
               }

               $self->{s_framing} = $s_framing;

               $hdl->rbuf_max (undef);
               my $queue = delete $self->{queue}; # we are connected

               $self->connected;

               my $src_node = $self->{node};

               $hdl->push_write ($self->{s_framing} => $_)
                  for @$queue;

               my $rmsg; $rmsg = sub  {
                  $_[0]->push_read ($r_framing => $rmsg);

                  local $AnyEvent::MP::Base::SRCNODE = $src_node;
                  AnyEvent::MP::Base::_inject (@{ $_[1] });
               };
               $hdl->push_read ($r_framing => $rmsg);
            });
         });
      });
   }

   $self
}

sub error {
   my ($self, $msg) = @_;

   if ($self->{node} && $self->{node}{transport} == $self) {
      $self->{node}->fail (transport_error => $msg);
      $self->{node}->clr_transport;
   }
   $AnyEvent::MP::Base::WARN->("$self->{peerhost}:$self->{peerport}: $msg");
   $self->destroy;
}

sub connected {
   my ($self) = @_;

   my $node = AnyEvent::MP::Base::add_node ($self->{remote_node});
   Scalar::Util::weaken ($self->{node} = $node);
   $node->set_transport ($self);
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

=head1 PROTOCOL

The protocol is relatively simple, and consists of three phases which are
symmetrical for both sides: greeting (followed by optionally switching to
TLS mode), authentication and packet exchange.

the protocol is designed to allow both full-text and binary streams.

The greeting consists of two text lines that are ended by either an ASCII
CR LF pair, or a single ASCII LF (recommended).

=head2 GREETING

All the lines until after authentication must not exceed 4kb in length,
including delimiter. Afterwards there is no limit on the packet size that
can be received.

=head3 First Greeting Line

Example:

   aemp;0;fec.4a7720fc;127.0.0.1:1235,[::1]:1235;hmac_md6_64_256;json,storable;provider=AE-0.0

The first line contains strings separated (not ended) by C<;>
characters. The first even ixtrings are fixed by the protocol, the
remaining strings are C<KEY=VALUE> pairs. None of them may contain C<;>
characters themselves.

The fixed strings are:

=over 4

=item protocol identification

The constant C<aemp> to identify the protocol.

=item protocol version

The protocol version supported by this end, currently C<0>. If the
versions don't match then no communication is possible. Minor extensions
are supposed to be handled through additional key-value pairs.

=item a token uniquely identifying the current node instance

This is a string that must change between restarts. It usually contains
things like the current time, the (OS) process id or similar values, but
no meaning of the contents are assumed.

=item the node endpoint descriptors

for public nodes, this is a comma-separated list of protocol endpoints,
i.e., the noderef. For slave nodes, this is a unique identifier.

=item the acceptable authentication methods

A comma-separated list of authentication methods supported by the
node. Note that AnyEvent::MP supports a C<hex_secret> authentication
method that accepts a cleartext password (hex-encoded), but will not use
this auth method itself.

The receiving side should choose the first auth method it supports.

=item the acceptable framing formats

A comma-separated list of packet encoding/framign formats understood. The
receiving side should choose the first framing format it supports for
sending packets (which might be different from the format it has to accept).

=back

The remaining arguments are C<KEY=VALUE> pairs. The following key-value
pairs are known at this time:

=over 4

=item provider=<module-version>

The software provider for this implementation. For AnyEvent::MP, this is
C<AE-0.0> or whatever version it currently is at.

=item peeraddr=<host>:<port>

The peer address (socket address of the other side) as seen locally, in the same format
as noderef endpoints.

=item tls=<major>.<minor>

Indicates that the other side supports TLS (version should be 1.0) and
wishes to do a TLS handshake.

=back

=head3 Second Greeting Line

After this greeting line there will be a second line containing a
cryptographic nonce, i.e. random data of high quality. To keep the
protocol text-only, these are usually 32 base64-encoded octets, but
it could be anything that doesn't contain any ASCII CR or ASCII LF
characters.

I<< The two nonces B<must> be different, and an aemp implementation
B<must> check and fail when they are identical >>.

Example of a nonce line:

   p/I122ql7kJR8lumW3lXlXCeBnyDAvz8NQo3x5IFowE4

=head2 TLS handshake

I<< If, after the handshake, both sides indicate interest in TLS, then the
connection B<must> use TLS, or fail.>>

Both sides compare their nonces, and the side who sent the lower nonce
value ("string" comparison on the raw octet values) becomes the client,
and the one with the higher nonce the server.

=head2 AUTHENTICATION PHASE

After the greeting is received (and the optional TLS handshake),
the authentication phase begins, which consists of sending a single
C<;>-separated line with three fixed strings and any number of
C<KEY=VALUE> pairs.

The three fixed strings are:

=over 4

=item the authentication method chosen

This must be one of the methods offered by the other side in the greeting.

The currently supported authentication methods are:

=over 4

=item cleartext

This is simply the shared secret, lowercase-hex-encoded. This method is of
course very insecure, unless TLS is used, which is why this module will
accept, but not generate, cleartext auth replies.

=item hmac_md6_64_256

This method uses an MD6 HMAC with 64 bit blocksize and 256 bit hash. First, the shared secret
is hashed with MD6:

   key = MD6 (secret)

This secret is then used to generate the "local auth reply", by taking
the two local greeting lines and the two remote greeting lines (without
line endings), appending \012 to all of them, concatenating them and
calculating the MD6 HMAC with the key.

   lauth = HMAC_MD6 key, "lgreeting1\012lgreeting2\012rgreeting1\012rgreeting2\012"

This authentication token is then lowercase-hex-encoded and sent to the
other side.

Then the remote auth reply is generated using the same method, but local
and remote greeting lines swapped:

   rauth = HMAC_MD6 key, "rgreeting1\012rgreeting2\012lgreeting1\012lgreeting2\012"

This is the token that is expected from the other side.

=back

=item the authentication data

The authentication data itself, usually base64 or hex-encoded data, see
above.

=item the framing protocol chosen

This must be one of the framing protocols offered by the other side in the
greeting. Each side must accept the choice of the other side.

=back

Example of an authentication reply:

   hmac_md6_64_256;363d5175df38bd9eaddd3f6ca18aa1c0c4aa22f0da245ac638d048398c26b8d3;json

=head2 DATA PHASE

After this, packets get exchanged using the chosen framing protocol. It is
quite possible that both sides use a different framing protocol.

=head2 FULL EXAMPLE

This is an actual protocol dump of a handshake, followed by a single data
packet. The greater than/less than lines indicate the direction of the
transfer only.

   > aemp;0;nndKd+gn;10.0.0.1:4040;hmac_md6_64_256,cleartext;json,storable;provider=AE-0.0;peeraddr=127.0.0.1:1235
   > sRG8bbc4TDbkpvH8FTP4HBs87OhepH6VuApoZqXXskuG
   < aemp;0;nmpKd+gh;127.0.0.1:1235,[::1]:1235;hmac_md6_64_256,cleartext;json,storable;provider=AE-0.0;peeraddr=127.0.0.1:58760
   < dCEUcL/LJVSTJcx8byEsOzrwhzJYOq+L3YcopA5T6EAo
   > hmac_md6_64_256;9513d4b258975accfcb2ab7532b83690e9c119a502c612203332a591c7237788;json
   < hmac_md6_64_256;0298d6ba2240faabb2b2e881cf86b97d70a113ca74a87dc006f9f1e9d3010f90;json
   > ["","lookup","pinger","10.0.0.1:4040#nndKd+gn.a","resolved"]

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

