#!/usr/bin/env perl

use strict;
use warnings;

use threads;
use threads::shared;

use File::Path qw( make_path );
use Geo::Proj4;
use Getopt::Std;
use LWP::UserAgent;
use Time::HiRes qw( usleep );

my $sources = {
	osmmapMapnik => {
		url => sub {
			'http://a.tile.openstreetmap.org'
				. "/$_[2]/$_[0]/$_[1].png"
		},
		proj => 'epsg:3857',
		format => 'png',
	},
	yamapng => {
		url => sub {
			'http://vec.maps.yandex.net'
				. "/tiles?l=map&v=2.17.1&x=$_[0]&y=$_[1]&z=$_[2]"
		},
		proj => 'epsg:3395',
		format => 'png',
	},
	yasat => {
		url => sub {
			'http://sat01.maps.yandex.net'
				. "/tiles?l=sat&v=1.21.0&x=$_[0]&y=$_[1]&z=$_[2]"
		},
		proj => 'epsg:3395',
		format => 'jpg',
	},
	sat => {
		url => sub {
			'http://khm.google.com'
				. "/kh/v=79&hl=ru&x=$_[0]&y=$_[1]&z=$_[2]"
		},
		proj => 'epsg:3857',
		format => 'jpg',
	},
	GSHin7ane => {
		url => sub {
			'http://www.in7ane.com'
				. "/topomaps/tiles/$_[2]/$_[0]/$_[1].jpg"
		},
		proj => 'epsg:3857',
		format => 'jpg',
	},
	Navitel => {
		url => sub {
			'http://maps.navitel.su'
				. '/navitms.fcgi?t='
				. sprintf( '%08d', $_[0] )
				. ','
				. sprintf( '%08d', 2 ** $_[2] - $_[1] - 1 )
				. ','
				. sprintf( '%02d', $_[2] )
		},
		proj => 'epsg:3857',
		format => 'png',
	},
};

our ( $opt_b, $opt_c, $opt_m, $opt_z, $opt_D );
getopts( 'b:c:m:z:D' );
unless ( $opt_b && $opt_c && $opt_m && $opt_z ) {
	die "Usage: sasdownload.pl -c [cache_dir] -b [bounds] -m [maps] -z [zoom]\n";
}

my ( $bounds, $cache_dir, $maps, $zooms, $errors ) = parse_opts();
if ( @$errors ) {
	die join( "\n", @$errors ), "\n";
}

my $ua = LWP::UserAgent->new(
	keep_alive => 1,
);

my $status = {};
share( $status );
foreach my $map ( @$maps ) {
	my $hash_ref = {};
	share( $hash_ref );
	$status->{ $map } = $hash_ref;
	foreach my $zoom ( @$zooms ) {
		my $hash_ref = {};
		share( $hash_ref );
		$status->{ $map }->{ $zoom } = $hash_ref;
	}
	threads->create( 'download_map', $map );
}

while ( threads->list( threads::running ) ) {
	print_status();
	sleep( 1 );
}
print_status();

#===============================================================================
sub parse_opts {
	my @errors;

	my @bounds = split /,/, $opt_b;
	unless (
		@bounds == 4
		&& $bounds[0] >= -180 && $bounds[0] <= 180
		&& $bounds[1] >= -90 && $bounds[1] <= 90
		&& $bounds[2] >= -180 && $bounds[2] <= 180
		&& $bounds[3] >= -90 && $bounds[3] <= 90
		&& $bounds[0] <= $bounds[2]
		&& $bounds[1] <= $bounds[3]
	) {
		push @errors, "Wrong bounds: $opt_b";
	}

	my $cache_dir = $opt_c;
	unless ( -d $cache_dir ) {
		push @errors, "Cache directory does not exists: $cache_dir"
	}

	my @maps = split /,/, $opt_m;
	foreach ( @maps ) {
		push @errors, "Wrong map: $_" unless $sources->{ $_ };
	}

	my @zooms;
	if ( $opt_z =~ /^(\d+)$/ ) {
		if ( $1 >= 1 && $1 <= 18 ) {
			push @zooms, $opt_z;
		}
		else {
			push @errors, "Wrong zoom: $opt_z";
		}
	}
	elsif ( $opt_z =~ /^(\d+)-(\d+)$/ ) {
		if (
			$1 >= 1 && $1 <= 18
			&& $2 >= 1 && $2 <= 18
			&& $1 < $2
		) {
			push @zooms, $_ foreach $1 .. $2;
		}
		else {
			push @errors, "Wrong zoom: $opt_z";
		}
	}
	else {
		push @errors, "Wrong zoom: $opt_z";
	}

	return ( \@bounds, $cache_dir, \@maps, \@zooms, \@errors );
}

#===============================================================================
sub download_map {
	my ( $map ) = @_;

	my $proj = Geo::Proj4->new( init => $sources->{ $map }->{proj} );
	my $format = $sources->{ $map }->{format};
	foreach my $zoom ( @$zooms ) {
		download_layer( $map, $zoom, $proj, $format, $bounds );
	}

	threads->detach;
}

#===============================================================================
sub download_layer {
	my ( $map, $zoom, $proj, $format, $bounds ) = @_;

	my ( $x1, $y1 ) = get_tile_xy( @$bounds[ 2, 1 ], $zoom, $proj );
	my ( $x2, $y2 ) = get_tile_xy( @$bounds[ 0, 3 ], $zoom, $proj );

	my ( $total, $exist, $error );
	$total = ( $x2 - $x1 + 1 ) * ( $y2 - $y1 + 1 );
	$exist = $error = 0;

	my $vals = {};
	share( $vals );
	$vals->{total} = $total;
	$vals->{exist} = $exist;
	$vals->{error} = $error;
	$status->{ $map }->{ $zoom } = $vals;

	for ( my $x = $x1; $x <= $x2; $x++ ) {
		for ( my $y = $y1; $y <= $y2; $y++ ) {
			$vals->{exist} = $exist;
			$vals->{error} = $error;

			my $dir = "$cache_dir/$map/z$zoom/"
				. int( $x / 1024 ) . "/x$x/"
				. int( $y / 1024 );
			my $file = "$dir/y$y.$format";

			if ( -e $file ) {
				$exist++;
				next;
			}
			if ( $opt_D ) {
				$error++;
				next;
			}
			make_path( $dir ) unless -e $dir;

			my $url = $sources->{ $map }->{url}( $x, $y, $zoom - 1 );
			my $res = $ua->get( $url, ':content_file' => $file );
			if ( $res->is_success ) {
				$exist++;
			}
			else {
				#print $url . ': ' . $res->status_line . "\n";
				$error++;
			}

			usleep( 100000 );
		}
	}

	$vals->{exist} = $exist;
	$vals->{error} = $error;
}

#===============================================================================
sub get_tile_xy {
	my ( $lat, $lon, $zoom, $proj ) = @_;

	my ( $x, $y ) = $proj->forward( $lat, $lon );
	$x = $x + 20037508.34;
	$y = 20037508.34 - $y;
	my $res = ( 2 ** ( $zoom - 2 ) ) / 20037508.34;
	$x *= $res;
	$y *= $res;

	return ( int $x, int $y );
}

#===============================================================================
sub print_status {
	print "\x1B[1J\x1B[H         Total     Exist     Error\n";
	foreach my $map ( sort keys %$status ) {
		print "$map\n";
		foreach my $zoom ( sort keys %{ $status->{ $map } } ) {
			my $vals = $status->{ $map }->{ $zoom };
			printf '%4d', $zoom;
			if ( defined $vals->{total} ) {
				printf '%10d%10d%10d',
					$vals->{total},
					$vals->{exist},
					$vals->{error};
			}
			print "\n";
		}
	}
}
