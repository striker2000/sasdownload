sasdownload
===========

Perl script for downloading raster maps tiles in SAS.Planet cache format.

[SAS.Planet](http://sasgis.ru/sasplaneta/) is a freeware program, which allows
download and view raster maps from many sources such as Google Maps, Yandex
Maps, OpenStreetMap, etc.

Usage
-----

	sasdownload.pl -c [cache_dir] -b [bounds] -m [maps] -z [zoom]

### Example

Download OSM Mapnik and Google Sat maps of Moscow with zoom from 10 to 15 to
~/sasplanet/cache directory:

	sasdownload.pl -c ~/sasplanet/cache -b 55.4,36.8,56.1,38.5 -m osmmapMapnik,sat -z 10-15
