#!/usr/bin/perl -w
#
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

use strict;
use IO::Handle;    # for autoflush();
use FindBin;
use File::Basename qw(dirname basename);

my $profile_name       = "";    # profile name of this execution
my $profile_content    = "";    # the actual name and filter of the profile
my $current_package    = "";    # package name of current run
my $current_run_number = 0;     # how many cases has run for the running pacakge
my $deviceid    = ""; 

sub BEGIN {

	# Add current directory to the @INC to be able to include modules
	# from the same directory where this script is located.
	unshift @INC, $FindBin::Bin;

	$| = 1;                     # Immediate flush of all output

	# Certain utilities used for system administration (and other privileged
	# commands) may be stored in /sbin, /usr/sbin, and /usr/local/sbin.
	# Applications requiring to use commands identified as system
	# administration utilities should add these directories to their PATH.
	$ENV{PATH} .= ":/sbin:/usr/sbin";
	$ENV{TESTKIT_ROOT} .= $FindBin::Bin . "/../../";
}
use Common;
use Error;
use Misc;
Misc::Init();
use Subshell;
use TestLog;

my $isOnlyAuto = "FALSE";

#----------------------------------------------------------------------------

$SIG{__WARN__} = sub {
	die "Error: Compilation error: " . $_[0]
	  if !defined $^S
		  && $_[0] !~ /^Error: Compilation error: /;    # Compilation error

	local $Error::Depth = $Error::Depth + 1;
	local $Error::Debug = 0;
	warning $_[0];
};

$SIG{__DIE__} = sub {
	die @_ if $^S;    # Do nothing if called inside eval{ }
	die "Error: Compilation error: " . $_[0]
	  if !defined $^S
		  && $_[0] !~ /^Error: Compilation error: /;    # Compilation error

	local $Error::Depth = $Error::Depth + 1;
	local $Error::Debug = 0;
	fail "Died. " . $_[0];
};

my $need_cleanup = 0;
my $isWebApi     = "False";

my $_END = sub {
	print_stderr "Finished.\n" if $globals->{'webui'};
	$globals->{'finish_time'} = time();

	if ( !defined $globals->{'not-run'} && defined $globals->{'result_dir'} ) {
		my $status_summary = "NotFinished";
		if ( defined $globals->{'testkitdone'}
			&& $globals->{'testkitdone'} eq "Finished" )
		{
			$status_summary = "Finished";
		}
		$status_summary = "Auto: $status_summary\n";
		write_string_as_file( $globals->{'result_dir'} . "/test_status",
			$status_summary );
	}
	inform "Finished.";
};

#----------------------------------------------------------------------------

#=============================================================================
# Subroutines of the main script
#=============================================================================

# Prints a short help text.
sub print_help {

	my $text = <<DATA;
 Usage: $0 [OPTIONS]
 Runs tests and produces HTML report.

 Options:

  -h,--help                  Show this help and exit.
  -f,--profile <file>        Take settings from <file>.
  -u,--userprofile <file>    User profile from <file>
  --report <result dir>      Build report for results in directory <result dir>.
  --not-run                  Do some initialization, then exit (for debug).
  -m,--mail-to <email>      Send test results to e-mail.
  -t,--testrun_id <name>     Use <name> as a result subdirectory name.
DATA

	print $text;
}

#read the command line parameters.
sub get_options {
	my @args = @ARGV;
	if ( @args < 1 ) {
		print "Please run $0 --help for information about usage.\n";
		exit 0;
	}

	my $params = [];
	push @$params, { LONG_NAME => 'help', SHORT_NAME => 'h' };
	push @$params,
	  { LONG_NAME => 'profile', SHORT_NAME => 'f', HAS_VALUE => 1 };
	push @$params,
	  { LONG_NAME => 'userprofile', SHORT_NAME => 'u', HAS_VALUE => 1 };
	push @$params, { LONG_NAME => 'report', HAS_VALUE => 1 };
	push @$params,
	  { LONG_NAME => 'testrun_id', SHORT_NAME => 't', HAS_VALUE => 1 };
	push @$params, { LONG_NAME => 'not-run' };
	push @$params,
	  { LONG_NAME => 'mail-to', SHORT_NAME => 'm', HAS_VALUE => 1 };
	push @$params, { LONG_NAME => 'webui', SHORT_NAME => 'w' };   # Internal use

	my $options = {};

	while (@args) {
		my $arg = shift @args;
		if ( $arg =~ /^-/ ) {
			my $found = 0;
			foreach my $opt (@$params) {
				my $long_name  = $opt->{'LONG_NAME'};
				my $short_name = $opt->{'SHORT_NAME'};
				my $value      = undef;

				if ( $long_name && $arg =~ m/^--\Q$long_name\E=(.+)$/ ) {
					$value = $1;
				}
				elsif ( $short_name && $arg =~ m/^-\Q$short_name\E(.+)$/ ) {
					$value = $1;
				}
				elsif ( $long_name && $arg =~ m/^--\Q$long_name\E$/ ) {

					# OK
				}
				elsif ( $short_name && $arg =~ m/^-\Q$short_name\E$/ ) {

					# OK
				}
				else {
					next;
				}

				if ( !defined $value ) {
					if ( $opt->{HAS_VALUE} ) {
						$value = shift @args;
						( defined $value )
						  or return error
						  "Option $arg must be followed by a value";
					}
					else {
						$value = 1;
					}
				}

				my $result_name = ( $long_name or $short_name );

				$options->{$result_name} = $value;
				$found = 1;
				last;
			}
			if ( !$found ) {
				fail "Unexpected parameter: '$arg'";
			}
		}
		else {

			# this is not a parameter, so it's probably a test name
			push @{ $options->{TESTS} }, $arg;
		}
	}
	return $options;
}

#Fetch the parameters from HTTP request, and save into a hash 'options'
#Read some running setting, such as the email addr, PID, and start_time, and saving into a hash 'globals'
sub Setup {

	inform "Initialization...";

	# Default report name
	$globals->{'report'}   = "report.htm";
	$globals->{'temp_dir'} = $DEFAULT_TEMP_DIR;

	my $options = get_options();

	is_ok($options) or fail "Error in command line parameters", $Error::Last;
	$globals->{'not-run'} = $options->{'not-run'};

	host_check_and_info();    # get the host info

	#if report name is specified

	if ( $globals->{'not-run'} && $options->{'report'} ) {

		#use the specified report name if needed
		$globals->{'report'} = $options->{'report'};

		if ( $options->{'testrun_id'} ) {
			rebuild_report( $options->{'report'},
				$RESULTS_DIR . "/" . $options->{'testrun_id'},
				$options->{'profile'} );
		}
		else {
			warning "No reporting since testrun_id is not specified!\n";
		}
	}
	else {
		if ( $options->{'report'} ) {
			$globals->{'report'} = $options->{'report'};
		}
	}

	if ( $globals->{'not-run'} && $options->{'mail-to'} ) {

		#Create tar ball
		if ( $options->{'testrun_id'} ) {
			$globals->{'results_tarball'} =
			  $RESULTS_DIR . "/" . $options->{'testrun_id'} . ".tgz";

			my $tmp_file =
			  $globals->{'temp_dir'} . "/"
			  . extract_filename( $globals->{'results_tarball'} );

			cmd(
				    "cd "
				  . extract_dir( $RESULTS_DIR . "/" . $options->{'testrun_id'} )
				  . " && tar czf "
				  . $tmp_file . " "
				  . extract_filename(
					$RESULTS_DIR . "/" . $options->{'testrun_id'}
				  )
				  . " && mv "
				  . $tmp_file . " "
				  . $globals->{'results_tarball'}
			);

			#Send mail
			$globals->{'mailto'} = $options->{'mail-to'};

			if ( $globals->{'mailto'} ) {

				# Send results by e-mail
				is_ok send_results( $globals->{'results_tarball'} )
				  or complain $Error::Last;
			}
		}
		else {
			warning "No mail is send since testrun_id is not specified!\n";
		}
	}
	else {
		if ( $options->{'mail-to'} ) {
			$globals->{'mailto'} = $options->{'mail-to'};
		}
	}

	if ( $globals->{'not-run'} ) { exit 0; }

	# Some global initializations
	# System time
	$globals->{'start_time'} = time();

	# Process ID
	$globals->{'PID'} = $$;

	# Script directory
	$globals->{'script_directory'} = $FindBin::Bin;

	# File with the current status
	$globals->{'status_file'} = $RESULTS_DIR . '/' . $STATUS_FILE;

	# Remove the test_status file before start a new test
	if ( -f $globals->{'status_file'} ) {
		cmd( "rm " . $globals->{'status_file'} ) == 0
		  or warning "can not remove " . $globals->{'status_file'};
	}

	# Default user profile
	$globals->{'userprofile'} =
	  $FindBin::Bin . "/../../plans/user/user.profile";

	# Auto test config under testrun_id folder
	$globals->{'auto_profile'} = "profile.auto";

	# Manual test config under testrun_id folder
	$globals->{'manual_profile'} = "profile.manual";

	# User config under testrun_id folder
	$globals->{'user_profile'} = "profile.user";

	# Have auto test?
	$globals->{'auto'} = 1;

	# Have manula test?
	$globals->{'manual'}      = 1;
	$globals->{'testkit_dir'} = $FindBin::Bin . "/../..";

	if ( $options->{'userprofile'} ) {
		$globals->{'userprofile'} = $options->{'userprofile'};
	}

	if ( $options->{'webui'} ) {
		$globals->{'webui'} = $options->{'webui'};
	}

	if ( $options->{'help'} ) {
		print_help();
		exit 0;
	}

	# Set testrun_id
	if ( !defined $options->{'testrun_id'} ) {
		my ( $sec, $min, $hour, $mday, $mon, $year ) =
		  localtime( $globals->{'start_time'} );
		$globals->{'testrun_id'} =
		    ( defined $host_info->{'hostname'} ? $host_info->{'hostname'} : "" )
		  . '-'
		  . sprintf(
			'%04d-%02d-%02d-%02dh-%02dm-%02ds',
			$year + 1900,
			$mon + 1, $mday, $hour, $min, $sec
		  );
	}
	else {
		$globals->{'testrun_id'} = $options->{'testrun_id'};
	}

	setup_dirs_and_logs();

	# Read the profile and backup them for each session
	if ( $options->{'profile'} ) {
		my $profile_filename = $options->{'profile'};
		$profile_name = $options->{'profile'};

		if ( !defined $profile_filename || !-f $profile_filename ) {
			fail "Wrong profile filename "
			  . (
				defined $profile_filename
				? "'$profile_filename'"
				: "(undefined)"
			  );
		}

		#parse the profile and copy it to testrun_id folder
		my $res = ();
		$res = read_config_simple($profile_filename);

		my $profile_auto   = $res->{'Auto'};
		my $profile_manual = $res->{'Manual'};

		write_string_as_file(
			$globals->{'result_dir'} . "/" . $globals->{'auto_profile'},
			$profile_auto );

#write_string_as_file($globals->{'result_dir'}."/".$globals->{'manual_profile'}, $profile_manual);

		if ( !defined $profile_auto || $profile_auto eq "" ) {
			$globals->{'auto'} = 0;
		}
		else {
			write_string_as_file(
				$globals->{'result_dir'} . "/" . $globals->{'auto_profile'},
				$profile_auto );
		}

		if ( !defined $profile_manual || $profile_manual eq "" ) {
			$globals->{'manual'} = 0;
		}
		else {

#write_string_as_file($globals->{'result_dir'}."/".$globals->{'manual_profile'}, $profile_manual);
		}
		$globals->{'original_profile_path'} = $profile_filename;
	}

	if ( -f $globals->{'userprofile'} ) {
		cmd(    "cp -f "
			  . $globals->{'userprofile'} . " "
			  . $globals->{'result_dir'}
			  . "/profile.user" ) == 0
		  or warning "Failed to copy profile: '"
		  . $globals->{'user_profile'}
		  . "' to '"
		  . $globals->{'result_dir'} . "'";
	}

	if ( -f $globals->{'userprofile'} ) {
		my $emailline = `grep "E-mail:" $globals->{'userprofile'}`;
		if ( $emailline =~ /E-mail:(\s+)(.*)(\s+)/ ) {
			$globals->{'mailto'} = $2;
		}
	}

	# Print some settings
	my $command_line = "$0 @ARGV";
	inform "==========================================";
	inform $MTK_BRANCH. "  v. " . $MTK_VERSION;
	inform format_time( $globals->{'start_time'} );
	inform "Command line: $command_line" if $command_line ne "";
	inform "Script directory is " . $FindBin::Bin;
	inform "Host name: " . $host_info->{'hostname'};
	inform "Host machine: " . $host_info->{'machine'};
	inform "Host architecture: " . $host_info->{'architecture'};
	inform "Host kernel: " . $host_info->{'kernel'};
	inform "Host OS: " . $host_info->{'OS'};
	inform "==========================================";

	inform "Initialization done.";
	inform "Result dir: '" . $globals->{'result_dir'} . "'"
	  if $globals->{'result_dir'};    # The first line in log
}

sub setup_dirs_and_logs {

	inform "Setup folders and logs ...";

	# Default temporary directory
	is_ok create_empty_directory( $globals->{'temp_dir'} )
	  or return error "Failed to create temp dir", $Error::Last;

	if ( !-d $RESULTS_DIR ) {
		is_ok create_empty_directory($RESULTS_DIR)
		  or return error "Failed to create result dir: " . $RESULTS_DIR;
	}

	# Results subdir
	$globals->{'result_dir'} = $RESULTS_DIR . "/" . $globals->{'testrun_id'};
	if ( !-d $globals->{'result_dir'} ) {

		# Create a subdir in the result directory
		mkdir $globals->{'result_dir'}
		  or return error "Failed to create dir '"
		  . $globals->{'result_dir'} . "': $!";
		is_ok append_string_to_file(
			'!' . $RESULTS_DIR . "/HISTORY",
			$globals->{'testrun_id'} . "\n"
		  )    # '!' tells that flock should be used
		  or return error "Failed to write to the HISTORY file", $Error::Last;
	}

	# Setup logs
	is_ok Misc::setup_logging() or return $Error::Last;

	return;
}

sub host_check_and_info {

	# Check for basic utilities we will need.
	#require_tool("uname"); # Included since LSB 1.0

	if ( !defined $host_info->{'OS'} ) {
		$host_info->{'OS'} = detect_OS();
	}

	my $tmp = "";

	if ( !defined $host_info->{'machine'} ) {

		# The machine type and architecture are discovered via uname.
		$tmp = `uname -m`;
		chomp $tmp;
		if ( $tmp ne "" ) {
			$host_info->{'machine'} = $tmp;
		}
		else {
			complain "Failed to recognize the machine type."
			  . "\nUse the --arch option to specify the machine type manually on the command line";
			fail() unless $globals->{'ignore_check'};

			# else
			$host_info->{'machine'} = 'x86';    # fallback
		}
	}

	if ( !defined $host_info->{'hostname'} ) {

		# Get the host name.
		$tmp = `uname -n`;
		chomp $tmp;
		if ( $tmp ne "" ) {
			if ( $tmp eq "(none)" ) {
				$host_info->{'hostname'} = "empty";
			}
			else {
				$host_info->{'hostname'} = $tmp;
			}
		}
		else {
			complain "Failed to obtain the host name."
			  . "\n'uname -n' command should print the host name.";
			fail() unless $globals->{'ignore_check'};

			# else
			$host_info->{'hostname'} = 'undefined';    # fallback
		}
	}

	if ( !defined $host_info->{'architecture'} ) {
		$host_info->{'architecture'} = detect_architecture()
		  or fail "Failed to recognize the machine architecture."
		  . "\nSupported architectures are "
		  . ( join ", ", @all_archs ) . "."
		  . "\nUse the --arch option to specify the architecture manually on the command line"
		  . "\nYou can identify the architecture using the command 'uname -m'.";
	}

	if ( !defined $host_info->{'kernel'} ) {

		# Get the kernel version
		$tmp = `uname -r -v`;
		chomp $tmp;
		$host_info->{'kernel'} = $tmp;
	}

	# Read the /etc/issue file, if present. Sometimes it is the only place
	# where an exact OS version can be found.
	if ( !defined $host_info->{'etc_issue'} && -f "/etc/issue" ) {
		$tmp = read_file("/etc/issue");
		if ( is_ok($tmp) ) {
			$tmp =~ s/\s+$//;    # Remove trailing spaces
			$host_info->{'etc_issue'} = $tmp;
		}
	}

}

# Write the INFO file
sub write_info {
	my $INFO = $_[0];

	$INFO .= "\n";

	is_ok write_string_as_file( $globals->{'result_dir'} . "/INFO", $INFO )
	  or return $Error::Last;

	return;
}

sub write_status {
	my $content = "";

	$content .= "PID = " . $globals->{'PID'} . "\n";
	$content .= "RESULT_DIR = " . $globals->{'testrun_id'} . "\n"
	  if defined $globals->{'testrun_id'};    # undef if --check-only
	$content .= "STATUS = "
	  . ( $globals->{'done'} ? $globals->{'done'} : 'Running' ) . "\n";

	$content .= "CURRENT_TIME = " . time() . "\n";

	$content .= "START_TIME = " . $globals->{'start_time'} . "\n";

	if ( $globals->{'auto'} == 1 ) {

		# Tests to run:
		$content .= "\n[" . "testkit-manager" . "]\n";

		my $status =
		  $globals->{'testkitdone'} ? $globals->{'testkitdone'} : 'Prepare';

# STATUS values: Not started|Preparing|Running|Failed|Warnings|Passed|Incomplete|Skipped|Crashed
		$content .= "STATUS = " . $status . "\n";

		$content .= "START_TIME = " . $globals->{'prepare_time'} . "\n"
		  if defined $globals->{'prepare_time'};
		$content .= "STOP_TIME = " . $globals->{'finish_time'} . "\n"
		  if defined $globals->{'finish_time'};
		$content .= "RUN_TIME = " . $globals->{'run_time'} . "\n"
		  if defined $globals->{'run_time'};
		$content .= "TEST_PLAN = " . $globals->{'test_plan'} . "\n"
		  if defined $globals->{'test_plan'};
		$content .= "CURRENT_PACKAGE = " . $globals->{'current_package'} . "\n"
		  if defined $globals->{'current_package'};
		$content .=
		  "CURRENT_RUN_NUMBER = " . $globals->{'current_run_number'} . "\n"
		  if defined $globals->{'current_run_number'};
		$content .=
		  "COMPLETE_PACKAGE = " . $globals->{'complete_package'} . "\n"
		  if defined $globals->{'complete_package'};
		$content .= "STOP_REASON = " . $globals->{'stop_reason'}
		  if defined $globals->{'stop_reason'};
	}

	return write_string_as_file( '!' . $globals->{'status_file'}, $content );
}

sub Check_subshell_off {
	my ($self) = @_;

	# Check the subshell is closed
	if ( $self->{SUBSHELL} && !$self->{SUBSHELL}{TERMINATED} ) {
		my $pid_info = (
			$self->{SUBSHELL}{PTY_PID}
			? "PTYSHELL: " . $self->{SUBSHELL}{PTY_PID}
			: ""
		  )
		  . (
			$self->{SUBSHELL}{SUB_PID}
			? ", SUBSHELL: " . $self->{SUBSHELL}{SUB_PID}
			: ""
		  );

		inform "Terminating " . $self->name . " (" . $pid_info . ")";
		if ( !is_ok $self->{SUBSHELL}->ExpectLogout(0) ) {
			$self->report_error(
				complain "Attention! Failed to shutdown a subshell."
				  . "\nPlease, check the process list and kill the following processes: "
				  . $pid_info,
				$Error::Last
			);
		}
		else {
			$self->report_error( complain "The test was terminated." );
		}
		$self->state('Crashed');

		# Save the test configuration
		is_ok $self->save_info()
		  or complain "Failed to save the test configuration", $Error::Last;

		return 1;
	}
}

#===========================================================================
# The Main Script
#============================================================================

# Initialization
{
	is_ok Setup()
	  or fail "Initialization failed.", $Error::Last;
	$globals->{'prepare_time'} = time();

	# write test_status file under results
	my $test_plan_name = $profile_name;
	$test_plan_name =~ s/\/.*plans\///;
	$globals->{'test_plan'} = $test_plan_name;
	write_status();

	# indicate the ajax server test is started
	print_stderr "Started.\n" if $globals->{'webui'};

	# write INFO file
	write_info("test enviroment is setup");

	# write log to console
	inform "Setup Done";
}

# Setup interrupt handlers
$SIG{INT} = $SIG{TERM} = sub {
	local $SIG{INT} = local $SIG{TERM} = 'IGNORE';

	$globals->{'done'} = "Terminated";
	write_status();
	inform "Killed";
	print_stderr "Terminated.\n" if $globals->{'webui'};

	fail "Caught a terminate signal!";

};

#stop the running test if captured the Interrupt signal.
$SIG{INT} = sub {
	local $SIG{INT} = 'IGNORE';
	if ( $globals->{'interrupt_request'} ) {    # Ctrl-C pushed twice
		kill 'TERM', $$;    # send the TERM signal to itself.
		return;
	}
	$globals->{'interrupt_request'} = 1;

	inform "Caught an interrupt signal!";

	return
	  if ( defined $globals->{'done'}
		&& $globals->{'done'} eq ""
		&& $globals->{'done'} eq "Finished" );

	# exit subshell
	if ( defined $globals->{'subshell'} ) {
		my $pid_info = (
			$globals->{'subshell'}{PTY_PID}
			? "PTYSHELL: " . $globals->{'subshell'}{PTY_PID}
			: ""
		  )
		  . (
			$globals->{'subshell'}{SUB_PID}
			? ", SUBSHELL: " . $globals->{'subshell'}{SUB_PID}
			: ""
		  );

		print "pid info = $pid_info\n";

		# Force the subshell to be closed
		if ( !is_ok $globals->{'subshell'}->ExpectLogout(0) ) {
			complain "Attention! Failed to shutdown a subshell."
			  . "\nPlease, check the process list and kill the following processes: "
			  . $pid_info;
		}
		else {
			complain "The test was terminated.";
			kill 'TERM', $$;    # send the TERM signal to itself.
		}
	}

	# write status
	$globals->{'done'} = "Terminated";
	write_status();
	inform "Killed";
	print_stderr "Terminated.\n" if $globals->{'webui'};
	return;
};

# Creates and prepares a subshell
sub Spawn_subshell {
	my ( $user, $sslog ) = @_;

	my $sslog_file = $globals->{'result_dir'} . "/" . $sslog;

	my $subshell = Subshell::New();
	is_ok $subshell->LogFile($sslog_file)
	  or return error "Failed to open subshell log file", $Error::Last;

	is_ok $subshell->Spawn("sdb devices")
	  or return error "Failed to spawn a subshell", $Error::Last;

	is_ok $subshell->Spawn(
"export LC_ALL=C; export LC_MESSAGES=C; export LC_COLLATE=C; export LC_CTYPE=C; export LC_MONETARY=C; export LC_NUMERIC=C; export LC_TIME=C;"
	  )    # To avoid messages in local languages
	  or return error "Failed to send command to the started subshell",
	  $Error::Last;

	return $subshell;
}

# send result by mail
sub send_results {
	my ($tarball_file) = @_;

	( $globals->{'mailto'} ) or return error "Mailto parameter isn't defined.";
	($tarball_file) or return error "Results tarball missed";

	#Send the results by e-mail if requested.
	inform "Sending the results by e-mail...\n";

	# Use sendmail utility
	sendmail(
		TO      => $globals->{'mailto'},
		SUBJECT => "MeeGo Testkit test results for " . $host_info->{'hostname'},
		TEXT    => "Please see the attached archive for the test results.",
		ATTACHMENT => $tarball_file,
	);
}

# if no auto test is configured, set auto test status as Finished
{
	if ( $globals->{'auto'} == 0 ) {
		$globals->{'testkitdone'} = "Finished";
		$globals->{'done'}        = "Finished";
		write_status();
		exit 0;
		goto &$_END;
	}
}

# Added by Shao-Feng, for reading the profile.
my @thisTargetPackages;
my @thisTargetFilter;
my @targetFilter;

sub initProfileInfo {
	my $theEnd = "False";

	# change to use our own profile, not the system supplied
	if ( open( FILE, $profile_name ) ) {
		while (<FILE>) {
			my $line = $_;
			$line =~ s/\n//g;
			if ( $line =~ /\[\/Auto\]/ ) {
				$theEnd = "True";
			}
			if ( $theEnd eq "False" ) {
				if ( $line !~ /Auto/ ) {
					$line =~ s/\(\d+ \d+\)//;
					push( @thisTargetPackages, $line );
				}
			}
			if ( $theEnd eq "True" ) {
				if ( $line =~ /select_category=(.*)/ ) {
					if ( $1 ne "Any Category" ) {
						push( @thisTargetFilter, "--category " . $1 );
					}
				}
				if ( $line =~ /select_pri=(.*)/ ) {
					if ( $1 ne "Any Priority" ) {
						push( @thisTargetFilter, "--priority " . $1 );
						push( @targetFilter,     'priority="' . $1 . '"' );
					}
				}
				if ( $line =~ /select_status=(.*)/ ) {
					if ( $1 ne "Any Status" ) {
						push( @thisTargetFilter, "--status " . $1 );
						push( @targetFilter,     'status="' . $1 . '"' );
					}
				}
				if ( $line =~ /select_exe=(.*)/ ) {
					if ( $1 eq "manual" ) {
						push( @thisTargetFilter, "-M" );
					}
					if ( $1 eq "auto" ) {
						$isOnlyAuto = "TRUE";
						push( @thisTargetFilter, "-A" );
					}
				}
				if ( $line =~ /select_testsuite=(.*)/ ) {
					if ( $1 ne "Any Test Suite" ) {
						push( @thisTargetFilter, "--suite " . $1 );
						push( @targetFilter,     'suite name="' . $1 . '"' );
					}
				}
				if ( $line =~ /select_type=(.*)/ ) {
					if ( $1 ne "Any Type" ) {
						push( @thisTargetFilter, "--type " . $1 );
						push( @targetFilter,     'type="' . $1 . '"' );
					}
				}
				if ( $line =~ /select_testset=(.*)/ ) {
					if ( $1 ne "Any Test Set" ) {
						push( @thisTargetFilter, "--set " . $1 );
						push( @targetFilter,     'set name="' . $1 . '"' );
					}
				}
				if ( $line =~ /select_com=(.*)/ ) {
					if ( $1 ne "Any Component" ) {
						push( @thisTargetFilter, "--component " . $1 );
						push( @targetFilter,     'component="' . $1 . '"' );
					}
				}
			}
		}
		close(FILE);
	}
	else {
		inform "[Target Package]:Fail to read the profile:$profile_name";
	}
	inform "[Target Package]:@thisTargetPackages";
	inform "[Target Filter]:@thisTargetFilter";
}

sub readProfile {
	my $targetPackages      = "";
	my $wrtPackages         = "-e \"WRTLauncher";
	my @uninstalledPackages = ();
	if ( !@thisTargetPackages ) {
		&initProfileInfo();
	}
	foreach (@thisTargetPackages) {
		my $thisTargetPackage = $_;

		# check if the package is still there
		my $cmd = sdb_cmd("shell ls /usr/share/$thisTargetPackage/tests.xml");
		my $isInstalled = `$cmd`;
		if ( $isInstalled !~ /No such file or directory/ ) {
			if (   ( $thisTargetPackage =~ /^webapi/ )
				or ( $thisTargetPackage =~ /^cts-webapi/ )
				or ( $thisTargetPackage =~ /^tct-webapi/ )
				or ( $thisTargetPackage =~ /^wrt/ ) )
			{
				$isWebApi = "True";
				$wrtPackages .= " " . $thisTargetPackage;
			}
			if ( $profile_name =~ /plans\/rerun_/ ) {
				$targetPackages .= "/tmp/rerun/$thisTargetPackage/tests.xml ";
			}
			else {
				$targetPackages .= "/usr/share/$thisTargetPackage/tests.xml ";
			}
		}
		else {
			push( @uninstalledPackages, $thisTargetPackage );
		}
	}
	if ( $targetPackages ne "" ) {
		if ( $isWebApi eq "True" ) {
			$targetPackages .= $wrtPackages . '"';
		}
		if ( @thisTargetFilter >= 1 ) {
			$targetPackages .= " ";
			foreach (@thisTargetFilter) {
				my $filter = $_;
				$targetPackages .= $filter . " ";
			}
		}
	}
	if ( @uninstalledPackages > 0 ) {
		my $uninstall = join( ",", @uninstalledPackages );
		return $uninstall;
	}
	return $targetPackages;
}

sub getBackupResultXMLCMD {

	# write runconfig and info file under each report folder
	syncLiteResult();
	chomp( my $time     = `ls -t ../../../lite | cut -f 1 | sed -n '1,1p'` );
	chomp( my $time_all = `ls -l ../../../lite | grep latest` );
	if ( $time_all =~ /-> \/opt\/testkit\/lite\/(.*)/ ) {
		$time = $1;
	}
	writeResultInfo( $time, $isOnlyAuto, @targetFilter );
}

sub syncLiteResult {
	my $result_dir_lite = $FindBin::Bin . "/../../lite";
	system("rm -rf $result_dir_lite/*");
	system("cd /opt/testkit/lite; tar -czvf /tmp/lite.tar.gz .");
	system("cp /tmp/lite.tar.gz $result_dir_lite");
	system("rm -rf /tmp/lite.tar.gz");
	system("cd $result_dir_lite;tar -xzvf lite.tar.gz");
	system("rm -rf $result_dir_lite/lite.tar.gz");
}

# run test in ptyshell
{

	# start ptyshell
	my $subshell = Spawn_subshell( "root", "subshelllog" );
	$globals->{'subshell'} = $subshell;

	is_ok $subshell or fail "create subshell failed!";

	# write status
	$globals->{'testkitdone'} = "Preparing";
	write_status();

	# write INFO for current status
	write_info("Sub shell started");

	# Run the test in ptyshell
	$profile_content = &readProfile( $globals->{'testkit_dir'} . "/plans" );
	$profile_content =~ s/\s*$//;
    $deviceid  = shell_cmd();
	if (   ( $profile_content !~ /usr\/share/ )
		&& ( $profile_content !~ /tmp\/rerun/ ) )
	{
		inform "[ERROR]:\nCan't find the following package(s),\n"
		  . $profile_content
		  . "\nTry to load this test plan or install missing package(s) manually to resolve this issue";
		$globals->{'stop_reason'} = "missing_package";
		write_status();
	}
	else {
		if ( $isWebApi eq "False" ) {
			inform "[CMD]:\n"
			  . "testkit-lite -f "
			  . $profile_content
			  . shell_cmd()
			  . " --non-active --enable-memory-collection\n";
		}
		else {
			inform "[CMD]:\n"
			  . "testkit-lite -f "
			  . $profile_content
			  . shell_cmd()
			  . " --non-active --enable-memory-collection\n";
		}
	}
	if (   ( $profile_content =~ /usr\/share/ )
		or ( $profile_content =~ /tmp\/rerun/ ) )
	{

		# kill all existing widgets before testing
		my $cmd           = sdb_cmd("shell 'wrt-launcher -l'");
		my @package_items = `$cmd`;
		foreach (@package_items) {
			my $package_item = $_;
			my $package_id   = "none";
			if ( $package_item =~ /\s+([a-zA-Z0-9]*?)\s*$/ ) {
				$package_id = $1;
			}
			if ( $package_id ne "none" ) {
				my $cmd =
				  sdb_cmd("shell 'ps aux | grep $package_id | sed -n '1,1p''");
				my $pid = `$cmd`;
				if ( $pid =~ /app\s*(\d+)\s*/ ) {
					system( sdb_cmd("shell 'kill -9 $1'") );
				}
			}
		}

		# start testing
		write_string_as_file( "$globals->{'temp_dir'}/lite-command",
"testkit-lite -f $profile_content --non-active --enable-memory-collection $deviceid "
		);
		system( "mv $globals->{'temp_dir'}/lite-command /tmp" );
		system( 'chmod 755 /tmp/lite-command');
		$subshell->Spawn( 'sh /tmp/lite-command');
	}
	else {
		$subshell->Spawn("echo 'Missing package(s) found, exit...'; sleep 10");
		kill 'TERM', $$;    # send the TERM signal to itself.
	}

	# write status
	$globals->{'testkitdone'}      = "Running";
	$globals->{'complete_package'} = "none";
	write_status();

	# write INFO
	write_info("Testkit-lite test started");

	my $TC_last = "";

	sub check_run_done {
		my ($line) = @_;
		defined $line or $line = "";

		if ( $line =~
			/\[ all tasks for testkit lite are accomplished, goodbye \]/ )
		{
			return 1;
		}

		my $run_time = time() - $globals->{'prepare_time'};
		$globals->{'run_time'} = $run_time;
		write_status();

		# record auto package
		if ( $line =~ /testing xml:.*[0-9:\.\-]+\/(.*?)\.auto\.xml/ ) {
			my $current_package_temp  = $1 . '_auto';
			my $complete_package_temp = $globals->{'complete_package'};
			if ( ( $complete_package_temp eq "none" )
				&& defined $globals->{'current_package'} )
			{
				$globals->{'complete_package'} = $globals->{'current_package'};
			}
			if ( ( $complete_package_temp ne "none" )
				&& defined $globals->{'current_package'} )
			{
				$globals->{'complete_package'} .=
				  '!:!' . $globals->{'current_package'};
			}
			$current_package_temp =~ s/^\s//;
			$current_package_temp =~ s/\s$//;
			$current_package                 = $current_package_temp;
			$globals->{'current_package'}    = $current_package;
			$current_run_number              = 0;
			$globals->{'current_run_number'} = $current_run_number;
			write_status();
			return 0;
		}

		# record manual package
		if ( $line =~ /testing xml:.*[0-9:\.\-]+\/(.*?)\.manual\.xml/ ) {
			my $current_package_temp  = $1 . '_manual';
			my $complete_package_temp = $globals->{'complete_package'};
			if ( ( $complete_package_temp eq "none" )
				&& defined $globals->{'current_package'} )
			{
				$globals->{'complete_package'} = $globals->{'current_package'};
			}
			if ( ( $complete_package_temp ne "none" )
				&& defined $globals->{'current_package'} )
			{
				$globals->{'complete_package'} .=
				  '!:!' . $globals->{'current_package'};
			}
			$current_package_temp =~ s/^\s//;
			$current_package_temp =~ s/\s$//;
			$current_package                 = $current_package_temp;
			$globals->{'current_package'}    = $current_package;
			$current_run_number              = 0;
			$globals->{'current_run_number'} = $current_run_number;
			write_status();
			return 0;
		}

		# record case number
		if ( $line =~ /execute case:/ ) {
			my @matches = $line =~ /execute case:/g;
			$current_run_number += @matches;
			$globals->{'current_run_number'} = $current_run_number;
			write_status();
			return 0;
		}
	}

	# monitor test status
	while ( my $line = $subshell->Read(50) ) {
		my $read_status = check_run_done($line);
		if ($read_status) {
			last;
		}
	}

	# wait some time to print out all messages
	for ( my $i = 0 ; $i < 30 ; $i++ ) {
		$subshell->Read(50);
		sleep 0.1;
	}

	if ( $subshell->{EXIT_CODE} ) {
		warning "subshell exited with code "
		  . $subshell->{EXIT_CODE} . ".\n"
		  . $subshell->get_last_lines();
	}
}

# backup report and send email
{
	if ( $profile_content ne "" ) {

		# write status
		$globals->{'testkitdone'} = 'Making report';
		$globals->{'finish_time'} = time();
		write_status();

		cmd("rm -rf $globals->{'result_dir'}/../latest");
		cmd( "ln -s $globals->{'result_dir'} $globals->{'result_dir'}/../latest"
		);
		&getBackupResultXMLCMD();
	}
}

{
	$globals->{'testkitdone'} = 'Finished';

	# write info
	write_info("Testkit-lite test finished");
	$globals->{'done'} = 'Finished';

	# write status
	write_status();

}

exit 0;

END { goto &$_END if $_END; }

