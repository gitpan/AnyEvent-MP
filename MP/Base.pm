=head1 NAME

AnyEvent::MP::Base - basis for AnyEvent::MP and Coro::MP

=head1 SYNOPSIS

   # use AnyEvent::MP or Coro::MP instead

=cut

package AnyEvent::MP::Base;

use AnyEvent::MP::Node;
use AnyEvent::MP::Transport;

use common::sense;

use Carp ();

use AE ();

use base "Exporter";

our $VERSION = '0.01';
our @EXPORT = qw(NODE $NODE snd _any_ become_slave become_public);

our $DEFAULT_SECRET;

our $CONNECT_INTERVAL =  5; # new connect every 5s, at least
our $CONNECT_TIMEOUT  = 30; # includes handshake

sub nonce($) {
   my $nonce;

   if (open my $fh, "</dev/urandom") {
      sysread $fh, $nonce, $_[0];
   } else {
      # shit...
      our $nonce_init;
      unless ($nonce_init++) {
         srand time ^ $$ ^ unpack "%L*", qx"ps -edalf" . qx"ipconfig /all";
      }

      $nonce = join "", map +(chr rand 256), 1 .. $_[0]
   }

   $nonce
}

sub default_secret {
   unless (defined $DEFAULT_SECRET) {
      if (open my $fh, "<$ENV{HOME}/.aemp-secret") {
         sysread $fh, $DEFAULT_SECRET, -s $fh;
      } else {
         $DEFAULT_SECRET = nonce 32;
      }
   }

   $DEFAULT_SECRET
}

our $UNIQ = sprintf "%x.%x", $$, time; # per-process/node unique cookie
our $ID   = "a";
our $PUBLIC = 0;
our $NODE = $$;
our $PORT;

our %NODE; # node id to transport mapping, or "undef", for local node
our %PORT; # local ports
our %WKP;
our %LISTENER; # local transports

sub NODE() { $NODE }

sub _ANY_() { 1 }
sub _any_() { \&_ANY_ }

sub _inject {
   ($PORT{$_[0][0]} or return)->(@{$_[0][1]});
}

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

sub snd(@) {
   my ($noderef, $port) = split /#/, shift, 2;

   add_node $noderef
      unless exists $NODE{$noderef};

   $NODE{$noderef}->send (["$port", [@_]]);
}

sub become_public {
   return if $PUBLIC;

   my $noderef = join ",", @_;
   my @args = @_;

   $NODE = (AnyEvent::MP::Node::normalise_noderef $noderef)->recv;

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

#############################################################################
# self node code

$NODE{""} = new AnyEvent::MP::Node::Self noderef => $NODE;
$PORT{""} = sub {
   given (shift) {
      when ("wkp") {
         my $wkname = shift;
         snd @_, $WKP{$wkname};
      }
      when ("relay") {
         &snd;
      }
      when ("eval") {
         my @res = eval shift;
         snd @_, "$@", @res if @_;
      }
      when ("time") {
         snd @_, AE::time;
      }
      when ("devnull") {
         #
      }
   }
};

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

