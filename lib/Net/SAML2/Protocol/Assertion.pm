use strict;
use warnings;
package Net::SAML2::Protocol::Assertion;
use Moose;
use MooseX::Types::DateTime qw/ DateTime /;
use MooseX::Types::Common::String qw/ NonEmptySimpleStr /;
use DateTime;
use DateTime::HiRes;
use DateTime::Format::XSD;
use Net::SAML2::XML::Util qw/ no_comments /;
use XML::LibXML;

with 'Net::SAML2::Role::ProtocolMessage';

our $VERSION = '0.49';

# ABSTRACT: Net::SAML2::Protocol::Assertion - SAML2 assertion object

=head1 NAME

Net::SAML2::Protocol::Assertion - SAML2 assertion object

=head1 SYNOPSIS

  my $assertion = Net::SAML2::Protocol::Assertion->new_from_xml(
    xml => decode_base64($SAMLResponse)
  );

=cut

has 'attributes'        => (isa => 'HashRef[ArrayRef]', is => 'ro', required => 1);
has 'session'           => (isa => 'Str',               is => 'ro', required => 1);
has 'nameid'            => (isa => 'Str',               is => 'ro', required => 1);
has 'not_before'        => (isa => DateTime,            is => 'ro', required => 1);
has 'not_after'         => (isa => DateTime,            is => 'ro', required => 1);
has 'audience'          => (isa => NonEmptySimpleStr,   is => 'ro', required => 1);
has 'xpath'             => (isa => 'XML::LibXML::XPathContext',        is => 'ro', required => 1);
has 'in_response_to'    => (isa => 'Str',               is => 'ro', required => 1);
has 'response_status'   => (isa => 'Str',               is => 'ro', required => 1);

=head1 METHODS

=cut

=head2 new_from_xml( ... )

Constructor. Creates an instance of the Assertion object, parsing the
given XML to find the attributes, session and nameid.

Arguments:

=over

=item B<xml>

XML data

=back

=cut

sub new_from_xml {
    my($class, %args) = @_;

    my $dom = no_comments($args{xml});

    my $xpath = XML::LibXML::XPathContext->new($dom);
    $xpath->registerNs('saml',  'urn:oasis:names:tc:SAML:2.0:assertion');
    $xpath->registerNs('samlp', 'urn:oasis:names:tc:SAML:2.0:protocol');

    my $attributes = {};
    for my $node (
        $xpath->findnodes('//saml:Assertion/saml:AttributeStatement/saml:Attribute'))
    {
        # We can't select by saml:AttributeValue
        # because of https://rt.cpan.org/Public/Bug/Display.html?id=8784
        my @values = $node->findnodes("*[local-name()='AttributeValue']");
        $attributes->{$node->getAttribute('Name')} = [map $_->string_value, @values];
    }

    my $not_before;
    if($xpath->findvalue('//saml:Conditions/@NotBefore')) {
        $not_before = DateTime::Format::XSD->parse_datetime(
            $xpath->findvalue('//saml:Conditions/@NotBefore'));
    }
    else {
        $not_before = DateTime::HiRes->now();
    }

    my $not_after;
    if($xpath->findvalue('//saml:Conditions/@NotOnOrAfter')) {
        $not_after = DateTime::Format::XSD->parse_datetime(
            $xpath->findvalue('//saml:Conditions/@NotOnOrAfter'));
    }
    else {
        $not_after = DateTime->from_epoch(epoch => time() + 1000);
    }

    my $self = $class->new(
        issuer         => $xpath->findvalue('//saml:Assertion/saml:Issuer'),
        destination    => $xpath->findvalue('/samlp:Response/@Destination'),
        attributes     => $attributes,
        session        => $xpath->findvalue('//saml:AuthnStatement/@SessionIndex'),
        nameid         => $xpath->findvalue('//saml:Subject/saml:NameID'),
        audience       => $xpath->findvalue('//saml:Conditions/saml:AudienceRestriction/saml:Audience'),
        not_before     => $not_before,
        not_after      => $not_after,
        xpath          => $xpath,
        in_response_to => $xpath->findvalue('//saml:Subject/saml:SubjectConfirmation/saml:SubjectConfirmationData/@InResponseTo'),
        response_status => $xpath->findvalue('//samlp:Response/samlp:Status/samlp:StatusCode/@Value'),
    );

    return $self;
}

=head2 name( )

Returns the CN attribute, if provided.

=cut

sub name {
    my($self) = @_;
    return $self->attributes->{CN}->[0];
}

=head2 valid( $audience, $in_response_to )

Returns true if this Assertion is currently valid for the given audience.

Also accepts $in_response_to which it checks against the returned
Assertion.  This is very important for security as it helps ensure
that the assertion that was received was for the request that was made.

Checks the audience matches, and that the current time is within the
Assertions validity period as specified in its Conditions element.

=cut

sub valid {
    my ($self, $audience, $in_response_to) = @_;

    return 0 unless defined $audience;
    return 0 unless($audience eq $self->audience);

    return 0 unless !defined $in_response_to
        or $in_response_to eq $self->in_response_to;

    my $now = DateTime::HiRes->now;

    # not_before is "NotBefore" element - exact match is ok
    # not_after is "NotOnOrAfter" element - exact match is *not* ok
    return 0 unless DateTime::->compare($now,             $self->not_before) > -1;
    return 0 unless DateTime::->compare($self->not_after, $now) > 0;

    return 1;
}

1;
