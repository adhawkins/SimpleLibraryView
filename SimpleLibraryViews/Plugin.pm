# Simple Library Views plugin for Logitech Media Server
# Copyright (C) 2016 Andy Hawkins
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Andy Hawkins - andy@gently.org.uk

package Plugins::SimpleLibraryViews::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Menu::BrowseLibrary;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use File::Basename;
use File::Spec::Functions qw(catfile);
use Slim::Utils::Prefs;
use Slim::Control::Request;
use Path::Class;

my $log = Slim::Utils::Log->addLogCategory({
        'category'     => 'plugin.simplelibraryviews',
        'defaultLevel' => 'WARN',
        'description'  => 'PLUGIN_SIMPLE_LIBRARY_VIEWS_DESC',
});

if ( main::WEBUI ) {
	require Plugins::SimpleLibraryViews::Settings;
}

my $prefs = preferences('plugin.simplelibraryviews');

sub initPlugin {
	my $class = shift;

	$log->info("In initPlugin for SimpleLibraryViews");

	$prefs->init({
		libraries => ''
	});

	if ( main::WEBUI ) {
		Plugins::SimpleLibraryViews::Settings->new;
	}

	registerLibraries();

	$class->SUPER::initPlugin(@_);
}

sub scheduleRegisterLibraries {
	$log->info("Scheduling library register, new: '" . $prefs->get('libraries') . "'");

	my @newLibraries = split(/;/, $prefs->get('libraries'));

	foreach my $library (@newLibraries) {
		$library =~ s/^\s+|\s+$//g;
	}

	my %newLibrariesHash = map { $_ => 1 } @newLibraries;

	my $libs = Slim::Music::VirtualLibraries->getLibraries();

	foreach my $libid (keys % {$libs}) {
		my $name = Slim::Music::VirtualLibraries->getNameForId($libid);

		$log->info("Found registered lib ID ". $libid . ", name '" . $name);

		$name =~ /^SimpleLibraryViews (.*)/ || next;

		my $slvLib = $1;
		$log->info("Found SLV lib: '" . $slvLib . "'");

		if (! exists($newLibrariesHash{$slvLib})) {
			$log->info("Unregisering lib '" . $name . "'");
			Slim::Music::VirtualLibraries->unregisterLibrary($libid);
		}
	}

	registerLibraries();
}

sub registerLibraries {
	$log->info("In registerLibraries: '" . $prefs->get('libraries') . "'");

	my @libraries = split(/;/, $prefs->get('libraries'));
	foreach my $library (@libraries) {
		$library =~ s/^\s+|\s+$//g;
		$log->info("Checking library '$library'");
		if ($library ne "" ) {
			$log->info("Processing library '$library'");

			my $newID = Slim::Music::VirtualLibraries->registerLibrary( {
				id => $library,
				name => "SimpleLibraryViews $library",
				scannerCB => sub {
					my $libraryId = shift;
					createLibrary($libraryId, $library);
				}
			} );

			$log->info("Registered library $newID");
		}
	}

	Slim::Control::Request::executeRequest( undef, [ 'rescan' ] );
}

sub getDisplayName {
	return 'PLUGIN_SIMPLE_LIBRARY_VIEWS';
}

sub createLibrary {
	my $id = shift;
	my $libName = shift;

	$log->info("Scanner callback Building library id " . $id . " for name " . $libName);

	if ( ! main::SCANNER )
	{
		$log->info("Scanner callback Not in scanner building library id " . $id . " for name " . $libName);
		return;
	}

	$log->info("Scanner callback continuing");

	my $dbh = Slim::Schema->dbh;

	# prepare the insert SQL statement - no need to re-initialize for every track
	my $sth_insert = $dbh->prepare('INSERT OR IGNORE INTO library_track (library, track) values (?, ?)');

	# get track ID and URL for every single audio track in our library
	my $sth = $dbh->prepare('SELECT id, url FROM tracks WHERE content_type NOT IN ("cpl", "src", "ssp", "dir") ORDER BY url');
	$sth->execute();

	# use a hash to cache results of the library file checks
	my %knownDirs;

	# iterate over all tracks in our library
	while ( my ($trackid, $url) = $sth->fetchrow_array ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Checking trackID: $trackid, url: '$url'");

		if (Slim::Music::Info::isFileURL($url)) {
			my $addToView = 0;
			my $dir = dirname(Slim::Utils::Misc::pathFromFileURL($url));

			while (Slim::Utils::Misc::inMediaFolder($dir)) {
				my $cacheEntry = $knownDirs{$dir};

				main::DEBUGLOG && $log->is_debug && $log->debug("Checking '$dir' ($cacheEntry)");

				if (defined($cacheEntry)) {
					$addToView = $cacheEntry;

					main::DEBUGLOG && $log->is_debug && $log->debug("In cache: $addToView");
				} else {
					main::DEBUGLOG && $log->is_debug && $log->debug("Not in cache, checking files");

					my $libFile = catfile($dir, "simple-library-views-$libName");
					my $newLibFile = catfile($dir, ".simple-library-views-$libName");

					$addToView = (-f $libFile || -f $newLibFile) ? 1 : 0;
					main::DEBUGLOG && $log->is_debug && $log->debug("Found files: $addToView");

					$knownDirs{$dir} = $addToView;
				}

				last if $addToView;

				$dir = dir($dir)->parent;
			}

			if ($addToView) {
				$log->debug("Adding " . $url . " to library " . $libName);

				$sth_insert->execute($id, $trackid);
			}
		}
	}
}

1;

__END__
