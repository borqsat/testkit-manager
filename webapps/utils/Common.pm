# Copyright (C) 2012 Intel Corporation
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
#
# Authors:
#              Zhang, Huihui <huihuix.zhang@intel.com>
#              Wendong,Sui  <weidongx.sun@intel.com>

package Common;
use strict;
use Fcntl qw/:flock :seek/;
use FindBin;
use Error;

# Export symbols
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
	DEBUG
	$MTK_BRANCH $MTK_VERSION $PUBLIC_VERSION
	$RESULTS_DIR
	$STATUS_FILE  $DEFAULT_TEMP_DIR
	$DEFAULT_STANDARD_VER
        $TESTKIT_ROOT
	&append_string_to_file &cache_dest &shq
	&create_empty_directory &does_shell_know &extract_dir &extract_filename
	&format_duration &format_time &guess_architecture &glob_hash
	&in_array &sort_cat &copy &merge_hash &read_file &write_string_as_file
	&read_config &read_config_simple
	&is_process_running &file_info
	&detect_architecture &backward_compatible_platforms
	&detect_OS 
	@all_archs
	$last_cmd_output &last_line
	&complain &debug_inform &fail &inform &warning &capture &cmd
	&sleep_ms &check_sdb_device &sdb_cmd &get_serial &set_serial &get_config_info
	&shell_cmd
);

push @EXPORT, @Error::EXPORT;

#----------------------------------------------------------------------

use constant DEBUG => 0; # DBG: Whether debug mode is enabled

$Error::Debug = 1 if DEBUG;
our $last_cmd_output = "";

our @all_archs = qw( x86  x86-64  IA64  PPC32  PPC64  S390  S390X );

our $STATUS_FILE = 'test_status';

use File::Spec;
use File::Basename;

sub location  {
   return File::Spec->rel2abs( __FILE__);
}
our $TESTKIT_ROOT = dirname(location())."/../../"; 

our $DEFAULT_TEMP_DIR = $TESTKIT_ROOT."/tmp"; 

# ---------------------------------------------------------------------

my $configuration_file = $TESTKIT_ROOT . "/CONF";

sub check_sdb_device {
	my @device     = `sdb devices`;
	my @sdb_serial = ();
	foreach (@device) {
		my $device = $_;
		if ( ( $device =~ /(.*?)\sdevice/ ) && ( $device !~ /List of/ ) ) {
			my $sdb_serial = $1;
			push( @sdb_serial, $sdb_serial );
		}
	}
	return @sdb_serial;
}

sub sdb_cmd {
	my ($cmd_content) = @_;
	my $sdb_serial    = get_serial();
	my $whole_cmd     = "";
	if ( ( $sdb_serial eq "none" ) or ( $sdb_serial eq "Error" ) ) {
		$whole_cmd = "sdb " . $cmd_content;
	}
	else {
		$whole_cmd = "sdb -s " . $sdb_serial . " " . $cmd_content;
	}
	return $whole_cmd;
}
sub shell_cmd {
	my $sdb_serial    = get_serial();
	my $whole_cmd     = "";
	if ( ( $sdb_serial eq "none" ) or ( $sdb_serial eq "Error" ) ) {
		$whole_cmd = "";
	}
	else {
		$whole_cmd = " --deviceid " . $sdb_serial;
	}
	return $whole_cmd;
}

sub get_serial {
	my $sdb_serial = "none";
	open FILE, $configuration_file or die $!;
	while (<FILE>) {
		if ( $_ =~ /^sdb_serial/ ) {
			$sdb_serial = $_;
			last;
		}
	}
	close(FILE);
	if ( $sdb_serial eq "none" ) {
		return "Error";
	}
	else {
		$sdb_serial =~ s/^\s*//;
		$sdb_serial =~ s/\s*$//;
		my @serial = split( "=", $sdb_serial );
		my $serial_number = "";
		if ( defined $serial[1] ) {
			$serial_number = $serial[1];
			$serial_number =~ s/^\s*//;
			$serial_number =~ s/\s*$//;
		}
		if ( $serial_number eq "" ) {
			$serial_number = "none";
		}
		return $serial_number;
	}
}

sub set_serial {
	my ($serial)    = @_;
	my $sdb_serial  = "none";
	my $line_number = 0;
	open FILE, $configuration_file or die $!;
	while (<FILE>) {
		$line_number++;
		if ( $_ =~ /^sdb_serial/ ) {
			$sdb_serial = $_;
			last;
		}
	}
	close(FILE);
	if ( $sdb_serial eq "none" ) {
		return "Error";
	}
	else {
		system( "sed -i '$line_number"
			  . "c sdb_serial = $serial' $configuration_file" );
		return "OK";
	}
}

sub get_config_info {
	my ($key) = @_;
	my $config_line = "none";
	open FILE, $configuration_file or die $!;
	while (<FILE>) {
		if ( $_ =~ /^$key/ ) {
			$config_line = $_;
			last;
		}
	}
	close(FILE);
	if ( $config_line eq "none" ) {
		return "Error";
	}
	else {
		$config_line =~ s/^\s*//;
		$config_line =~ s/\s*$//;
		my @config_info = split( "=", $config_line );
		my $config_value = "";
		if ( defined $config_info[1] ) {
			$config_value = $config_info[1];
			$config_value =~ s/^\s*//;
			$config_value =~ s/\s*$//;
		}
		if ( $config_value eq "" ) {
			$config_value = "none";
		}
		return $config_value;
	}
}

# ---------------------------------------------------------------------

our $MTK_VERSION;
our $PUBLIC_VERSION = "none";
our $MTK_BRANCH; # "MeeGo"
{
	# Look for $MTK_VERSION and $MTK_BRANCH in the utils/VERSION file
	(my $file_path = __FILE__) =~ s/\/?[^\/]*$//; # get path to this file
	if ( open my $FILE, $file_path."/VERSION" ) {
		if ( defined( local $_ = <$FILE> ) ) { # read first line
			chomp;
			($MTK_VERSION, $MTK_BRANCH) = split /:/;
		}
		if ( defined( local $_ = <$FILE> ) ) { # Read second line
			chomp;
			my @temp = split /:/;
			$PUBLIC_VERSION = $temp[1];
		}
		close $FILE;
	}
}
$MTK_BRANCH = "MeeGo" if !$MTK_BRANCH;
$MTK_VERSION = "" if ( !$MTK_VERSION or $MTK_VERSION !~ /^\d/ ); # Version should start with digit
our $RESULTS_DIR     = $TESTKIT_ROOT."/results"; # Cache directory for downloaded packages and test data files

#jenny add for DEFAULLT_STANDARD_VER, need to update with real MTK_BRANCH
our $DEFAULT_STANDARD_VER = ($MTK_BRANCH eq "MeeGo" ? "MeeGo 2.0" : "MeeGo 2.1");

#----------------------------------------------------------------------

# Print error message.
# If $err is an error object, then it is printed.
# If $err is a string, then an error($err, @params) is created, then printed.
# Returns the error object.
our $complain_sub = sub {
	my ($err, @params) = @_;
	
	( defined $err ) or $err = "";
	
	if ( !is_err_obj($err) ) {
		local $Error::Depth = $Error::Depth + 1;
		$err = error($err, @params);
	}
	
	print STDERR "\nError:\n".$err->tostring()."\n";
	
	return $err;
};
sub complain { goto &$complain_sub }

# Like complain(), but prints the 'Warning' word instead of 'Error'.
our $warning_sub = sub {
	my ($err, @params) = @_;
	
	( defined $err ) or $err = "";
	
	if ( !is_err_obj($err) ) {
		local $Error::Depth = $Error::Depth + 1;
		$err = error($err, @params);
	}
	
	print STDERR "\nWarning:\n".$err->tostring()."\n";
	
	return $err;
};
sub warning { goto &$warning_sub; }

# Prints error message like complain(), then exits.
our $fail_sub = sub { 
	my (@params) = @_;
	
	local $Error::Depth = $Error::Depth + 1;
	complain(@params) if @params;
	
	inform("Failed.");
	
	exit 1;
};
sub fail { goto &$fail_sub }
#----------------------------------------------------------------------

# Print message and a linefeed.
our $inform_sub = sub {
	print "$_[0]\n";
};
sub inform { goto &$inform_sub; }

# Print message only if DEBUG mode is ON.
our $debug_inform_sub = sub {
	print "$_[0]\n" if DEBUG;
};
sub debug_inform { goto &$debug_inform_sub; }
#----------------------------------------------------------------------

# Returns the output of the given command.
our $capture_sub = sub {
	my ($command) = @_;
	
	$command = "( ".$command." ) 2>&1";
	
	return `$command`;
};
sub capture { goto &$capture_sub; }

# Return the exit code of the given command.
# Save the command output to $last_cmd_output.
our $cmd_sub = sub {
	my ($command) = @_;
	
	$last_cmd_output = "%> ".$command;
	
	my $resp = capture ( $command );
	if ( is_err $resp ) { complain $Error::Last; return 256; }
	
	$last_cmd_output .= "\n".$resp if $resp ne "";
	
	return $?;
};
sub cmd { goto &$cmd_sub; }
#----------------------------------------------------------------------

# Checks whether $needle is present in array.
# Returns position of $needle in array, starting from 1.
# 0 is returned if there is no such element in the array.
sub in_array {
	my $needle = shift;
	
	( defined $needle )
		or return error("in_array(undef, ...)");
	
	for ( my $i = 0; $i < @_; $i++ ) {
		next if !defined $_[$i];
		return ($i+1) if $_[$i] eq $needle;
	}
	return 0;
}
#----------------------------------------------------------------------

# Compare function for extended sorting.
# Usage: sort {sort_cat($a, $b, \@arr);} @to_sort
# Places elements present in @arr at the beginning (in the same order as in @arr), then - all the rest (alphabetically).
# Example: sort {sort_cat($a, $b, ['y', 'w', 'x']);} ('a', 'x', 'y', 'z') == ('y', 'x', 'a', 'z')
sub sort_cat($$$) {
	my ($a, $b, $arr) = @_;
	my $ai = in_array($a, @$arr);
	my $bi = in_array($b, @$arr);
	return $ai <=> $bi if ($ai && $bi);
	return $a cmp $b   if (!$ai && !$bi);
	return 1           if !$ai;
	return -1          if !$bi;
}
#----------------------------------------------------------------------

sub shq {
	my ($s) = @_;
	$s =~ s/'/'\''/g; # escape quotes. foo'bar -> 'foo'\''bar'
	return "'$s'";
}

# Read and return the file contents
sub read_file {
	my ($filename) = @_;
	
	my $to_lock = 0;
	if ( $filename =~ s/^!// ) {
		$to_lock = 1;
	}
	
	my $text = undef;
	my $file;
	
	open $file, $filename
		or return error("Can't open file for read '$filename': $!");
		
	$to_lock && flock($file, LOCK_SH);
	{
		local $/ = undef;
		$text = <$file>;
	}
	$to_lock && flock($file, LOCK_UN);
	close $file;
	
	( defined $text ) or return error("Can't read file '$filename': $!");
	
	return $text;
}
#---------------------------------------------------------------------

# Extracts filename from a full name
sub extract_filename {
	my ($fullname) = @_;
	
	( defined $fullname ) or return error("undefined argument");
	
	if ( $fullname =~ m/([^\/]+)$/ ) {
		return $1;
	}
	return $fullname;
}
#---------------------------------------------------------------------

# Extracts directory name (with a trailing slash)
sub extract_dir {
	my ($fullname) = @_;
	
	( defined $fullname ) or return error("undefined argument");
	
	my $dir = $fullname;
	
	$dir =~ s{/+[^/]*$}{}; # Remove everything after the last /

	return $dir;
}
#---------------------------------------------------------------------

# Returns size and mtime of the $file.
# Returns (undef,undef) if error.
sub file_info {
	my ($file) = @_;
	
	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime) = stat($file);
	
	return ($size, $mtime);
}
#---------------------------------------------------------------------

# Write the specified string to the specified file, removing the original
# contents of the file (if any).
sub write_string_as_file {
	my ($file_name, $content) = @_;
	
	( defined $file_name && defined $content )
		or return error("undefined argument");

	# "!" at the beginning of the filename means that flock is required.
	my $to_lock = 0;
	if ( $file_name =~ s/^!// ) {
		$to_lock = 1;
	}

	if ( !$to_lock ) {
		my $file;
		open $file, ">".$file_name
			or return error("Failed to open file '$file_name' for writing: $!");
		print {$file} $content;
		close $file;
	}
	else {
		my $file;
		open $file, "+>>".$file_name
			or return error("Failed to open file '$file_name' for writing: $!");
		flock($file, LOCK_EX);
		seek($file, 0, SEEK_SET);
		truncate($file, 0);

		# Print the string and close the file.
		print {$file} $content;

		flock($file, LOCK_UN);
		close $file;
	}

	return 1; # OK
}
#---------------------------------------------------------------------

# Appends the string to the file.
sub append_string_to_file {
	my ($file_name, $content) = @_;

	( defined $file_name && defined $content )
		or return error("undefined argument");
	
	my $to_lock = 0;
	if ( $file_name =~ s/^!// ) {
		$to_lock = 1;
	}
	
	my $file;
	
	# Open the file for appending.
	open $file, ">>".$file_name
		or return error("Failed to open file '$file_name' for appending: $!");
	
	if ( $to_lock ) {
		flock($file, LOCK_EX);
		seek($file, 0, SEEK_END);
	}
	
	# Print the string and close the file.
	print {$file} $content;
	
	if ( $to_lock ) {
		flock($file, LOCK_UN);
	}
	close $file;
	
	return 1; # OK
}
#---------------------------------------------------------------------

# Creates the specified directory, or removes and re-creates it
# if the directory already exists.
sub create_empty_directory {
	my ($dir_name) = @_;

	( defined $dir_name )
		or return error("undefined argument");

	# If the directory already exists then delete it with all contents
	# and re-create to ensure it is empty and with standard access rights.
	if ( -d $dir_name ) {
		system("rm -rf ".shq($dir_name)." >/dev/null 2>&1") == 0 
			or return error("Failed to delete '$dir_name'.");
	}

	# Create the directory.
	my $res = system( "mkdir -p ".shq($dir_name) );
	if ( $res != 0 || !-d $dir_name ) {
		return error("Failed to create '$dir_name'.");
	}
	return 1; # OK
}
#---------------------------------------------------------------------

# Checks whether the specified tool is known to the shell.
sub does_shell_know ($) {
	my ($tool_name) = @_;
	
	( defined $tool_name ) or return error("undefined argument");
	
	return ( system ("which ".shq($tool_name)." >/dev/null 2>&1") == 0 );
}
#---------------------------------------------------------------------

# Returns time in format "HH:MM:SS dd-mm-yyyy"
sub format_time {
	my ($timestamp) = @_;
	
	( defined $timestamp ) or return error("undefined argument");
	
	( $timestamp eq int($timestamp) )
		or return error("parameter isn't numeric: '$timestamp'");
	
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime ($timestamp);

	return sprintf ('%02d:%02d:%02d %02d-%02d-%04d', $hour, $min, $sec,
			$mday, ($mon + 1), ($year + 1900) );
}
#----------------------------------------------------------------------

# Format time interval in form "HH hours, MM minutes, SS seconds"
sub format_duration {
	my ($time) = @_;
	
	( defined $time ) or return error("undefined argument");
	
	$time = int($time);
	
	my $seconds = $time % 60;
	my $tmp = int($time / 60);
	my $minutes = $tmp % 60;
	my $hours = int($tmp / 60);
	
	my $res = "";
	
	$res .= sprintf '%d hours, ', $hours if $time >= 3600;
	$res .= sprintf '%02d minutes, ', $minutes if $time >= 60;
	$res .= sprintf '%02d seconds', $seconds;
	
	return $res;
}
#----------------------------------------------------------------------

# Returns element of a hash or a value by key '*'.
sub glob_hash {
	my ($hashref, @keys) = @_;

	return $hashref if !@keys;
	return undef if !defined $hashref;
	
	( ref($hashref) eq 'HASH' )
		or return error("HASHREF is expected as the first argument");

	my $key = shift @keys;
	if ( defined $hashref->{$key} ) {
		return glob_hash( $hashref->{$key}, @keys );
	}
	elsif ( defined $hashref->{'*'} ) {
		return glob_hash( $hashref->{'*'} );
	}
	# else
	return undef;
}
#----------------------------------------------------------------------

sub copy {
	my ($a, %opts) = @_;
	
	my $ref = ref($a);
	
	if ( $ref eq '' ) {
		return $a;
	}
	elsif ( $ref eq 'ARRAY' ) {
		return [ map {copy($_, %opts)} @$ref ]; # recursion!
	}
	elsif ( $ref eq 'HASH' ) {
		my $h = {};
		return merge_hash($h, $a, %opts); # indirect recursion!
	}
	else {
		warning "Don't know what to do with '$ref' ('$_')";
	}
}

# Merges the $h2 hash INTO the $h1
sub merge_hash {
	my ($h1, $h2, %opts) = @_;
	
	( ref $h1 eq 'HASH' ) or return error("argument1 is not a hash ref");
	( ref $h2 eq 'HASH' ) or return error("argument2 is not a hash ref");
	
	local $_;
	
	foreach ( keys %$h2 ) {
		if ( !defined $h1->{$_} ) {
			$h1->{$_} = $h2->{$_};
			next;
		}
		
		( ref($h1->{$_}) eq ref($h2->{$_}) )
			or return error("incongruent hashes: '$_'");
		
		my $ref = ref($h1->{$_});
		
		if ( $ref eq "HASH" ) {
			is_ok merge_hash( $h1->{$_}, $h2->{$_}, %opts ) # recursion
				or return $Error::Last;
		}
		elsif ( $ref eq "ARRAY" ) {
			if ( $opts{'overwrite_array'} ) {
				$h1->{$_} = [ map {copy($_, %opts)} @{$h2->{$_}} ];
			} else {
				# default: join arrays
				push @{$h1->{$_}}, @{$h2->{$_}};
			}
		}
		elsif ( $ref eq "" ) { # SCALAR
			next if $h1->{$_} eq $h2->{$_};
			if ( $opts{'overwrite_scalar'} ) {
				$h1->{$_} = $h2->{$_};
			} else {
				return error("Scalar conflict: '$_': '$h1->{$_}' != '$h2->{$_}'");
			}
			
		}
		else {
			warning "Don't know what to do with '$ref' ('$_')";
		}
	}
	return $h1;
}
#----------------------------------------------------------------------

# Helps to determine an architecture name.
sub guess_architecture {
	my ($name, $noarch_label) = @_;
	
	return "x86"    if ( $name =~ /^(x86|ia32|i[3-6]86)$/ );
	return "x86-64" if ( $name =~ /^(amd64|x86_64|x86-64)$/);
	return "IA64"   if ( $name =~ /^(ia64)$/ );
	return "PPC32"  if ( $name =~ /^(ppc|powerpc|ppc32)$/ );
	return "PPC64"  if ( $name =~ /^(ppc64)$/ );
	return "S390"   if ( $name =~ /^(s390)$/ );
	return "S390X"  if ( $name =~ /^(s390x)$/ );
	
	if ( $noarch_label ) {
		return $noarch_label if ( $name =~ /^(noarch|all)$/ );
	}
	
	# else
	return undef;
}
#------------------------------------------------------------------------

# Detect the architecture name
sub detect_architecture {
	# If uname utility supports -i options then use it
	# Check if `uname' has -i option
	if ( system ("uname --help 2>&1 | grep -- ' -i\\b' >/dev/null") == 0 ) { 
		my $tmp = `uname -i`;
		chomp $tmp;
		my $res = guess_architecture( $tmp );
		if ( $res ) { return $res; }
	}
	# else:
	
	# Try to find out the host architecture using the machine type.
	my $tmp = `uname -m`;
	chomp $tmp;
	my $res = guess_architecture( $tmp );
	if ( $res ) { return $res; }
	
	return undef;
}

#------------------------------------------------------------------------

# Returns list of compatible architectures.
sub backward_compatible_platforms {
	my $arch = shift;

	if ( $arch eq "x86-64" ) {
		return ("x86", "x86-64");
	}
	elsif ( $arch eq "IA64" ) {
		return ("x86", "IA64");
	}
	elsif ( $arch eq "PPC64" ) {
		return ("PPC32", "PPC64");
	}
	elsif ( $arch eq "S390X" ) {
		return ("S390", "S390X");
	}
	# else: return itself
	return ($arch);
}

#------------------------------------------------------------------------

sub detect_OS {
	if ( does_shell_know('lsb_release') ) {
		# The OS version is determined via the lsb_release tool
		# (this should be a canonical, distro independent way).
		my $res = `lsb_release -s -d`;
		chomp $res;
		$res =~ s/^\s*\"(.*)\"\s*$/$1/;  # remove quotes if any
		return $res;
	}
	else {
		my $res = read_file("/etc/issue");
		if ( !is_ok($res) ) { $res = ""; }
		$res =~ s/\n.*//s; # leave only the first line
		return $res;
	}
	return "";
}

#------------------------------------------------------------------------
sub read_config_simple {
	my ($filename) = @_;
	
	my $res = {};
        my $values = "";	
	# TODO: use read_file to be able to lock the file
	open FILE, $filename
		or return error("Failed to open testinfo file '$filename': $!");
	
	my $section;
	while ( my $line = <FILE> ) {
		chomp $line; 
		$line =~ s/^\s+//;
		$line =~ s/\s+$//; # Remove spaces
		
		next if !$line;  # Skip empty lines
		next if $line =~ /^#/;  # Skip comments
		
		if ( $line =~ /^\[([^\]]+)\]$/  ) {
                        my $secname = $1;
                        if(defined $section){
                             if(!($section =~ /^$/ )){
                             $res->{$section} = $values;
                             $section = "";
                             $values = ""; 
                            }
                        } 
			$section = $secname;
			next;
		}
		else {
			my $value = $line;
			
			$value =~ s/\x81/\n/g;
			
			if ( !defined $section ) {	
                                next;
			}
			else {
                                if($values eq ""){
                                    $values = $value;
                                }else{
                                    $values = $values."\n".$value;
                                }
			}
		}
		
	}

	if(defined $section){
               if( !($section =~ /^$/) ){
                  $res->{$section} = $values;
               }
        } 
	
	close FILE;
	
	return $res;
}

sub read_config {
	my ($filename) = @_;
	
	my $res = {};
	
	# TODO: use read_file to be able to lock the file
	open FILE, $filename
		or return error("Failed to open testinfo file '$filename': $!");
	
	my $section = undef;
	while ( my $line = <FILE> ) {
		chomp $line; 
		$line =~ s/^\s+//;
		$line =~ s/\s+$//; # Remove spaces
		
		next if !$line;  # Skip empty lines
		next if $line =~ /^#/;  # Skip comments
		
		if ( $line =~ /^\[([^\]]+)\]$/  ) {
			$section = $1;
			next;
		}
		elsif ( $line =~ /([^:=\s]+)\s*[:=\s]\s*(.*)/ ) {
			my $name = $1;
			my $value = $2;
			
			$value =~ s/\x81/\n/g;
			
			if ( !defined $section ) {	
				$res->{$name} = $value;
			}
			else {
				$res->{SECTIONS}{$section}->{$name} = $value;
			}
		}
		else {
			warning "Cant parse line $. in file '$filename': '$line'";
		}
	}
	
	close FILE;
	
	return $res;
}
#----------------------------------------------------------------------

sub is_process_running($;$) {
	my ($PID, $procname) = @_;
	# -e : check whether the file_name (/proc/$PID) already has been used.
	if (!-e "/proc/$PID") {
		return 0;
	}
	open(FILE, "/proc/$PID/stat") or return 0;
	my $info = <FILE>;
	close(FILE);
	if ($info =~ m/^\d+\s+\((.*)\)\s+(\S)\s+[^\(\)]+$/) {
		my $running = 1;
		if ($procname) {
			$running &&= ($1 eq $procname);
		}
		return ($running and ($2 ne 'Z'));
	}
	else {
		return 0;
	}
}
#----------------------------------------------------------------------

sub last_line {
	my ($text) = @_;
	
	$text =~ s/[\n\r]+$//;
	
	$text =~ s/.*[\n\r]//sg;
	return $text;
}

#----------------------------------------------------------------------

# Sleep $delay milliseconds
sub sleep_ms {
	my ($delay) = @_;
	
	select undef, undef, undef, $delay;
}
#----------------------------------------------------------------------


1; #return value
