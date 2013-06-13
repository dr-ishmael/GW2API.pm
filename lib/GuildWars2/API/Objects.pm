use Carp ();
use Modern::Perl '2012';

package GuildWars2::API::Objects;
BEGIN {
  $GuildWars2::API::Objects::VERSION = '0.50';
}
use Moose;

=pod

=head1 DESCRIPTION

This class and its subclasses define the objects that can be returned from
GuildWars2::API. Some objects also have methods attached to them.

=head1 SUBCLASSES

See the individual modules for documentation of these subclasses

=item * GuildWars2::API::Objects::Color
=item * GuildWars2::API::Objects::Guild


=cut

use GuildWars2::API::Objects::Color;
use GuildWars2::API::Objects::Guild;


1;
