use strict;
use warnings;
package Net::SAML2::IdP;
use Moose;
use MooseX::Types::URI qw/ Uri /;

our $VERSION = '0.49';

# ABSTRACT: Net::SAML2::IdP - SAML Identity Provider object

=head1 NAME

Net::SAML2::IdP - SAML Identity Provider object

=head1 SYNOPSIS

  my $idp = Net::SAML2::IdP->new_from_url(
        url => $url,
        cacert => $cacert,
        ssl_opts =>         # Optional options supported by LWP::Protocol::https
            {
                SSL_ca_file     => '/your/directory/cacert.pem',
                SSL_ca_path     => '/etc/ssl/certs',
                verify_hostname => 1,
            }
        );
  my $sso_url = $idp->sso_url('urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect');

=head1 METHODS

=cut

use Crypt::OpenSSL::Verify;
use Crypt::OpenSSL::X509;
use HTTP::Request::Common;
use LWP::UserAgent;
use XML::LibXML;
use Net::SAML2::XML::Util qw/ no_comments /;

=head2 new( )

Constructor

=over

=item B<entityid>

=item B<sls_force_lcase_url_encoding>

Specifies that the IdP requires the encoding of a URL to be in lowercase.
Necessary for a HTTP-Redirect of a LogoutResponse from Azure in particular.
True (1) or False (0). Some web frameworks and underlying http requests assume
that the encoding should be in the standard uppercase (%2F not %2f)

=item B<sls_double_encoded_response>

Specifies that the IdP response sent to the HTTP-Redirect is double encoded.
The double encoding requires it to be decoded prior to processing.

=back

=cut

has 'entityid' => (isa => 'Str',          is => 'ro', required => 1);
has 'cacert'   => (isa => 'Maybe[Str]',   is => 'ro', required => 1);
has 'sso_urls' => (isa => 'HashRef[Str]', is => 'ro', required => 1);
has 'slo_urls' => (isa => 'Maybe[HashRef[Str]]', is => 'ro');
has 'art_urls' => (isa => 'Maybe[HashRef[Str]]', is => 'ro');
has 'certs'    => (isa => 'HashRef[Str]',        is => 'ro', required => 1);
has 'formats'  => (isa => 'HashRef[Str]',        is => 'ro', required => 1);
has 'sls_force_lcase_url_encoding'    => (isa => 'Bool', is => 'ro', required => 0);
has 'sls_double_encoded_response' => (isa => 'Bool', is => 'ro', required => 0);
has 'default_format'          => (isa => 'Str',  is => 'ro', required => 1);

=head2 new_from_url( url => $url, cacert => $cacert, ssl_opts => {} )

Create an IdP object by retrieving the metadata at the given URL.

Dies if the metadata can't be retrieved with reason.

=cut

sub new_from_url {
    my($class, %args) = @_;

    my $req = GET $args{url};
    my $ua  = LWP::UserAgent->new;

    if ( defined $args{ssl_opts} ) {
        require LWP::Protocol::https;
        $ua->ssl_opts( %{$args{ssl_opts}} );
    }

    my $res = $ua->request($req);
    if (! $res->is_success ) {
        my $msg = "no metadata: " . $res->code . ": " . $res->message . "\n";
        die $msg;
    }

    my $xml = $res->content;

    return $class->new_from_xml(
                    xml => $xml,
                    cacert => $args{cacert},
                    sls_force_lcase_url_encoding => $args{sls_force_lcase_url_encoding},
                    sls_double_encoded_response => $args{sls_double_encoded_response},
                    );
}

=head2 new_from_xml( xml => $xml, cacert => $cacert )

Constructor. Create an IdP object using the provided metadata XML
document.

=cut

sub new_from_xml {
    my($class, %args) = @_;

    my $dom = no_comments($args{xml});

    my $xpath = XML::LibXML::XPathContext->new($dom);
    $xpath->registerNs('md', 'urn:oasis:names:tc:SAML:2.0:metadata');
    $xpath->registerNs('ds', 'http://www.w3.org/2000/09/xmldsig#');

    my $data;

    for my $sso (
        $xpath->findnodes(
            '//md:EntityDescriptor/md:IDPSSODescriptor/md:SingleSignOnService')
        )
    {
        my $binding = $sso->getAttribute('Binding');
        $data->{SSO}->{$binding} = $sso->getAttribute('Location');
    }

    for my $slo (
        $xpath->findnodes(
            '//md:EntityDescriptor/md:IDPSSODescriptor/md:SingleLogoutService')
        )
    {
        my $binding = $slo->getAttribute('Binding');
        $data->{SLO}->{$binding} = $slo->getAttribute('Location');
    }

    for my $art (
        $xpath->findnodes(
            '//md:EntityDescriptor/md:IDPSSODescriptor/md:ArtifactResolutionService')
        )
    {
        my $binding = $art->getAttribute('Binding');
        $data->{Art}->{$binding} = $art->getAttribute('Location');
    }

    for my $format (
        $xpath->findnodes('//md:EntityDescriptor/md:IDPSSODescriptor/md:NameIDFormat'))
    {
        $format = $format->string_value;
        $format =~ s/^\s+|\s+$//g;
        my($short_format)
            = $format =~ /urn:oasis:names:tc:SAML:(?:2.0|1.1):nameid-format:(.*)$/;
        if(defined $short_format) {
            $data->{NameIDFormat}->{$short_format} = $format;
            $data->{DefaultFormat} = $short_format unless exists $data->{DefaultFormat};
        }
    }

    # NameIDFormat is an optional field and not provided in all metadata xml
    # Microsoft in particular does not provide this field
    if(!defined($data->{NameIDFormat})){
        $data->{NameIDFormat}->{unspecified} = 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified';
        $data->{DefaultFormat} = 'unspecified' unless exists $data->{DefaultFormat};
    }

    for my $key (
        $xpath->findnodes('//md:EntityDescriptor/md:IDPSSODescriptor/md:KeyDescriptor'))
    {
        my $use = $key->getAttribute('use') || 'signing';

        # We can't select by ds:KeyInfo/ds:X509Data/ds:X509Certificate
        # because of https://rt.cpan.org/Public/Bug/Display.html?id=8784
        my ($text)
            = $key->findvalue("//*[local-name()='X509Certificate']")
            =~ /^\s*(.+?)\s*$/s;

        # rewrap the base64 data from the metadata; it may not
        # be wrapped at 64 characters as PEM requires
        $text =~ s/\n//g;

        my @lines;
        while(length $text > 64) {
            push @lines, substr $text, 0, 64, '';
        }
        push @lines, $text;

        $text = join "\n", @lines;

        # form a PEM certificate
        $data->{Cert}->{$use}
            = sprintf("-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n",
            $text);
    }

    my $self = $class->new(
        entityid       => $xpath->findvalue('//md:EntityDescriptor/@entityID'),
        sso_urls       => $data->{SSO},
        slo_urls       => $data->{SLO} || {},
        art_urls       => $data->{Art} || {},
        certs          => $data->{Cert},
        formats        => $data->{NameIDFormat},
        default_format => $data->{DefaultFormat},
        cacert         => $args{cacert},
        sls_force_lcase_url_encoding => $args{sls_force_lcase_url_encoding},
        sls_double_encoded_response => $args{sls_double_encoded_response},
    );

    return $self;
}

=head2 BUILD ( hashref of the parameters passed to the constructor )

Called after the object is created to validate the IdP using the cacert

=cut

sub BUILD {
    my($self) = @_;

    if ($self->cacert) {
        my $ca = Crypt::OpenSSL::Verify->new($self->cacert, { strict_certs => 0, });

        for my $use (keys %{$self->certs}) {
            my $cert = Crypt::OpenSSL::X509->new_from_string($self->certs->{$use});
            ## BUGBUG this is failing for valid things ...
            eval { $ca->verify($cert) };
            if ($@) {
                warn "Can't verify IdP '$use' cert: $@\n";
            }
        }
    }
}

=head2 sso_url( $binding )

Returns the url for the SSO service using the given binding. Binding
name should be the full URI.

=cut

sub sso_url {
    my($self, $binding) = @_;
    return $self->sso_urls->{$binding};
}

=head2 slo_url( $binding )

Returns the url for the Single Logout Service using the given
binding. Binding name should be the full URI.

=cut

sub slo_url {
    my ($self, $binding) = @_;
    return $self->slo_urls ? $self->slo_urls->{$binding} : undef;
}

=head2 art_url( $binding )

Returns the url for the Artifact Resolution service using the given
binding. Binding name should be the full URI.

=cut

sub art_url {
    my ($self, $binding) = @_;
    return $self->art_urls ? $self->art_urls->{$binding} : undef;
}

=head2 cert( $use )

Returns the IdP's certificate for the given use (e.g. C<signing>).

=cut

sub cert {
    my($self, $use) = @_;
    return $self->certs->{$use};
}

=head2 binding( $name )

Returns the full Binding URI for the given binding name (i.e. C<redirect> or C<soap>).
Includes this module's currently-supported bindings.

=cut

sub binding {
    my($self, $name) = @_;

    my $bindings = {
        redirect => 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect',
        soap     => 'urn:oasis:names:tc:SAML:2.0:bindings:SOAP',
    };

    if(exists $bindings->{$name}) {
        return $bindings->{$name};
    }

    return;
}

=head2 format( $short_name )

Returns the full NameID Format URI for the given short name.

If no short name is provided, returns the URI for the default format,
the one listed first by the IdP.

If no NameID formats were advertised by the IdP, returns undef.

=cut

sub format {
    my($self, $short_name) = @_;

    if(defined $short_name && exists $self->formats->{$short_name}) {
        return $self->formats->{$short_name};
    }
    elsif($self->default_format) {
        return $self->formats->{$self->default_format};
    }

    return;
}

__PACKAGE__->meta->make_immutable;
