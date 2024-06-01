#!/usr/bin/env perl

use strict;
use warnings;
use Storable qw(dclone);
require Getopt::Long;

my $usage = "
usage: $0 [-H <hint.pbm>] <secretfile> <fontfile> <output.pbm>

Encodes a message from stdin, using the given one-time pad and square font, to a PBM file.
Within the message, carriage returns start a new encoded line, as expected.

Current limitation: only square fonts allowed, e.g. all characters NxN.

A textual representation of the process is printed to stdout.

The secret file is expected to be a binary sequence in OEIS format (https://oeis.org)

-H\tSpecify a option hint bitmap can be supplied, which will be placed below the code.
";

my $help = 0;
my $hintpath = undef;

Getopt::Long::GetOptions(
	"h" => \$help,
	"H=s" => \$hintpath
) or die("Error in command line arguments\n");

die $usage unless @ARGV == 3;
die $usage if $help;

my $secretpath = shift @ARGV;
my $fontpath = shift @ARGV;
my $pbmpath = shift @ARGV;

my $secret = read_oeis_sequence($secretpath);
my $font = read_font($fontpath);
my $hint = read_pbm($hintpath); # returns undef if no $hintpath
my $message = do { local $/ ; <> };

die $usage if $message =~ /^\n*$/; # no empty messages

print "plaintext:\n$message\n";

my ($buffer, $width, $height) = rasterize($message, $font);

print "plaintext bitmap:\n";
render_to_console($buffer);

encode($buffer, $secret);

print "ciphertext bitmap:\n";
render_to_console($buffer);
render_to_pbm($buffer, $width, $pbmpath, $hint);

exit 0;

# read_oeis_sequence(file)
#
# Reads a file containing an integer sequence and returns an arrayref of bits, e.g. [ 0, 1, 0, 1, 1, ... ]
#
# The secret file is expected to be a binary sequence, either in OEIS format (https://oeis.org) or a simple bit
# list 0/1, one per line.
sub read_oeis_sequence
{
	my $file = shift;
	# for testing, can use: my @d = (0) x $ndigits; return \@d;
	my $digits = [];
	open IN, "<$file" or die;
	while (<IN>) {
		chomp;
		next unless length($_);
		next if $_ =~ /^#/;
		$_ =~ s/^\s+//;
		next if $_ =~ /^$/;
		my ($seq, $bit) = split(/\s+/, $_); # assume OEIS format
		$bit = $seq unless defined $bit; # adjust if plain bitstring
		push @$digits, $bit? 1:0;
	}
	close IN;
	return $digits;
}

# read_font(fontpath)
#
# Load a square monofont (NxN) from the given path. The file format is text. Each character is specified in turn,
# in any order.
#
# A character is described as follows:
# - One line containing the character itself
# - N lines of N characters, a dot matrix of the character representation, where a space is "off" and * is "on"
#
# N must be > 1 and the same for all characters.
#
# Returns { N, <font> } where <font> is a hashref, key = character, value = arrayref of arrayref of pixels, i.e.
#   { char -> [ [ <pixels left-to-right> ], [...] ] ]
sub read_font
{
	my $fontpath = shift;
	my $font = {};
	my $max_n = 99;
	my $n = $max_n;

	open IN, "<$fontpath" or die;
	while (my $line = <IN>) {
		chomp $line;
		die unless length($line) == 1;
		my $char = $line;
		die if exists $font->{$char};
		my $pixels = [];
		for (my $i = 0; $i < $n; $i++) {
			my $line = <IN>;
			chomp $line;
			if ($n >= $max_n) { # i.e. we don't know the font size yet...
				$n = length($line);
				die if $n <= 1 or $n >= $max_n;
			} else {
				die "bad line $.\n\t" unless $line =~ /^[ *]{$n}$/;
			}
			my @row = split(//, $line);
			push @$pixels, \@row;
		}
		$font->{$char} = $pixels;
	}
	close IN;

	return ($n, $font);
}

# read_pbm(pbmpath)
#
# Reads a Portable Bitmap file from the given path and returns an arrayref of arrayrefs of bits.
sub read_pbm
{
	my $pbmpath = shift;
	return undef unless defined $pbmpath;
	my $hint = [];
	open IN, "<$pbmpath" or die;
	my $line = <IN>;
	$line = <IN>;
	chomp $line;
	my ($x, $y) = split(/\s+/, $line);
	for (1..$y) {
		$line = <IN>;
		chomp $line;
		my @bits = split(/\s+/, $line);
		die unless $x == @bits;
		@bits = map { $_ ne '0' } @bits;
		push @$hint, \@bits;
	}
	die unless $y == @$hint;
	close IN;
	return $hint;
}

# rasterize(text, font)
#
# Convert text into an array of pixels using the supplied font.
#
# Returns an array with elements:
# [0] -> a reference to an array of lines. Each line is an arrayref of characters, each character a 2D arrayref of bits.
# [1] -> the number of characters in the longest line of the text
# [2] -> the number of lines in the text
sub rasterize
{
	my $text = shift;
	my $font = shift;
	my $buffer = []; # is array of lines
	my $line = []; # is array of chars
	my $x = 0;
	my $y = 0;
	for my $char (split(//, $text)) {
		if ($char eq "\n") {
			push @$buffer, $line;
			$x = max($x, scalar(@$line));
			$line = [];
		}
		elsif ($char eq " ") {
			push @$line, undef;
		}
		elsif (defined $font->{$char}) {
			push @$line, dclone($font->{$char});
		}
		else {
			die "no char $char in font\n";
		}
	}
	# if text does not end with a newline, push the last accumulated line
	push @$buffer, $line unless 0 == scalar(@$line);
	$x = max($x, scalar(@$line));
	$y = scalar(@$line);
	return ($buffer, $x, $y);
}

# encode(buffer, key[, key_offset])
#
# XORs a buffer from rasterize() in-place (the supplied buffer is modified), using the given key.
#
# To generate the bit string, the pixel buffer is traversed one character a time, then the next
# character from the row, ... , then the next row, and so on.
#
# Encoding starts with the first bit of the key unless an offset is supplied.
#
# Returns the key offset after encoding.
sub encode
{
	my $buffer = shift;
	my $key = shift;
	my $keyoffset = shift || 0;
	for my $line_ (0..$#$buffer) {
		for my $char_ (0..$#{$buffer->[$line_]}) {
			for my $scan_ (0..$#{$buffer->[$line_]->[$char_]}) {
				for my $pixel_ (0..$#{$buffer->[$line_]->[$char_]->[$scan_]}) {
					my $bit = $buffer->[$line_]->[$char_]->[$scan_]->[$pixel_] eq ' '? 0:1;
					my $keybit = $key->[$keyoffset];
					$keyoffset = 0 if (++$keyoffset >= scalar(@$key));
					$bit = ($bit != $keybit);
					$bit = $bit? '*':' ';
					$buffer->[$line_]->[$char_]->[$scan_]->[$pixel_] = $bit;
				}
			}
		}
	}
	return $keyoffset;
}

# render_to_console(buffer)
#
# Prints a buffer from rasterize()/encode() to the console.
sub render_to_console
{
	my $buffer = shift;
	for my $line (@$buffer) {
		next unless @$line;
		for my $scan_ (0..$#{$line->[0]}) {
			for my $char (@$line) {
				if (defined $char->[$scan_]) {
					print join("", @{$char->[$scan_]}) , "  ";
				}
				else { # it's a space character
					print " " x (0+@{$font->{'A'}->[0]}), "  ";
				}
			}
			print "\n";
		}
		print "\n";
	}
}

# render_to_pbm(buffer, width, path [, hint])
#
# Prints a buffer from rasterize()/encode() in PBM format to a file at the given path.
#
# "width" is the maximum number of characters found in a line of buffer.
#
# An optional hint buffer can be supplied.
sub render_to_pbm
{
	my $buffer = shift;
	my $xchars = shift;
	my $ychars = scalar(@$buffer); # number of text lines
	my $filename = shift;
	my $hint = shift; # = undef if no hint

	# font size in pixels is N x N
	my $fontN = scalar(@{$buffer->[0]->[0]});
	die unless $fontN == scalar(@{$buffer->[0]->[0]->[0]}); # square font support only for now

	my $xypixel = 7; # width/height of pixel square
	my $xyborder = 1; # width/height of pixel border line
	my $char_margin = 10; # spacing between chars (not counting border, pixel square only), also used all the way around image
	my $img_margin = 20; # extra margin added around whole image

	my $xybit = $xypixel+$xyborder; # pixels per bit, including right/bottom border
	my $xych = $xybit*$fontN - $xyborder + $char_margin; # pixels per char, including right/bottom margin
	my $hintY = $hint? scalar(@$hint) + $char_margin: 0; # extra height added (in pixels) due to any hint

	# dimensions of complete image:
	my $_X = $img_margin          + $char_margin + $xchars * $xych          + $img_margin;
	my $_Y = $img_margin + $hintY + $char_margin + $ychars * $xych + $hintY + $img_margin;

	# make it square:
	my $X = max($_X, $_Y);
	my $Y = max($_X, $_Y);

	my $bitmap = init_bitmap($X, $Y);

	# top-left origin for first char of first line:
	my $x0 = int( ( $X - ($xchars*$xych-$char_margin) ) / 2 );
	my $y0 = int( ( $Y - $_Y ) / 2 ) + $img_margin + $hintY + $char_margin;

	# render bits
	for my $line_ (0..$#{$buffer}) {
		for my $char_ (0..$#{$buffer->[$line_]}) {
			next unless defined $buffer->[$line_]->[$char_]; # do nothing for space characters
			for my $scan_ (0..$#{$buffer->[$line_]->[$char_]}) {
				for my $pixel_ (0..$#{$buffer->[$line_]->[$char_]->[$scan_]}) {
					# draw pixel
					if ($buffer->[$line_]->[$char_]->[$scan_]->[$pixel_] ne ' ') {
						for my $x (0..$xypixel-1) {
							for my $y (0..$xypixel-1) {
								$bitmap->[$y0+$line_*$xych+$scan_*$xybit+$y]->[$x0+$char_*$xych+$pixel_*$xybit+$x] = 1;
							}
						}
					}
					# draw border around pixel
					for my $x (-1..$xypixel) {
						$bitmap->[$y0+$line_*$xych+$scan_*$xybit-1       ]->[$x0+$char_*$xych+$pixel_*$xybit+$x] = 1; #top
						$bitmap->[$y0+$line_*$xych+$scan_*$xybit+$xypixel]->[$x0+$char_*$xych+$pixel_*$xybit+$x] = 1; #bottom
					}
					for my $y (-1..$xypixel) {
						$bitmap->[$y0+$line_*$xych+$scan_*$xybit+$y]->[$x0+$char_*$xych+$pixel_*$xybit-1       ] = 1; #left
						$bitmap->[$y0+$line_*$xych+$scan_*$xybit+$y]->[$x0+$char_*$xych+$pixel_*$xybit+$xypixel] = 1; #right
					}
				}
			}
		}
	}
	# add hint
	if ($hint) {
		$x0 = int( ( $X - scalar(@{$hint->[0]}) ) / 2 ); # top-left origin for first bit of hint
		$y0 += $ychars * $xych;
		for my $y (0..$#{$hint}) {
			for my $x (0..$#{$hint->[$y]}) {
				$bitmap->[$y0+$y]->[$x0+$x] = $hint->[$y]->[$x];
			}
		}
	}
	# write to file
	open OUT, ">$filename" or die;
	print OUT "P1\n"; # 1 bit per pixel
	print OUT "$X $Y\n"; # N x N pixels
	for my $row (@$bitmap) {
		print OUT join(" ", map { $_? '1':'0' } @$row), "\n";
	}
	close OUT;
}

# init_bitmap(x, y)
#
# Return a bitmap of the given dimensions with all pixels cleared, e.g.
#   [ [ 0, 0, 0, ... ], ... ]
sub init_bitmap
{
	my $x = shift;
	my $y = shift;
	my $bitmap = [];
	for (1..$y) {
		my @raster = (0) x $x;
		push @$bitmap, \@raster;
	}
	return $bitmap;
}

sub max
{
	my $a = shift;
	my $b = shift;
	return $a > $b? $a : $b;
}
