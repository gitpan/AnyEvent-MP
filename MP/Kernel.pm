=head1 NAME

AnyEvent::MP::Kernel - the actual message passing kernel

=head1 SYNOPSIS

   use AnyEvent::MP::Kernel;

=head1 DESCRIPTION

This module provides most of the basic functionality of AnyEvent::MP,
exposed through higher level interfaces such as L<AnyEvent::MP> and
L<Coro::MP>.

This module is mainly of interest when knowledge about connectivity,
connected nodes etc. are needed.

=head1 GLOBALS AND FUNCTIONS

=over 4

=cut

package AnyEvent::MP::Kernel;

use common::sense;
use Carp ();
use MIME::Base64 ();

use AE ();

use AnyEvent::MP::Node;
use AnyEvent::MP::Transport;

use base "Exporter";

our $VERSION = '0.6';
our @EXPORT = qw(
   %NODE %PORT %PORT_DATA %REG $UNIQ $RUNIQ $ID add_node load_func

   NODE $NODE node_of snd kil _any_
   resolve_node initialise_node
);

our $DEFAULT_PORT = "4040";

our $CONNECT_INTERVAL =  2; # new connect every 2s, at least
our $NETWORK_LATENCY  =  3; # activity timeout
our $MONITOR_TIMEOUT  = 15; # fail monitoring after this time

=item $AnyEvent::MP::Kernel::WARN

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

sub asciibits($) {
   my $data = $_[0];

   if (eval "use Math::GMP 2.05; 1") {
      $data = Math::GMP::get_str_gmp (
                  (Math::GMP::new_from_scalar_with_base (+(unpack "H*", $data), 16)),
                  62
              );
   } else {
      $data = MIME::Base64::encode_base64 $data, "";
      $data =~ s/=//;
      $data =~ s/\//s/g;
      $data =~ s/\+/p/g;
   }

   $data
}

sub gen_uniq {
   asciibits pack "wNa*", $$, time, nonce 2
}

=item $AnyEvent::MP::Kernel::PUBLIC

A boolean indicating whether this is a full/public node, which can create
and accept direct connections form othe rnodes.

=item $AnyEvent::MP::Kernel::SLAVE

A boolean indicating whether this node is a slave node, i.e. does most of it's
message sending/receiving through some master node.

=item $AnyEvent::MP::Kernel::MASTER

Defined only in slave mode, in which cas eit contains the noderef of the
master node.

=cut

our $PUBLIC = 0;
our $SLAVE  = 0;
our $MASTER; # master noderef when $SLAVE

our $NODE   = asciibits nonce 16;
our $RUNIQ  = $NODE; # remote uniq value
our $UNIQ   = gen_uniq; # per-process/node unique cookie
our $ID     = "a";

our %NODE; # node id to transport mapping, or "undef", for local node
our (%PORT, %PORT_DATA); # local ports

our %RMON; # local ports monitored by remote nodes ($RMON{noderef}{portid} == cb)
our %LMON; # monitored _local_ ports

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

sub TRACE() { 0 }

sub _inject {
   warn "RCV $SRCNODE->{noderef} -> @_\n" if TRACE;#d#
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

   # new node, check validity
   my $node;

   if ($noderef =~ /^slave\/.+$/) {
      $node = new AnyEvent::MP::Node::Indirect $noderef;

   } else {
      for (split /,/, $noderef) {
         my ($host, $port) = AnyEvent::Socket::parse_hostport $_
            or Carp::croak "$noderef: not a resolved node reference ('$_' not parsable)";

         $port > 0
            or Carp::croak "$noderef: not a resolved node reference ('$_' contains non-numeric port)";

         AnyEvent::Socket::parse_address $host
            or Carp::croak "$noderef: not a resolved node reference ('$_' contains unresolved address)";
      }

      # TODO: for indirect sends, use a different class
      $node = new AnyEvent::MP::Node::Direct $noderef;
   }

   $NODE{$_} = $node
      for $noderef, split /,/, $noderef;

   $node
}

sub snd(@) {
   my ($noderef, $portid) = split /#/, shift, 2;

   warn "SND $noderef <- $portid @_\n" if TRACE;#d#

   ($NODE{$noderef} || add_node $noderef)
      ->{send} (["$portid", @_]);
}

sub kil(@) {
   my ($noderef, $portid) = split /#/, shift, 2;

   length $portid
      or Carp::croak "$noderef#$portid: killing a node port is not allowed, caught";

   ($NODE{$noderef} || add_node $noderef)
      ->kill ("$portid", @_);
}

sub resolve_node($) {
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

sub initialise_node(@) {
   my ($noderef, @others) = @_;

   @others = @{ $AnyEvent::MP::Config::CFG{seeds} }
      unless @others;

   if ($noderef =~ /^slave\/(.*)$/) {
      $SLAVE = AE::cv;
      my $name = $1;
      $name = $NODE unless length $name;
      $noderef = AE::cv;
      $noderef->send ("slave/$name");

      @others
         or Carp::croak "seed nodes must be specified for slave nodes";

   } else {
      $PUBLIC = 1;
      $noderef = resolve_node $noderef;
   }

   @others = map $_->recv, map +(resolve_node $_), @others;

   $NODE = $noderef->recv;

   for my $t (split /,/, $NODE) {
      $NODE{$t} = $NODE{""};

      my ($host, $port) = AnyEvent::Socket::parse_hostport $t;

      $LISTENER{$t} = AnyEvent::MP::Transport::mp_server $host, $port,
         sub {
            my ($tp) = @_;

            # TODO: urgs
            my $node = add_node $tp->{remote_node};
            $node->{trial}{accept} = $tp;
         },
      ;
   }

   (add_node $_)->connect for @others;

   if ($SLAVE) {
      my $timeout = AE::timer $MONITOR_TIMEOUT, 0, sub { $SLAVE->() };
      $MASTER = $SLAVE->recv;
      defined $MASTER
         or Carp::croak "AnyEvent::MP: unable to enter slave mode, unable to connect to a seednode.\n";

      (my $via = $MASTER) =~ s/,/!/g; 

      $NODE .= "\@$via";
      $NODE{$NODE} = $NODE{""};

      $_->send (["", iam => $NODE])
         for values %NODE;

      $SLAVE = 1;
   }
}

#############################################################################
# node moniotirng and info

sub _uniq_nodes {
   my %node;

   @node{values %NODE} = values %NODE;

   values %node;
}

=item known_nodes

Returns the noderefs of all nodes connected to this node.

=cut

sub known_nodes {
   map $_->{noderef}, _uniq_nodes
}

=item up_nodes

Return the noderefs of all nodes that are currently connected (excluding
the node itself).

=cut

sub up_nodes {
   map $_->{noderef}, grep $_->{transport}, _uniq_nodes
}

=item $guard = mon_nodes $callback->($noderef, $is_up, @reason)

Registers a callback that is called each time a node goes up (connection
is established) or down (connection is lost).

Node up messages can only be followed by node down messages for the same
node, and vice versa.

The fucntino returns an optional guard which can be used to de-register
the monitoring callback again.

=cut

our %MON_NODES;

sub mon_nodes($) {
   my ($cb) = @_;

   $MON_NODES{$cb+0} = $cb;

   wantarray && AnyEvent::Util::guard { delete $MON_NODES{$cb+0} }
}

sub _inject_nodeevent($$;@) {
   my ($node, @args) = @_;

   unshift @args, $node->{noderef};

   for my $cb (values %MON_NODES) {
      eval { $cb->(@args); 1 }
         or $WARN->($@);
   }
}

#############################################################################
# self node code

sub load_func($) {
   my $func = $_[0];

   unless (defined &$func) {
      my $pkg = $func;
      do {
         $pkg =~ s/::[^:]+$//
            or return sub { die "unable to resolve '$func'" };
         eval "require $pkg";
      } until defined &$func;
   }

   \&$func
}

our %node_req = (
   # internal services

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
   # node changed its name (for slave nodes)
   iam => sub {
      $SRCNODE->{noderef} = $_[0];
      $NODE{$_[0]} = $SRCNODE;
   },

   # public services

   # relay message to another node / generic echo
   relay => sub {
      &snd;
   },
   relay_multiple => sub {
      snd @$_ for @_
   },

   # informational
   info => sub {
      snd @_, $NODE;
   },
   known_nodes => sub {
      snd @_, known_nodes;
   },
   up_nodes => sub {
      snd @_, up_nodes;
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
$PORT{""} = sub {
   my $tag = shift;
   eval { &{ $node_req{$tag} ||= load_func $tag } };
   $WARN->("error processing node message: $@") if $@;
};

=back

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

