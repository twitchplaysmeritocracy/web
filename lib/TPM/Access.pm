package TPM::Access;
use Dancer ':syntax';

use 5.12.0;
use warnings;

use Data::Dumper;
use File::Slurp;
use LWP::UserAgent;
use JSON qw//;
use Try::Tiny;

use Email::Sender::Simple;
use Email::Simple;
use Email::Simple::Creator;

our $VERSION = '0.1';

my $json = read_file('config.json');
my $config = JSON->new->decode($json);
my $akeys = {};
my $dkeys = {};

hook before => sub {
  clean_auth_keys();
};

get '/' => sub {
  template 'index';
};

get '/add' => sub {
  template 'add';
};

get '/delete' => sub {
  template 'delete';
};

post '/add' => sub {
  my $user = params->{user};
  try {
    if ( is_member($config, $user) ) {
      template 'generic', { message => "$user is already a member!" };
    } else {
      my $email = get_user_email($config, $user);
      open my $fh, '<', '/dev/urandom';
      read $fh, my $bkey, 32;
      my $key = unpack("h*", $bkey);
      $akeys->{$user} = [ $key, time ];
      email($email, 'add', $user, $key);
      template 'generic', { message => "check $email for activation url" };
    }
  } catch {
    status 404;
    template 'generic', { message => "$user does not exist on github: $_" };
  };
};

post '/delete' => sub {
  my $user = params->{user};
  try {
    if ( is_member($config, $user) ) {
      my $email = get_user_email($config, $user);
      open my $fh, '<', '/dev/urandom';
      read $fh, my $bkey, 32;
      my $key = unpack("h*", $bkey);
      $dkeys->{$user} = [ $key, time ];
      email($email, 'delete', $user, $key);
      template 'generic', { message => "check $email for deactivation url" };
    } else {
      template 'generic', { message => "$user is not a member!" };
    }
  } catch {
    status 500;
    return 'unknown error';
  };
};

get '/add/:user/:key' => sub {
  my $user = params->{user};
  my $key = params->{key};
  try {
    if (!exists $akeys->{$user}) {
      status 404;
      return "$user has no auth key";
    }
    my ($valid, $time) = @{ $akeys->{$user} };
    if (time - $time > 60*15) {
      status 410;
      return "auth key too old for $user";
    }
    if ($key ne $valid) {
      status 403;
      return "auth key invalid for $user";
    }
    template 'generic', { message => "$user added to tpm" } if add_member($config, $user);
  } catch {
    status 500;
    return 'unknown error';
  };
};

get '/delete/:user/:key' => sub {
  my $user = params->{user};
  my $key = params->{key};
  try {
    if (!exists $dkeys->{$user}) {
      status 404;
      return "$user has no auth key";
    }
    my ($valid, $time) = @{ $dkeys->{$user} };
    if (time - $time > 60*15) {
      status 410;
      return "auth key too old for $user";
    }
    if ($key ne $valid) {
      status 403;
      return "auth key invalid for $user";
    }
    template 'generic', { message => "$user deleted from tpm" } if delete_member($config, $user);
  } catch {
    status 500;
    return 'unknown error';
  };
};

sub clean_auth_keys {
  for my $user (keys %$akeys) {
    if (time - $akeys->{$user}[1] > 60*60) {
      delete $akeys->{$user};
    }
  }
  for my $user (keys %$dkeys) {
    if (time - $dkeys->{$user}[1] > 60*60) {
      delete $dkeys->{$user};
    }
  }
}

sub email {
  my ($address, $type, $user, $key) = @_;
  my $base_url = "http://tpm.laurelmail.net";
  my $url = "$base_url/$type/$user/$key";

  my $subject = $type eq 'add' ? "Add $user to tpm" : "Delete $user from tpm";
  my $action = $type eq 'add' ? 'added to' : 'deleted from';
  my $body = <<"BODY";
Someone, hopefully you, requested that $user be $action https://github.com/twitchplaysmeritocracy.
If this is true, click here: $url.
Otherwise, ignore this message, and nothing will happen.
BODY

  my $email = Email::Simple->create(
    header => [
      To      => $address,
      From    => '"twitch plays meritocracy" <tpm@laurelmail.net>',
      Subject => $subject,
    ],
    body => $body,
  );

  Email::Sender::Simple->send($email);
}

sub delete_member {
  my ($config, $member) = @_;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new(DELETE => "https://api.github.com/orgs/$config->{org}/members/$member");
  $request->authorization_basic($config->{token}, 'x-oauth-basic');
  my $response = $ua->request($request);
  if ($response->code == 204) {
    return 1;
  } else {
    die $response->status_line . "\n";
  }
}

sub is_member {
  my ($config, $member) = @_;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new(GET => "https://api.github.com/teams/$config->{teamid}/members/$member");
  $request->authorization_basic($config->{token}, 'x-oauth-basic');
  my $response = $ua->request($request);
  if ($response->code == 204) {
    return 1;
  } elsif ($response->code == 404) {
    return 0;
  } else {
    die $response->status_line . "\n";
  }
}

sub add_member {
  my ($config, $member) = @_;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new(PUT => "https://api.github.com/teams/$config->{teamid}/members/$member");
  $request->header('Content-Length' => 0);
  $request->authorization_basic($config->{token}, 'x-oauth-basic');
  my $response = $ua->request($request);
  if ($response->code == 204) {
    return 1;
  } else {
    die $response->status_line . "\n";
  }
}

sub members {
  my ($config) = @_;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new(GET => "https://api.github.com/teams/$config->{teamid}/members");
  $request->authorization_basic($config->{token}, 'x-oauth-basic');
  my $response = $ua->request($request);
  if ($response->code == 200) {
    return $response->decoded_content;
  } else {
    die $response->status_line . "\n";
  }
}

sub get_user_email {
  my ($config, $user) = @_;
  my $ua = LWP::UserAgent->new;
  my $request = HTTP::Request->new(GET => "https://api.github.com/users/$user");
  $request->authorization_basic($config->{token}, 'x-oauth-basic');
  my $response = $ua->request($request);
  if ($response->code == 200) {
    return JSON->new->decode($response->decoded_content)->{email};
  } else {
    die $response->status_line . "\n";
  }
}


true;

__END__

curl -X DELETE -u $key:x-oauth-basic -i https://api.github.com/orgs/twitchplaysmeritocracy/members/sdboyer
204

curl -u $key:x-oauth-basic -i https://api.github.com/teams/729660/members/sdboyer
404

curl -X PUT -u $key:x-oauth-basic -i -d '' https://api.github.com/teams/729660/members/sdboyer
204

curl -u $key:x-oauth-basic -i https://api.github.com/teams/729660/members/sdboyer
204

curl -X GET -u $key:x-oauth-basic -i https://api.github.com/teams/729660/members
200



