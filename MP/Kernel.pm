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
use POSIX ();
use Carp ();
use MIME::Base64 ();

use AE ();

use AnyEvent::MP::Node;
use AnyEvent::MP::Transport;

use base "Exporter";

our $VERSION = '0.8';
our @EXPORT = qw(
   %NODE %PORT %PORT_DATA $UNIQ $RUNIQ $ID
   connect_node add_node load_func snd_to_func snd_on eval_on

   NODE $NODE node_of snd kil
   port_is_local
   resolve_node initialise_node
   known_nodes up_nodes mon_nodes node_is_known node_is_up
);

our $DEFAULT_PORT = "4040";

our $CONNECT_INTERVAL =  2; # new connect every 2s, at least
our $NETWORK_LATENCY  =  3; # activity timeout
our $MONITOR_TIMEOUT  = 15; # fail monitoring after this time

=item $AnyEvent::MP::Kernel::WARN->($level, $msg)

This value is called with an error or warning message, when e.g. a connection
could not be created, authorisation failed and so on.

C<$level> sould be C<0> for messages ot be logged always, C<1> for
unexpected messages and errors, C<2> for warnings, C<7> for messages about
node connectivity and services, C<8> for debugging messages and C<9> for
tracing messages.

The default simply logs the message to STDERR.

=cut

our $WARN = sub {
   my ($level, $msg) = @_;

   $msg =~ s/\n$//;

   printf STDERR "%s <%d> %s\n",
          (POSIX::strftime "%Y-%m-%d %H:%M:%S", localtime time),
          $level,
          $msg;
};

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

BEGIN {
   *TRACE = $ENV{PERL_ANYEVENT_MP_TRACE}
      ? sub () { 1 }
      : sub () { 0 };
}

sub _inject {
   warn "RCV $SRCNODE->{noderef} -> @_\n" if TRACE && @_;#d#
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

      $node = new AnyEvent::MP::Node::Direct $noderef;
   }

   $NODE{$_} = $node
      for $noderef, split /,/, $noderef;

   $node
}

sub connect_node {
   &add_node->connect;
}

sub snd(@) {
   my ($noderef, $portid) = split /#/, shift, 2;

   warn "SND $noderef <- $portid @_\n" if TRACE;#d#

   ($NODE{$noderef} || add_node $noderef)
      ->{send} (["$portid", @_]);
}

=item $is_local = port_is_local $port

Returns true iff the port is a local port.

=cut

sub port_is_local($) {
   my ($noderef, undef) = split /#/, $_[0], 2;

   $NODE{$noderef} == $NODE{""}
}

=item snd_to_func $node, $func, @args

Expects a noderef and a name of a function. Asynchronously tries to call
this function with the given arguments on that node.

This fucntion can be used to implement C<spawn>-like interfaces.

=cut

sub snd_to_func($$;@) {
   my $noderef = shift;

   ($NODE{$noderef} || add_node $noderef)
      ->send (["", @_]);
}

=item snd_on $node, @msg

Executes C<snd> with the given C<@msg> (which must include the destination
port) on the given node.

=cut

sub snd_on($@) {
   my $node = shift;
   snd $node, snd => @_;
}

=item eval_on $node, $string

Evaluates the given string as Perl expression on the given node.

=cut

sub eval_on($@) {
   my $node = shift;
   snd $node, eval => @_;
}

sub kil(@) {
   my ($noderef, $portid) = split /#/, shift, 2;

   length $portid
      or Carp::croak "$noderef#$portid: killing a node port is not allowed, caught";

   ($NODE{$noderef} || add_node $noderef)
      ->kill ("$portid", @_);
}

sub _nodename {
   require POSIX;
   (POSIX::uname ())[1]
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

      $t = length $t ? _nodename . ":$t" : _nodename
         if $t =~ /^\d*$/;
      
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
      };
   }

   $cv->end;

   $cv
}

sub _node_rename {
   $NODE = shift;

   my $self = $NODE{""};
   $NODE{$NODE} = delete $NODE{$self->{noderef}};
   $self->{noderef} = $NODE;
}

sub initialise_node(@) {
   my ($noderef, @others) = @_;

   my $profile = AnyEvent::MP::Config::find_profile
                    +(defined $noderef ? $noderef : _nodename);

   $noderef = $profile->{noderef}
      if exists $profile->{noderef};

   push @others, @{ $profile->{seeds} };

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

   _node_rename $noderef->recv;

   for my $t (split /,/, $NODE) {
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

   for (@others) {
      my $node = add_node $_;
      $node->{autoconnect} = 1;
      $node->connect;
   }

   if ($SLAVE) {
      my $timeout = AE::timer $MONITOR_TIMEOUT, 0, sub { $SLAVE->() };
      my $master = $SLAVE->recv;
      $master
         or Carp::croak "AnyEvent::MP: unable to enter slave mode, unable to connect to a seednode.\n";

      $MASTER = $master->{noderef};
      $master->{autoconnect} = 1;

      (my $via = $MASTER) =~ s/,/!/g; 

      $NODE .= "\@$via";
      _node_rename $NODE;

      $_->send (["", iam => $NODE])
         for values %NODE;

      $SLAVE = 1;
   }

   for (@{ $profile->{services} }) {
      if (s/::$//) {
         eval "require $_";
         die $@ if $@;
      } else {
         (load_func $_)->();
      }
   }
}

#############################################################################
# node monitoring and info

sub _uniq_nodes {
   my %node;

   @node{values %NODE} = values %NODE;

   values %node;
}

=item node_is_known $noderef

Returns true iff the given node is currently known to the system.

=cut

sub node_is_known($) {
   exists $NODE{$_[0]}
}

=item node_is_up $noderef

Returns true if the given node is "up", that is, the kernel thinks it has
a working connection to it.

If the node is known but not currently connected, returns C<0>. If the
node is not known, returns C<undef>.

=cut

sub node_is_up($) {
   ($NODE{$_[0]} or return)->{transport}
      ? 1 : 0
}

=item known_nodes

Returns the noderefs of all nodes connected to this node, including
itself.

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

The function returns an optional guard which can be used to de-register
the monitoring callback again.

=cut

our %MON_NODES;

sub mon_nodes($) {
   my ($cb) = @_;

   $MON_NODES{$cb+0} = $cb;

   wantarray && AnyEvent::Util::guard { delete $MON_NODES{$cb+0} }
}

sub _inject_nodeevent($$;@) {
   my ($node, $up, @reason) = @_;

   for my $cb (values %MON_NODES) {
      eval { $cb->($node->{noderef}, $up, @reason); 1 }
         or $WARN->(1, $@);
   }

   $WARN->(7, "$node->{noderef} is " . ($up ? "up" : "down") . " (@reason)");
}

#############################################################################
# self node code

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
      # get rid of bogus slave/xxx name, hopefully
      delete $NODE{$SRCNODE->{noderef}};

      # change noderef
      $SRCNODE->{noderef} = $_[0];

      # anchor
      $NODE{$_[0]} = $SRCNODE;
   },

   # "public" services - not actually public

   # relay message to another node / generic echo
   snd => \&snd,
   snd_multi => sub {
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
   "" => sub {
      # empty messages are sent by monitoring
   },
);

$NODE{""} = $NODE{$NODE} = new AnyEvent::MP::Node::Self $NODE;
$PORT{""} = sub {
   my $tag = shift;
   eval { &{ $node_req{$tag} ||= load_func $tag } };
   $WARN->(2, "error processing node message: $@") if $@;
};

=back

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

