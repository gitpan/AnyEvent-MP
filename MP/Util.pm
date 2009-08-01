=head1 NAME

AnyEvent::MP::Util - utility cruft

=head1 SYNOPSIS

   use AnyEvent::MP::Util;

   # undocumented

=head1 DESCRIPTION

Guess.

=head1 FUNCTIONS/METHODS

Guess.

=over 4

=cut

package AnyEvent::MP::Util;

use common::sense;

our $VERSION = '0.0';

# => util
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

=back

=head1 SEE ALSO

L<AnyEvent::MP>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

