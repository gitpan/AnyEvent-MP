=head1 NAME

AnyEvent::MP::Base - basis for AnyEvent::MP and Coro::MP

=head1 SYNOPSIS

   # use AnyEvent::MP or Coro::MP instead

=head1 DESCRIPTION

This module provides most of the basic functionality of AnyEvent::MP,
exposed through higher level interfaces such as L<AnyEvent::MP> and
L<Coro::MP>.

=head1 GLOBALS

=over 4

=cut

package AnyEvent::MP::Base;

use common::sense;
use Carp ();
use MIME::Base64 ();

use AE ();

use AnyEvent::MP::Node;
use AnyEvent::MP::Transport;

use base "Exporter";

our $VERSION = '0.01';
our @EXPORT = qw(
   %NODE %PORT %PORT_DATA %REG $UNIQ $ID add_node

   NODE $NODE node_of snd kil _any_
   become_slave become_public
);

our $DEFAULT_SECRET;

our $CONNECT_INTERVAL =  5; # new connect every 5s, at least
our $CONNECT_TIMEOUT  = 30; # includes handshake

=item $AnyEvent::MP::Base::WARN

This value is called with an error or warning message, when e.g. a connection
could not be created, authorisation failed and so on.

The default simply logs the message to STDERR.

=cut

our $WARN = sub {
   my $msg = $_[0];
   $msg =~ s/\n$//;
   warn "$msg\n";
};

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

sub gen_uniq {
   my $uniq = pack "wN", $$, time;
   $uniq = MIME::Base64::encode_base64 $uniq, "";
   $uniq =~ s/=+$//;
   $uniq
}

our $UNIQ = gen_uniq; # per-process/node unique cookie
our $ID   = "a";
our $PUBLIC = 0;
our $NODE = unpack "H*", nonce 16;

our %NODE; # node id to transport mapping, or "undef", for local node
our (%PORT, %PORT_DATA); # local ports

our %RMON; # local ports monitored by remote nodes ($RMON{noderef}{portid} == cb)
our %LMON; # monitored _local_ ports

our %REG;  # registered port names

our %LISTENER;

our $SRCNODE; # holds the sending node during _inject

sub NODE() {
   $NODE
}

sub node_of($) {
   my ($noderef, undef) = split /#/, $_[0], 2;

   $noderef
}

sub _ANY_() { 1 }
sub _any_() { \&_ANY_ }

sub _inject {
   &{ $PORT{+shift} or return };
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

   ($NODE{$noderef} || add_node $noderef)
      ->send ([$port, @_]);
}

sub kil(@) {
   my ($noderef, $port) = split /#/, shift, 2;

   ($NODE{$noderef} || add_node $noderef)
      ->kill ($port, @_);
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
         sub {
            my ($tp) = @_;

            # TODO: urgs
            my $node = add_node $tp->{remote_node};
            $node->{trial}{accept} = $tp;
         },
      ;
   }

   $PUBLIC = 1;
}

#############################################################################
# self node code

our %node_req = (
   # monitoring
   mon0 => sub { # disable monitoring
      my $portid = shift;
      my $node   = $SRCNODE;
      $NODE{""}->unmonitor ($portid, delete $node->{rmon}{$portid});
   },
   mon1 => sub { # enable monitoring
      my $portid = shift;
      my $node   = $SRCNODE;
      $NODE{""}->monitor ($portid, $node->{rmon}{$portid} = sub {
         $node->send (["", kil => $portid, @_]);
      });
   },
   kil => sub {
      my $cbs = delete $SRCNODE->{lmon}{+shift}
         or return;

      $_->(@_) for @$cbs;
   },

   # well-known-port lookup
   lookup => sub {
      my $name = shift;
      my $port = $REG{$name};
      #TODO: check vailidity
      snd @_, $port;
   },

   # relay message to another node / generic echo
   relay => sub {
      &snd;
   },

   # random garbage
   eval => sub {
      my @res = eval shift;
      snd @_, "$@", @res if @_;
   },
   time => sub {
      snd @_, AE::time;
   },
   devnull => sub {
      #
   },
);

$NODE{""} = $NODE{$NODE} = new AnyEvent::MP::Node::Self noderef => $NODE;
$PORT{""} = sub { &{ $node_req{+shift} or return } };

=back

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

