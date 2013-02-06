package LWP::Authen::OAuth;

=head1 NAME

LWP::Authen::OAuth - generate signed OAuth requests

=head1 SYNOPSIS

	require LWP::Authen::OAuth;

=head2 Google

	# Google uses 'anonymous' for unregistered Web/offline applications or the
	# domain name for registered Web applications
	my $ua = LWP::Authen::OAuth->new(
		oauth_consumer_secret => "anonymous",
	);
	
	# request a 'request' token
	my $r = $ua->post( "https://www.google.com/accounts/OAuthGetRequestToken",
		[
			oauth_consumer_key => 'anonymous',
			oauth_callback => 'http://example.net/oauth',
			xoauth_displayname => 'Example Application',
			scope => 'https://docs.google.com/feeds/',
		]
	);
	die $r->as_string if $r->is_error;
	
	# update the token secret from the HTTP response
	$ua->oauth_update_from_response( $r );
	
	# open a browser for the user 
	
	# data are returned as form-encoded
	my $uri = URI->new( 'http:' );
	$uri->query( $r->content );
	my %oauth_data = $uri->query_form;
	
	# Direct the user to here to grant you access:
	# https://www.google.com/accounts/OAuthAuthorizeToken?
	# 	oauth_token=$oauth_data{oauth_token}\n";
	
	# turn the 'request' token into an 'access' token with the verifier
	# returned by google
	$r = $ua->post( "https://www.google.com/accounts/OAuthGetAccessToken", [
		oauth_consumer_key => 'anonymous',
		oauth_token => $oauth_data{oauth_token},
		oauth_verifier => $oauth_verifier,
	]);
	
	# update the token secret from the HTTP response
	$ua->oauth_update_from_response( $r );
	
	# now use the $ua to perform whatever actions you want

=head2 Twitter

Sending status updates to a single account is quite easy if you create an application. The C<oauth_consumer_key> and C<oauth_consumer_secret> come from the 'Application Details' page and the C<oauth_token> and C<oauth_token_secret> from the 'My Access Token' page.

	my $ua = LWP::Authen::OAuth->new(
		oauth_consumer_key => 'xxx1',
		oauth_consumer_secret => 'xxx2',
		oauth_token => 'yyy1',
		oauth_token_secret => 'yyy2',
	);
	
	$ua->post( 'http://api.twitter.com/1/statuses/update.json', [
		status => 'Posted this using LWP::Authen::OAuth!'
	]);

=head1 DESCRIPTION

This module provides a sub-class of L<LWP::UserAgent> that generates OAuth 1.0 signed requests. You should familiarise yourself with OAuth at L<http://oauth.net/>.

This module only supports HMAC_SHA1 signing.

OAuth nonces are generated using the Perl random number generator. To set a nonce manually define 'oauth_nonce' in your requests via a CGI parameter or the Authorization header - see the OAuth documentation.

=head1 METHODS

=over 4

=item $ua = LWP::Authen::OAuth->new( ... )

Takes the same options as L<LWP::UserAgent/new> plus optionally:

	oauth_consumer_key
	oauth_consumer_secret
	oauth_token
	oauth_token_secret

Most services will require some or all of these to be set even if it's just 'anonymous'.

=item $ua->oauth_update_from_response( $r )

Update the C<oauth_token> and C<oauth_token_secret> from an L<HTTP::Response> object returned by a previous request e.g. when converting a request token into an access token.

=item $key = $ua->oauth_consumer_key( [ KEY ] )

Get and optionally set the consumer key.

=item $secret = $ua->oauth_consumer_secret( [ SECRET ] )

Get and optionally set the consumer secret.

=item $token = $ua->oauth_token( [ TOKEN ] )

Get and optionally set the oauth token.

=item $secret = $ua->oauth_token_secret( [ SECRET ] )

Get and optionally set the oauth token secret.

=back

=head1 SEE ALSO

L<LWP::UserAgent>, L<MIME::Base64>, L<Digest::SHA>, L<URI>, L<URI::Escape>

=head2 Rationale

I think the complexity in OAuth is in the parameter normalisation and message signing. What this module does is to hide that complexity without replicating the higher-level protocol chatter.

In Net::OAuth:

	$r = Net::OAuth->request('request token')->new(
		consumer_key => 'xxx',
		request_url => 'https://photos.example.net/request_token',
		callback => 'http://printer.example.com/request_token_ready',
		...
		extra_params {
			scope => 'global',
		}
	);
	$r->sign;
	$res = $ua->request(POST $r->to_url);
	$res = Net::OAuth->response('request token')
		->from_post_body($res->content);
	... etc

In LWP::Authen::OAuth:

	$ua = LWP::Authen::OAuth->new(
		oauth_consumer_key => 'xxx'
	);
	$res = $ua->post( 'https://photos.example.net/request_token', [
		oauth_callback => 'http://printer.example.com/request_token_ready',
		...
		scope => 'global',
	]);
	$ua->oauth_update_from_response( $res );
	... etc

L<Net::OAuth>, L<OAuth::Lite>.

=head1 AUTHOR

Timothy D Brody <tdb2@ecs.soton.ac.uk>

Copyright 2011 University of Southampton, UK

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself

=cut

use LWP::UserAgent;
use URI;
use URI::Escape;
use Digest::SHA;
use MIME::Base64;

$VERSION = '1.01';
@ISA = qw( LWP::UserAgent );

use strict;

sub new
{
	my( $class, %self ) = @_;

	my $self = $class->SUPER::new( %self );

	for(qw( oauth_consumer_key oauth_consumer_secret oauth_token oauth_token_secret ))
	{
		$self->{$_} = $self{$_};
	}

	return $self;
}

sub request
{
	my( $self, $request, @args ) = @_;

	$self->sign_hmac_sha1( $request );

	return $self->SUPER::request( $request, @args );
}

sub oauth_encode_parameter
{
	my( $str ) = @_;
	return URI::Escape::uri_escape_utf8( $str, '^\w.~-' ); # 5.1
}

sub oauth_nonce
{
	my $nonce = '';
	$nonce .= sprintf("%02x", int(rand(255))) for 1..16;
	return $nonce;
}

sub oauth_authorization_param
{
	my( $request, @args ) = @_;

	if( @args )
	{
		my @parts;
		for(my $i = 0; $i < @args; $i+=2)
		{
			# header values are in quotes
			push @parts, sprintf('%s="%s"',
				map { oauth_encode_parameter( $_ ) }
				@args[$i,$i+1]
			);
		}
		$request->header( 'Authorization', sprintf('OAuth %s',
			join ',', @parts ) );
	}

	my $authorization = $request->header( 'Authorization' );
	return if !$authorization;
	return if $authorization !~ s/^\s*OAuth\s+//i;

	return
		map { URI::Escape::uri_unescape( $_ ) }
		map { $_ =~ /([^=]+)="(.*)"/; ($1, $2) }
		split /\s*,\s*/,
		$authorization;
}

sub sign_hmac_sha1
{
	my( $self, $request ) = @_;

	my $method = $request->method;
	my $uri = URI->new( $request->uri )->canonical;
	my $content_type = $request->header( 'Content-Type' );
	$content_type = '' if !defined $content_type;
	my $oauth_header = $request->header( "Authorization" );

	# build the parts of the string to sign
	my @parts;

	push @parts, $method;

	my $request_uri = $uri->clone;
	$request_uri->query( undef );
	push @parts, "$request_uri";

	# build up a list of parameters
	my @params;

	# CGI parameters (OAuth only supports urlencoded)
	if(
		$method eq "POST" &&
		$content_type eq 'application/x-www-form-urlencoded'
	)
	{
		$uri->query( $request->content );
	}
	
	push @params, $uri->query_form;

	# HTTP OAuth Authorization parameters
	my @auth_params = oauth_authorization_param( $request );
	my %auth_params = @auth_params;
	if( !exists($auth_params{oauth_nonce}) )
	{
		push @auth_params, oauth_nonce => oauth_nonce();
	}
	if( !exists($auth_params{oauth_timestamp}) )
	{
		push @auth_params, oauth_timestamp => time();
	}
	if( !exists($auth_params{oauth_version}) )
	{
		push @auth_params, oauth_version => '1.0';
	}
	for(qw( oauth_consumer_key oauth_token ))
	{
		if( !exists($auth_params{$_}) && defined($self->{$_}) )
		{
			push @auth_params, $_ => $self->{$_};
		}
	}
	push @auth_params, oauth_signature_method => "HMAC-SHA1";

	push @params, @auth_params;

	# lexically order the parameters as bytes (sorry for obscure code)
	{
		use bytes;
		my @pairs;
		push @pairs, [splice(@params,0,2)] while @params;
		# order by key name then value
		@pairs = sort {
			$a->[0] cmp $b->[0] || $a->[1] cmp $b->[0]
		} @pairs;
		@params = map { @$_ } @pairs;
	}

	# re-encode the parameters according to OAuth spec.
	my @query;
	for(my $i = 0; $i < @params; $i+=2)
	{
		next if $params[$i] eq "oauth_signature"; # 9.1.1
		push @query, sprintf('%s=%s',
			map { oauth_encode_parameter( $_ ) }
			@params[$i,$i+1]
		);
	}
	push @parts, join '&', @query;

	# calculate the data to sign and the secret to use (encoded again)
	my $data = join '&',
		map { oauth_encode_parameter( $_ ) }
		@parts;
	my $secret = join '&',
		map { defined($_) ? oauth_encode_parameter( $_ ) : '' }
		$self->{oauth_consumer_secret},
		$self->{oauth_token_secret};

	# 9.2
	my $digest = Digest::SHA::hmac_sha1( $data, $secret );

	push @auth_params,
		oauth_signature => MIME::Base64::encode_base64( $digest, '' );

	oauth_authorization_param( $request, @auth_params );
}

sub oauth_update_from_response
{
	my( $self, $r ) = @_;

	my $uri = URI->new( 'http:' );
	$uri->query( $r->content );
	my %oauth_data = $uri->query_form;

	for(qw( oauth_token oauth_token_secret ))
	{
		$self->{$_} = $oauth_data{$_};
	}
}

sub oauth_consumer_key
{
	my $self = shift;
	if( @_ )
	{
		$self->{oauth_consumer_key} = shift;
	}
	return $self->{oauth_consumer_key};
}

sub oauth_consumer_secret
{
	my $self = shift;
	if( @_ )
	{
		$self->{oauth_consumer_secret} = shift;
	}
	return $self->{oauth_consumer_secret};
}

sub oauth_token
{
	my $self = shift;
	if( @_ )
	{
		$self->{oauth_token} = shift;
	}
	return $self->{oauth_token};
}

sub oauth_token_secret
{
	my $self = shift;
	if( @_ )
	{
		$self->{oauth_token_secret} = shift;
	}
	return $self->{oauth_token_secret};
}

1;
