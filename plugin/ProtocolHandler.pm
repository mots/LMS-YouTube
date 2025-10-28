package Plugins::YouTube::ProtocolHandler;

# (c) 2018, philippe_44@outlook.com
# (c) 2025, simply.mots@gmail.com
#
# Released under GPLv2
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use URI;
use URI::Escape;
use Scalar::Util qw(blessed);
use Data::Dumper;
use File::Spec::Functions;
use FindBin qw($Bin);
use POSIX qw(strftime waitpid);
use Fcntl;

use IPC::Open3;
use Symbol qw(gensym);
use Errno qw(EAGAIN EWOULDBLOCK);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Slim::Networking::IO::Select qw(addRead removeRead);

use Plugins::YouTube::WebM;
use Plugins::YouTube::M4a;

use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128*1024;
use constant PAGE_URL_REGEXP => qr{^https?://(?:(?:www|m|music)\.youtube\.com/(?:watch\?|playlist\?|channel/)|youtu\.be/)}i;

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__)
    if Slim::Player::ProtocolHandlers->can('registerURLHandler');

sub flushCache { $cache->cleanup(); }

=comment
There is a voluntaty 'confusion' between codecs and streaming formats
(regular http or dash). As we only support ogg/opus with webm and aac
withdash, this is not a problem at this point, although not very elegant.
This only works because it seems that YT, when using webm and dash (171)
does not build a mpd file but instead uses regular webm. It might be due
to http://wiki.webmproject.org/adaptive-streaming/webm-dash-specification
but I'm not sure at that point. Anyway, the dash webm format used in codec
171, 251, 250 and 249, probably because there is a single stream, does not
need a different handling than normal webm
=cut

my $setProperties  = { 	'ogg' => \&Plugins::YouTube::WebM::setProperties,
						'ops' => \&Plugins::YouTube::WebM::setProperties,
						'aac' => \&Plugins::YouTube::M4a::setProperties
				};
my $getAudio 	   = { 	'ogg' => \&Plugins::YouTube::WebM::getAudio,
						'ops' => \&Plugins::YouTube::WebM::getAudio,
						'aac' => \&Plugins::YouTube::M4a::getAudio
				};
my $getStartOffset = { 	'ogg' => \&Plugins::YouTube::WebM::getStartOffset,
						'ops' => \&Plugins::YouTube::WebM::getStartOffset,
						'aac' => \&Plugins::YouTube::M4a::getStartOffset
				};

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;

	main::INFOLOG && $log->is_info && $log->info( "action=$action" );

	# if restart, restart from beginning (stop being live edge)
	$client->playingSong()->pluginData('props')->{'liveOffset'} = 0 if $action eq 'rew' && $client->isPlaying(1);

	return 1;
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $offset;
	my $props = $song->pluginData('props');

	return undef if !defined $props;

	main::DEBUGLOG && $log->is_debug && $log->debug( Dumper($props) );

	# erase last position from cache
	$cache->remove("yt:lastpos-" . $class->getId($args->{'url'}));

	# set offset depending on format
	$offset = $props->{'liveOffset'} if $props->{'liveOffset'};
	$offset = $props->{offset}->{clusters} if $props->{offset}->{clusters};

	$args->{'url'} = $song->pluginData('baseURL');

	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $song->pluginData('lastpos');
	$song->pluginData('lastpos', 0);

	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$offset = undef;
	}

	main::INFOLOG && $log->is_info && $log->info("url: $args->{url} offset: ", $startTime || 0);

	my $self = $class->SUPER::new;

	if (defined($self)) {
		${*$self}{'client'} = $args->{'client'};
		${*$self}{'song'}   = $args->{'song'};
		${*$self}{'url'}    = $args->{'url'};
		${*$self}{'props'}  = $props;
		${*$self}{'vars'}   = {        		# variables which hold state for this instance:
			'inBuf'       => '',      		# buffer of received data
			'outBuf'      => '',      		# buffer of processed audio
			'streaming'   => 1,      		# flag for streaming, changes to 0 when all data received
			'fetching'    => 0,		  		# waiting for HTTP data
			'offset'      => $offset,  		# offset for next HTTP request in webm/stream or segment index in dash
			'session' 	  => Slim::Networking::Async::HTTP->new,
			'baseURL'	  => $args->{'url'},
			'retry'       => 5,
		};
	}

	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{$props->{'format'}}($args->{url}, $startTime, $props, sub {
			${*$self}{'vars'}->{offset} = shift;
			$log->info("starting from offset ", ${*$self}{'vars'}->{offset});
		}
	) if !defined $offset;

	# for live stream, always set duration to timeshift depth
	if ($props->{'timeShiftDepth'}) {
		# only set offset when missing startTime or not starting from live edge
		$song->startOffset($props->{'timeShiftDepth'} - $prefs->get('live_delay')) unless $startTime || !$props->{'liveOffset'};
		$song->duration($props->{'timeShiftDepth'});
		$song->pluginData('liveStream', 1);
		$props->{'startOffset'} = $song->startOffset;
	} else {
		$song->pluginData('liveStream', 0);
	}

	${*$self}{'active'}  = 1;

	return $self;
}

sub close {
	my $self = shift;

	${*$self}{'active'} = 0;
	${*$self}{'vars'}->{'session'}->disconnect;

	main::INFOLOG && $log->is_info && $log->info("end of streaming for ", ${*$self}{'song'}->track->url);

	$self->SUPER::close(@_);
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::YouTube::ProtocolHandler->getId($song->track->url);

	if ($elapsed < $song->duration - 15) {
		$cache->set("yt:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("yt:lastpos-$id");
	}
}

sub onStream {
	my ($class, $client, $song) = @_;
	my $url = $song->track->url;

	$url =~ s/&lastpos=([\d]+)//;

	my $id = Plugins::YouTube::ProtocolHandler->getId($url);
	my $meta = $cache->get("yt:meta-$id") || {};

	Plugins::YouTube::Plugin->updateRecentlyPlayed( {
		url  => $url,
		name => $meta->{_fulltitle} || $meta->{title} || $song->track->title,
		icon => $meta->{icon} || $song->icon,
	} );
}

sub formatOverride {
	return $_[1]->pluginData('props')->{'format'};
}

sub contentType {
	return ${*{$_[0]}}{'props'} ? ${*{$_[0]}}{'props'}->{'format'} : undef;
}

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { 0 }

sub songBytes { }

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

my $nextWarning = 0;

sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
	my $props = ${*$self}{'props'};

	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}

	# need more data
	if ( length $v->{'outBuf'} < MIN_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $url = $v->{'baseURL'};
		my $headers = [ 'Connection', 'keep-alive' ];

		push @$headers, 'Range', "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1);

		my $request = HTTP::Request->new( GET => $url, $headers);
		$request->protocol( 'HTTP/1.1' );

		$v->{'fetching'} = 1;

		$v->{'session'}->send_request( {
			request => $request,

			onRedirect => sub {
				my $redirect = shift->uri;
				$v->{'baseURL'} = $redirect;
				main::INFOLOG && $log->is_info && $log->info("being redirected from $url to $redirect using new base $v->{baseURL}");
			},

			onBody => sub {
				my $response = shift->response;

				$v->{'inBuf'} .= $response->content;
				$v->{'fetching'} = 0;
				$v->{'retry'} = 5;

				($v->{length}) = $response->header('content-range') =~ /\/(\d+)$/ unless $v->{length};
				my $len = length $response->content;
				$v->{offset} += $len;
				$v->{'streaming'} = 0 if ($len < DATA_CHUNK && !$v->{length}) || ($v->{length} && $v->{offset} >= $v->{length});
				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: $len from ", $v->{offset} - $len, " total received: $v->{offset}", ($v->{length} ? "/$v->{length}" : ""), " for $url");
			},

			onError => sub {
				$log->warn("error $v->{retry} fetching $url: $_[1]") unless $v->{'baseURL'} ne ${*$self}{'url'} && $v->{'retry'};
				$v->{'retry'}--;
				$v->{'fetching'} = 0 if $v->{retry} > 0;
				$v->{'baseURL'} = ${*$self}{'url'};
			},
		} );
	}

	# process all available data
	$getAudio->{$props->{'format'}}($v, $props) if $props && $props->{'format'} && length $v->{'inBuf'};

	if ( my $bytes = min(length $v->{'outBuf'}, $maxBytes) ) {
		$_[1] = substr($v->{'outBuf'}, 0, $bytes, '');
		return $bytes;
	} elsif ( $v->{'streaming'} && $v->{'retry'} > 0 ) {
		$! = EINTR;
		return undef;
	}

	# end of streaming
	main::INFOLOG && $log->is_info && $log->info("end streaming");
	$props->{'updatePeriod'} = 0 if $props;

	return 0;
}

sub getId {
	my ($class, $url) = @_;

	if ($url =~ /^(?:youtube:\/\/)?https?:\/\/(?:www|m|music)\.youtube\.com\/watch\?v=([^&]*)/ ||
		$url =~ /^youtube:\/\/(?:www|m)\.youtube\.com\/v\/([^&]*)/ ||
		$url =~ /^youtube:\/\/([^&]*)/ ||
		$url =~ m{^https?://youtu\.be/([a-zA-Z0-9_\-]+)}i ||
		$url =~ /\b([a-zA-Z0-9_\-]{11})\b/ )
		{
		return $1;
	}

	return undef;
}

# --- NEW getNextTrack using IPC::Open3 and Slim::Networking::IO::Select ---
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $masterUrl = $song->track()->url;

	$song->pluginData(lastpos => ($masterUrl =~ /&lastpos=([\d]+)/)[0] || 0);
	$masterUrl =~ s/&.*//;

	my $id = $class->getId($masterUrl);
	unless ($id) {
		$log->error("Could not extract YouTube ID from URL: $masterUrl");
		return $errorCb->("Invalid YouTube URL");
	}

	main::INFOLOG && $log->is_info && $log->info("next track id: $id (using non-blocking IPC::Open3, watching stdout only)");

	my @formats;
	push @formats, '251', '250', '249', '171' if $prefs->get('ogg');
	push @formats, '141', '140', '139' if $prefs->get('aac');
	@formats = ('140') unless @formats;

	my $format_string = join('/', @formats);
	my $youtube_url = "https://www.youtube.com/watch?v=$id";

	my @cmd = ('yt-dlp', '-f', $format_string, '--get-format', '--get-url', '--no-playlist', $youtube_url);

	my ($stdin_fh, $stdout_fh, $stderr_fh) = (gensym, gensym, gensym);
	my $pid;
	eval {
		$pid = open3($stdin_fh, $stdout_fh, $stderr_fh, @cmd);
	};
	if ($@ || !defined $pid) {
		my $err_msg = $@ || "IPC::Open3 failed to return PID";
		$log->error("Failed to execute yt-dlp for $id: $err_msg");
		return $errorCb->("Failed to execute yt-dlp: $err_msg");
	}

	$log->debug("Spawned yt-dlp with PID $pid for $id");

	fcntl($stdout_fh, F_SETFL, O_NONBLOCK);

	my $stdout_buffer = '';
	my $stderr_buffer = '';

	my $on_finish_cb = sub {
		removeRead($stdout_fh);
		close $stdout_fh;
		close $stderr_fh;
		close $stdin_fh;

		waitpid($pid, 0);
		my $exit_code = $? >> 8;
		$log->debug("Reaped PID $pid for $id (exit: $exit_code)");

		my $current_song = $song->master->playingSong();
		if (!$current_song || !$current_song->track || $current_song->track->url ne $song->track->url) {
			$log->info("yt-dlp finished for stale track, discarding: " . $song->track->url);
			return $errorCb->("Stale track");
		}

		{
			local $/;
			eval {
				$stderr_buffer = <$stderr_fh>;
			};
			if ($@) {
				$log->warn("Error reading final stderr from yt-dlp PID $pid: $@");
			}
		}
		$stderr_buffer //= '';

		if ($exit_code != 0) {
			$log->error("yt-dlp failed for $id. Exit: $exit_code.\nSTDOUT:\n$stdout_buffer\nSTDERR:\n$stderr_buffer");
			return $errorCb->("yt-dlp failed (exit code $exit_code)");
		}

		my ($url, $itag);
		foreach my $line (split(/\n/, $stdout_buffer)) {
			$url = $line if $line =~ /^https?:\/\//;
			$itag = $1 if $line =~ /^(\d+)/;
		}
		chomp($url) if $url;

		if (!$url || !$itag) {
			$log->error("yt-dlp returned unparseable output for $id.\nSTDOUT:\n$stdout_buffer\nSTDERR:\n$stderr_buffer");
			return $errorCb->("yt-dlp returned unparseable output");
		}

		my %itag_to_format = (
			'251'=>'ops', '250'=>'ops', '249'=>'ops', '171'=>'ogg',
			'141'=>'aac', '140'=>'aac', '139'=>'aac',
		);
		my $format = $itag_to_format{$itag} // do {
			$log->warn("Unknown itag $itag from yt-dlp, assuming AAC");
			'aac';
		};

		main::INFOLOG && $log->is_info && $log->info("Got format: $format (itag $itag) for $id");

		my $props = { format => $format };
		if (blessed($song)) {
			$song->pluginData(props => $props);
			$song->pluginData(baseURL  => $url);
			if (my $handler = $setProperties->{$props->{'format'}}) {
				$handler->($song, $props, $successCb, $errorCb);
			} else {
				$log->error("No setProperties handler found for format '$format'");
				$errorCb->("Unsupported format '$format'");
			}
		} else {
			$log->warn("Song object no longer valid when yt-dlp finished for $id");
			$errorCb->("Song object invalid");
		}
	};

	my $stdout_read_cb = sub {
		my $buf;
		my $bytes = sysread($stdout_fh, $buf, 4096);

		if (defined $bytes && $bytes > 0) {
			$stdout_buffer .= $buf;
		} elsif (defined $bytes && $bytes == 0) {
			$log->debug("EOF detected on stdout for PID $pid, triggering finish handler.");
			$on_finish_cb->();
		} elsif (!defined $bytes) {
			if ($! != EWOULDBLOCK && $! != EAGAIN) {
				$log->warn("Error reading stdout from yt-dlp PID $pid: $!");
				$on_finish_cb->();
			}
		}
	};

	addRead($stdout_fh, $stdout_read_cb);
}

sub getMetadataFor {
	my ($class, $client, $full_url) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $id = $class->getId($url) || return {};

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	if (my $meta = $cache->get("yt:meta-$id")) {
		my $song = $client->playingSong();

		if ($song && $song->currentTrack()->url eq $full_url) {
			$song->track->secs( $meta->{duration} );
			if (defined $meta->{_thumbnails}) {
				$meta->{cover} = $meta->{icon} = Plugins::YouTube::Plugin::_getImage($meta->{_thumbnails}, 1);
				delete $meta->{_thumbnails};
				$cache->set("yt:meta-$id", $meta);
				main::INFOLOG && $log->is_info && $log->info("updating thumbnail cache with hires $meta->{cover}");
			}
		}

		main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $id");

		return $meta;
	}

	if ($client->master->pluginData('fetchingYTMeta')) {
		main::DEBUGLOG && $log->is_debug && $log->debug("already fetching metadata: $id");
		return {
			type	=> 'YouTube',
			title	=> $url,
			icon	=> $icon,
			cover	=> $icon,
		};
	}

	# Go fetch metadata for all tracks on the playlist without metadata
	my $pageCall;

	$pageCall = sub {
		my ($abort) = @_;

		my @need;

		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;

			if ( $trackURL =~ m{youtube:/*(.+)} ) {
				my $trackId = $class->getId($trackURL);

				if ( $trackId && !$cache->get("yt:meta-$trackId") ) {
					push @need, $trackId;
				} elsif (!$trackId) {
					$log->warn("No id found: $trackURL");
				}

				# we can't fetch more than 50 at a time
				last if (scalar @need >= 50);
			}
		}

		if (scalar @need && !$abort) {
			my $list = join( ',', @need );
			main::INFOLOG && $log->is_info && $log->info( "Need to fetch metadata for: $list");
			_getBulkMetadata($client, $pageCall, $list);
		} else {
			$client->master->pluginData(fetchingYTMeta => 0);
			unless ($abort) {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			}
		}
	};

	$client->master->pluginData(fetchingYTMeta => 1);

	# get the one item if playlist empty
	if ( Slim::Player::Playlist::count($client) ) {
		$pageCall->();
	} else {
		_getBulkMetadata($client, undef, $id);
	}

	return {
			type	=> 'YouTube',
			title	=> $url,
			icon	=> $icon,
			cover	=> $icon,
	};
}

sub _getBulkMetadata {
	my ($client, $cb, $ids) = @_;

	Plugins::YouTube::API->getVideoDetails( sub {
		my $result = shift;

		if ( !$result || $result->{error} || !$result->{pageInfo}->{totalResults} || !scalar @{$result->{items}} ) {
			$log->error($result->{error}->{message} || $result->{error} || 'Failed to grab track information');
			$cb->(1) if defined $cb;
			return;
		}

		foreach my $item (@{$result->{items}}) {
			my $snippet = $item->{snippet};
			my $title   = $snippet->{'title'};
			my $cover   = my $icon = Plugins::YouTube::Plugin::_getImage($snippet->{thumbnails});
			my $artist  = "";
			my $fulltitle;

			if ($title =~ /^(.*?) - (.*)$/) {
				$fulltitle = $title;
				$artist = $1;
				$title  = $2;
			} else {
				$artist = $snippet->{channelTitle} || '';
			}

			my $duration = $item->{contentDetails}->{duration};
			main::DEBUGLOG && $log->is_debug && $log->debug("Duration: $duration");
			my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
			$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

			my $meta = {
				title    =>	$title || '',
				artist   => $artist,
				duration => $duration || 0,
				icon     => $icon,
				cover    => $cover || $icon,
				type     => 'YouTube',
				_fulltitle => $fulltitle,
				_thumbnails => $snippet->{thumbnails},
			};

			$cache->set("yt:meta-" . $item->{id}, $meta, 86400);
		}

		$cb->() if defined $cb;
	}, $ids);
}

sub getIcon {
	my ( $class, $url ) = @_;
	return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}

sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	return $cb->([$uri]) unless $uri =~ PAGE_URL_REGEXP;

	$uri = URI->new($uri);

	my $handler;
	my $search;
	if ( $uri->host eq 'youtu.be' ) {
		$handler = \&Plugins::YouTube::Plugin::urlHandler;
		$search = ($uri->path_segments)[1];
	}
	elsif ( $uri->path eq '/watch' ) {
		$handler = \&Plugins::YouTube::Plugin::urlHandler;
		$search = $uri->query_param('v');
	}
	elsif ( $uri->path eq '/playlist' ) {
		$handler = \&Plugins::YouTube::Plugin::playlistIdHandler;
		$search = $uri->query_param('list');
	}
	elsif ( ($uri->path_segments)[1] eq 'channel' ) {
		$handler = \&Plugins::YouTube::Plugin::channelIdHandler;
		$search = ($uri->path_segments)[2];
	} else {
		$log->warn("Don't know how to explode YouTube URL: $uri");
		return $cb->([$uri]);
	}

	if ($handler) {
		$handler->(
			$client,
			sub { $cb->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
			{'search' => $search},
			{},
		);
	} else {
		$log->error("No handler found for YouTube URL type: $uri");
		return $cb->([$uri]);
	}
}

1;
