#! /usr/bin/perl -w
# -*- mode: cperl -*-

###################################################################
# MRTG 2.17.3  Multi Router Traffic Grapher
###################################################################
# Created by Tobias Oetiker <tobi@oetiker.ch>
#            and Dave Rand <dlr@bungi.com>
#
# For individual Contributers check the CHANGES file
#
###################################################################
#
# Distributed under the GNU General Public License
#
###################################################################
my @STARTARGS=($0,@ARGV);

@main::DEBUG=qw();
# DEBUG TARGETS
# cfg  - watch the config file reading
# dir  - directory mangeling
# base - basic program flow
# tarp - target parser
# snpo - snmp polling
# snpo2 - more snmp debug
# coca - confcache operations
# repo - track confcache repopulation
# fork - forking view
# time - some timing info
# log  - logging of data via rateup or rrdtool
# eval - trace eval experssions
# prof - add timeing info some interesting bits of code

$main::GRAPHFMT="png";
# There older perls tend to behave peculiar with
# large integers ...
require 5.005;

use strict;
# addon jpt
BEGIN {
    # Automatic OS detection ... do NOT touch
    if ( $^O =~ /^(ms)?(dos|win(32|nt)?)/i ) {
	$main::OS = 'NT';
	$main::SL = '\\';
	$main::PS = ';';        
    } elsif ( $^O =~ /^NetWare$/i ) {
	$main::OS = 'NW';
	$main::SL = '/';
	$main::PS = ';';
    } elsif ( $^O =~ /^VMS$/i ) {
	$main::OS = 'VMS';
	$main::SL = '.';
	$main::PS = ':';
    } elsif ( $^O =~ /^os2$/i ) {
	$main::OS = 'OS2';
	$main::SL = '/';
	$main::PS = ';';
    } else {
	$main::OS = 'UNIX';
	$main::SL = '/';
	$main::PS = ':';
    }
    if ( $ENV{LANG} and $ENV{LANG} =~ /UTF.*8/i ){        
        my $args = join " ", map { /\s/ ? "\"$_\"" : $_ } @ARGV;
        $args ||= "";
        print <<ERR;
-----------------------------------------------------------------------
ERROR: Mrtg will most likely not work properly when the environment
       variable LANG is set to UTF-8. Please run mrtg in an environment
       where this is not the case. Try the following command to start:

       env LANG=C ${0} $args 
-----------------------------------------------------------------------
ERR
        exit 0;
    }
}


use FindBin;
use lib "${FindBin::Bin}";
use lib "${FindBin::Bin}${main::SL}..${main::SL}lib${main::SL}mrtg2";
use Getopt::Long;
use Math::BigFloat;

# search for binaries in the bin and bin/../lib  directory
use MRTG_lib "2.100016";

my $NOW = timestamp;

# $SNMP_Session::suppress_warnings = 2;
use locales_mrtg "0.07";

# Do not Flash Console Windows for the forked rateup process 
BEGIN {
    if ($^O eq 'MSWin32'){
	eval {local $SIG{__DIE__};require Win32; Win32::SetChildShowWindow(0)};
	warn "WARNING: $@\n" if $@;
    }    
}

$main::STARTTIME = time;

%main::verified_rrd = ();
    
if ($MRTG_lib::OS eq 'OS2') {
# in daemon mode we will pause 3 seconds to be sure that parent died
  require OS2::Process;
  if (OS2::Process::my_type() eq 'DETACH') {sleep(3);}
}

if ($MRTG_lib::OS eq 'UNIX') {
   $SIG{INT} = $SIG{TERM} = 
           sub {   unlink ${main::Cleanfile} 
                       if defined $main::Cleanfile;
                   unlink ${main::Cleanfile2}
                       if defined $main::Cleanfile2;
                   unlink ${main::Cleanfile3}
                       if defined $main::Cleanfile3;
                   warn "$NOW: ERROR: Bailout after SIG $_[0]\n";
                   exit 1;
                };
  $SIG{HUP} = sub {
                   unlink ${main::Cleanfile} 
                       if defined $main::Cleanfile;
                   unlink ${main::Cleanfile2}
                       if defined $main::Cleanfile2;
                   unlink ${main::Cleanfile3}
                       if defined $main::Cleanfile3;
                   die "$NOW: ERROR: Bailout after SIG $_[0]\n";
                };
}


END {
    local($?, $!);
    unlink ${main::Cleanfile} if defined $main::Cleanfile;
    unlink ${main::Cleanfile2} if defined $main::Cleanfile2;
}

&main;

exit(0);

#### Functions ################################################

sub main {

    
    # read in the config file
    my @routers;
    my %cfg;
    my %rcfg;
    my %opts; 
    my $EXITCODE = 0;
    
    GetOptions(\%opts, 'user=s', 'group=s', 'lock-file=s','confcache-file=s','logging=s', 'check', 'fhs', 'daemon',  'pid-file=s','debug=s', 'log-only') or die "Please use valid Options\n";

    if (defined $opts{debug}){
        @main::DEBUG = split /\s*,\s*/, $opts{debug};
	if (defined $SNMP_util::Debug){
	        $SNMP_util::Debug = 1 if grep /^snpo2$/, @main::DEBUG;
	}
    }
    if (grep /^prof$/, @main::DEBUG){
	require Time::HiRes;
        eval "sub gettimeofday() {return Time::HiRes::time()}";
	# note this will crash if the module is missing
	# so only use the --debug=prof if you have Time::HiRes installed
    } else {
	eval "sub gettimeofday() {return time()}";
    }
    debug 'time', "prog start ".localtime(time);

    my $uid = $<;
    my $gid = $(;

    if (defined $opts{group}) {
        $gid = getgrnam($opts{group});
        die "$NOW: ERROR: Unknown Group: $opts{group})\n" if not defined $gid;
    }

    if (defined $opts{user}) {
        $uid = getpwnam($opts{user});
        die "$NOW: ERROR: Unknown User: $opts{user})\n" if not defined $uid;
    }

    # If we've specified using FHS (http://www.pathname.com/fhs/) on the command line,
    # use the relevant path definitions (can be overridden later):

    my $confcachefile;
    my $pidfile;
    my $lockfile;
    my $templock;
    my $logfile;

    if (defined $opts{"fhs"}) {
	$confcachefile = "/var/cache/mrtg/mrtg.ok";
	$pidfile = "/var/run/mrtg.pid";
	$lockfile = "/var/cache/mrtg/mrtg.lck";
	$templock = "/var/cache/mrtg/mrtg.lck.$$";
	$logfile = "/var/log/mrtg.log";
    }	

    my $cfgfile = shift @ARGV;

    if ( !defined $cfgfile and -r "/etc/mrtg.cfg" ) { $cfgfile = "/etc/mrtg.cfg"; }

    printusage() unless defined $cfgfile;

    # PID file code, used later if daemonizing...
    if ( !defined($pidfile) ) {
        $pidfile =  $cfgfile;
        $pidfile =~ s/\.[^.\/]+$//;
        $pidfile .= '.pid';
    }
    $pidfile =  $opts{"pid-file"} || $pidfile;

    # Run as a daemon, specified on command line (required for FHS compliant daemon)
    if (defined $opts{"daemon"}) {
	# Create a pidfile, then chown it so we can use it once we change user
	&create_pid($pidfile);
	chown $uid, $gid, $pidfile;
    }

    ($(,$)) = ($gid,$gid) ;
    ($<,$>) = ($uid,$uid) ;
    die "$NOW: ERROR failed to set UID to $uid\n" unless ($< == $uid and  $> == $uid);

    $logfile = $opts{logging} || $logfile;
    if (defined $logfile){
	setup_loghandlers $logfile;
        warn "Started mrtg with config \'$cfgfile\'\n";
    }	

    # lets make sure that there are not two mrtgs running in parallel.
    # so we lock on the cfg file. Nothing fancy, just a lockfile

    $lockfile = $opts{"lock-file"} || $lockfile;

    if (! defined $lockfile) {
        $lockfile = $cfgfile."_l";
    }
    if (! defined $templock) {
        $templock = $lockfile."_" . $$ ;
    }

    debug('base', "Creating Lockfiles $lockfile,$templock");
    &lockit($lockfile,$templock);

    debug('base', "Reading Config File: $cfgfile");
    my $cfgfile_age = -M $cfgfile;
    readcfg($cfgfile,\@routers,\%cfg,\%rcfg);

    imggen($cfg{icondir} || $cfg{imagedir} || $cfg{workdir});
    
    # Enable or disable snmpv3
    if(defined $cfg{enablesnmpv3}) {
        $cfg{enablesnmpv3} = lc($cfg{enablesnmpv3});
    } else {
        $cfg{enablesnmpv3} = 'no';
    }

    if ($cfg{threshmailserver}) {
        if  (eval {local $SIG{__DIE__};require Net::SMTP;})   {
	    import Net::SMTP;
            debug('base', "Loaded Net::SMTP module for ThreshMail.");
        } else {
            die "$NOW: WARNING: Can't load Net::SMTP module. This is required for ThreshMail.";
        }
    }
    # Check we have the necessary libraries for IPv6 support
    if ($cfg{enablesnmpv3} eq 'yes') {
        if  (eval {local $SIG{__DIE__};require Net_SNMP_util;})   {
	    import Net_SNMP_util;
            debug('base', "SNMP V3 libraries found, SNMP V3 enabled.");
        } else {
            warn "$NOW: WARNING: SNMP V3 libraries not found, SNMP V3 disabled.\n";
            $cfg{enablesnmpv3} =  'no';
	    require SNMP_util;
	    import SNMP_util;
        }
    }
    else {	# load V1/V2 libraries 
	require SNMP_util;
	import SNMP_util;
    }
    

    # Enable or disable IPv6
    if(defined $cfg{enableipv6}) {
        $cfg{enableipv6} = lc($cfg{enableipv6});
    } else {
        $cfg{enableipv6} = 'no';
    }

    # Check we have the necessary libraries for IPv6 support
    if ($cfg{enableipv6} eq 'yes') {
        if ( eval {local $SIG{__DIE__};require Socket; require Socket6; require IO::Socket::INET6;}) {
            import Socket;
            import Socket6;
            debug('base', "IPv6 libraries found, IPv6 enabled.");
        } else {
            warn "$NOW: WARNING: IPv6 libraries not found, IPv6 disabled.\n";
            $cfg{enableipv6} =  'no';
        }
    }

    # from our last run we kept some info about
    # the configuration of our devices around
    debug('base', "Reading Interface Config cache");
    $confcachefile =  $opts{"confcache-file"} || $confcachefile;
    if ( !defined($confcachefile) ) {
        $confcachefile = $cfgfile;
        $confcachefile  =~ s/\.[^.\/]+$//;
        $confcachefile .= ".ok";
    }
    my $confcache = readconfcache($confcachefile);

    # Check the config and create the target object
    debug('base', "Checking Config File");
    my @target;
    cfgcheck(\@routers, \%cfg, \%rcfg, \@target, \%opts);

    # exit here if we only check the config file
    # in case of an error, cfgcheck() already exited
    if (defined $opts{check}) {
        debug('base', "Remove Lock Files");
        close LOCK; unlink ($templock, $lockfile);
        debug('base', "Exit after successful config file check");
        exit 0;
    }

    # postload rrdtool support
    if ($cfg{logformat} eq 'rrdtool'){
        debug('base', "Loading RRD support");
	require 'RRDs.pm';
    }

    # set the locale
    my $LOC;
    if ( $cfg{'language'} and defined($lang2tran::LOCALE{"\L$cfg{'language'}\E"})) {
	debug('base', "Loading Locale for ".$cfg{'language'});
	$LOC=$lang2tran::LOCALE{"\L$cfg{'language'}\E"};
    } else {
	debug('base', "Loading default Locale");
	$LOC=$lang2tran::LOCALE{'default'};
    }

    # Daemon Code
    my $last_time=0;
    my $curent_time;
    my $sleep_time;
    if (defined $opts{"daemon"}) { $cfg{'runasdaemon'} = "yes"; }
    &demonize_me($pidfile,$cfgfile) if defined $cfg{'runasdaemon'}  and $cfg{'runasdaemon'} =~ /y/i  and $MRTG_lib::OS ne 'VMS'
    	and not (defined $cfg{'nodetach'} and $cfg{'nodetach'} =~ /y/i);
    # auto restart on die if running as demon

    $SIG{__DIE__} = sub {
        warn $_[0];
        warn "*** Restarting after 10 seconds in an attempt to recover from the error above\n";
        sleep 10;
        exec @STARTARGS;
    } if $cfg{'runasdaemon'};

    debug('base', "Starting main Loop");
    do {                        # Do this loop once for native mode and forever in daemon mode 
        my $router;        
        $NOW = timestamp;   # get the time
        debug 'time', "loop start ".localtime(time);

        #if we run as daemon, we sleep in between collection cycles
        $sleep_time=  (int($cfg{interval}*60))-(time-$last_time);
        if ($sleep_time > 0 ) { #If greater than 0 the sleep that amount of time
	    debug('time', "Sleep time $sleep_time seconds");
            sleep ($sleep_time);
        } elsif ($last_time > 0) {
            warn "$NOW: WARNING: data collection did not complete within interval!\n";
        }
        $last_time=time;

        # set meta expires if there is an index file
        # 2000/05/03 Bill McGonigle <bill@zettabyte.net>
        if (defined $cfg{'writeexpires'}) {
           my $exp = &expistr($cfg{'interval'});
           my $fil;
           $fil = "$cfg{'htmldir'}index.html"  if -e "$cfg{'htmldir'}index.html";
           $fil = "$cfg{'htmldir'}index.htm"  if -e "$cfg{'htmldir'}index.htm";
            if (defined $fil) {
                   open(META, ">$fil.meta");
                   print META "Expires: $exp\n";
                   close(META);
            }
        }


        # Use SNMP to populate the target object
	debug('base', "Populate Target object by polling SNMP and".
	      " external Datasources");
        debug 'time', "snmp read start ".localtime(time);
        readtargets($confcache,\@target, \%cfg);

        $NOW = timestamp;   # get the time
        # collect data for each router or pseudo target (`executable`)
        debug 'time', "target loop start ".localtime(time);
        foreach $router (@routers) {
	    debug('base', "Act on Router/Target $router");
            if (defined $rcfg{'setenv'}{$router}) {
                my $line = $rcfg{'setenv'}{$router};
                while ( $line =~ s/([^=]+)=\"([^\"]*)\"\s*// ) # " - unconfuse the highliter
 		{ 
		    $ENV{$1}=$2;
                }
	    }
	    my($savetz) = $ENV{'TZ'};
	    if (defined $rcfg{'timezone'}{$router}) {
                $ENV{'TZ'} = $rcfg{'timezone'}{$router};
		if ( $main::OS eq 'UNIX' ){
			require 'POSIX.pm';
			POSIX::tzset();
		}
            }

            my ($inlast, $outlast, $uptime, $name, $time) = 
              getcurrent(\@target, $router, \%rcfg, \%cfg);

            if ( defined($inlast) and defined($outlast)) {
              $EXITCODE = $EXITCODE | 1;
            }
            else {
              $EXITCODE = $EXITCODE | 2;
            }

	    debug('base', "Get Current values: in:".( defined $inlast ? $inlast : "undef").", out:".
                                                 ( defined $outlast? $outlast : "undef").", up:".
                                                 ( defined $uptime ? $uptime : "undef").", name:".
                                                 ( defined $name ? $name : "undef").", time:".
                                                 ( defined $time ? $time : "undef"));

            #abort, if the router is not responding.
            if ($cfg{'logformat'} ne 'rrdtool') {
              # undefined values are ok for rrdtool !
              #if ( not defined $inlast or not defined $outlast){
              #  warn "$NOW: WARNING: Skipping Update of $router, inlast is not defined\n"
              #          unless defined $inlast;
              #  warn "$NOW: WARNING: Skipping Update of $router, outlast is not defined\n"
              #          unless defined $outlast;
              #  next;
              #}

              if (defined $inlast and $inlast < 0) {
                $inlast += 2**31;
                # this is likely to be a broken snmp counter ... lets compensate
              }  
              if (defined $outlast and $outlast < 0) {
                $outlast += 2**31;
                # this is likely to be a broken snmp counter ... lets compensate
              }  
            }
	    
            my ($maxin, $maxout, $maxpercent, $avin, $avout, $avpercent,$avmxin, $avmxout,
                $cuin, $cuout, $cupercent);
	    debug('base', "Create Graphics");
            if ($rcfg{'options'}{'dorelpercent'}{$router}) {
                ($maxin, $maxout, $maxpercent, $avin, $avout, $avpercent,
                 $cuin, $cuout, $cupercent, $avmxin, $avmxout) =
                  writegraphics($router, \%cfg, \%rcfg, $inlast, $outlast, $time,$LOC, \%opts);
            } else {
                ($maxin, $maxout ,$avin, $avout, $cuin, $cuout, $avmxin, $avmxout) =
                  writegraphics($router, \%cfg, \%rcfg, $inlast, $outlast, $time,$LOC, \%opts);
            }
            # skip this update if we did not get anything usefull out of
            # writegraphics
            next if not defined $maxin;

	    debug('base', "Check for Thresholds");
            threshcheck(\%cfg,\%rcfg,$cfgfile,$router,$cuin,$cuout);

	    if (defined $opts{'log-only'}){
		debug('base', "Disable Graph and HTML generation");
	    }

	    if ($cfg{logformat} eq 'rateup' and not defined $opts{'log-only'} ){
		debug('base', "Check for Write HTML Pages");
		writehtml($router, \%cfg, \%rcfg,
			  $maxin, $maxout, $maxpercent, $avin, $avout, $avmxin, $avmxout, $avpercent,
			  $cuin, $cuout, $cupercent, $uptime, $name, $LOC)
	    }

            #
            clonedirectory($router,\%cfg, \%rcfg);
            #

            #put TZ things back in shape ... 
            if ($savetz) {
                $ENV{'TZ'} =  $savetz;
            } else {
                delete $ENV{'TZ'};
            }
	    if ( $main::OS eq 'UNIX' ){
		require 'POSIX.pm';
		POSIX::tzset();
	    };
        }
        # Has the cfg file been modified since we started? if so, reload it.
        if ( -M $cfgfile < $cfgfile_age and 
          $cfg{'runasdaemon'} and $cfg{'runasdaemon'} =~ /y/i ) {
            # reload the configuration
            $cfgfile_age = -M $cfgfile;
            debug('base', "Re-reading Config File: $cfgfile");
            @routers = (); %cfg = (); %rcfg = ();
            readcfg($cfgfile,\@routers,\%cfg,\%rcfg);
            cfgcheck(\@routers, \%cfg, \%rcfg, \@target, \%opts);
        }
        debug('base', "End of main Loop");
    } while ($cfg{'runasdaemon'} and $cfg{'runasdaemon'} =~ /y/i ); #In daemon mode run forever
    debug('base', "Exit main Loop");
    # OK we are done, remove the lock files ... 

    debug('base', "Remove Lock Files");
    close LOCK; unlink ($templock, $lockfile);

    debug('base', "Store Interface Config Cache");
    delete $$confcache{___updated} if exists $$confcache{___updated}; # make sure everything gets written out not only the updated entries
    writeconfcache($confcache,$confcachefile);

    if ( ! $cfg{'runasdaemon'} or $cfg{'runasdaemon'} !~ /y/i ) {
      if ( ($EXITCODE & 1) and ($EXITCODE & 2) ) {
        # At least one target was sucessful
        exit 91;
      }
      elsif ( not ($EXITCODE & 1) and ($EXITCODE & 2) ) {
        # All targets failed
        exit 92;
      }
    }
}

# ( $inlast, $outlast, $uptime, $name, $time ) =
#    &getcurrent( $target, $rou, $rcfg, $cfg )
# Calculate monitored data for device $rou based on information in @$target
# and referring to configuration data in %$rcfg and %$cfg. In the returned
# list, $inlast and $outlast are the input and output monitored data values,
# $uptime is the device uptime, $name is the device name, and $time is the
# current time when the calculation was performed.
sub getcurrent {
	my( $target, $rou, $rcfg, $cfg ) = @_;
	# Hash indexed by $mode for conveniently saving $inlast and $outlast
	my %last;
	# Initialize uptime, device name, and data collection time to empty strings
	my $uptime = '';
	my $name = '';
	my $time = '';

	# Calculate input and output monitored data
	foreach my $mode( qw( _IN_  _OUT_ ) ) {
		# Initialize monitored data, warning message, and death message
		# to empty strings
		my $data;
		my $warning;
		my $death;
		{
			# Code block used to calculate monitoring data
			# Localize warning and death exception handlers to capture
			# error message less any leading and trailing white space
			local $SIG{ __WARN__ } =
				sub { $_[0] =~ /^\s*(.+?)\s*$/; $warning = $1; };
			local $SIG{ __DIE__ } =
				sub { $_[0] =~ /^\s*(.+?)\s*$/; $death = $1; };
			# Calculate monitoring data. $rcfg->{ target }{ $rou } contains
			# a Perl expression for the calculation.
			$data = eval "$rcfg->{target}{$rou}";
       		}
		# Test for various exceptions occurring in the calculation
		if( $warning ) {
			warn "$NOW: ERROR: Target[$rou][$mode] '$$rcfg{target}{$rou}' (warn): $warning\n";
			$data = undef;
		} elsif( $death ) {
			warn "$NOW: ERROR: Target[$rou][$mode] '$$rcfg{target}{$rou}' (kill): $death\n";
			$data = undef;
		} elsif( $@ ) {
			warn "$NOW: ERROR: Target[$rou][$mode] '$$rcfg{target}{$rou}' (eval): $@\n";
			$data = undef;
		} elsif( not defined $data ) {
			warn "$NOW: ERROR: Target[$rou][$mode] '$$rcfg{target}{$rou}' did not eval into defined data\n";
			$data = undef;
		} elsif( $data and $data !~ /^[-+]?\d+(\.\d*)?([eE][+-]?[0-9]+)?$/ ) {
			warn "$NOW: ERROR: Target[$rou][$mode] '$$rcfg{target}{$rou}' evaluated to '$data' instead of a number\n";
			$data = undef;
		} elsif( length( $data ) > 190 ) {
			warn "$NOW: ERROR: $mode value: '$data' is way to long ...\n";
			$data = undef;
		} else {
			# At this point data is considered valid. Round to an integer
			# unless RRDTool is in use and this is a gauge
                        if (not ( $cfg->{ logformat } eq 'rrdtool'
                                      and  defined $rcfg->{ options }{ gauge }{ $rou })){
                            if (ref $data and ref $data eq 'Math::BigFloat') {
                			$data->ffround( 0 )
                            } else {
                                        $data = sprintf "%.0f", $data;
                            }
                        }
			# Remove any leading plus sign
			$data =~ s/^\+//;
		}
		$last{ $mode } = $data;
	}

	# Set $u to the unique index of the @$target array referred to in the
	# monitored data calculation for the current device. $u will be set to
	# -1 if that index is not unique.
	my $u = $rcfg->{ uniqueTarget }{ $rou };

	# Get the uptime, device name, and data collection time from the @$target
	# array if the monitored data calculation refers only to one target.
	# Otherwise it doesn't make sense to do this.
	if( $u >= 0 ) {
		$uptime = $target->[ $u ]{ _UPTIME_ };
		$name = $target->[ $u ]{ _NAME_ };
		$time = $target->[ $u ]{ _TIME_ };

                if ($time =~ /^([-0-9.]+)$/) {
                   $time = $1;
                }

	}

	# Set the time to the current time if it was not set above
	$time = time unless $time;

	# Cache uptime location for reading name
	my( $uploc );

	# Get the uptime and device name from the alternate location (community@host or
	# (OID:community@host or OID) that may have been specified with the RouterUptime
	# target keyword
	if( defined $rcfg->{ routeruptime }{ $rou } ) {
		my( $noid, $nloc ) = split( /:/, $rcfg->{ routeruptime }{ $rou }, 2 );
		# If only location (community@host) was specified then
		# move the location details into the right place
		if( $noid =~ /@/ ) {
			$nloc = $noid;
			$noid = undef;
		}
		# If no OID (community@host) was specified use the hardcoded default
		if( not $noid ) {
			$noid = 'sysUptime';
		}
		# If no location (community@host) was specified use values from the
		# unique target referred to in the monitored data calculation
		if( not $nloc ){
                        if ($u >= 0) {
          		    my $comm = $target->[ $u ]{ Community };
			    my $host = $target->[ $u ]{ Host };
			    my $opt = $target->[ $u ]{ SnmpOpt };
			    $nloc = "$comm\@$host$opt";
		        } else {
                            die "$NOW: ERROR: You must specify the location part of the RouterUptime oid for non unique targets! ($rou)\n";
                        }
                }
        
		$uploc = $nloc;
		# Get the device uptime if $noid(OID) and $nloc (community@host) have been specified
		# one way or the other
		debug('base', "Fetching sysUptime and sysName from: $noid:$nloc");
		( $uptime, $name ) = snmpget( $uploc, $rcfg->{ snmpoptions }{ $rou }, $noid, 'sysName');
	}

	# Get the device name from the alternate location (OID or
	# OID:community@host) that may have been specified with the RouterName
	# target keyword
	if( defined $rcfg->{ routername }{ $rou } ) {
		my( $noid, $nloc ) = split( /:/, $rcfg->{ routername }{ $rou }, 2 );
		# If no location (community@host) was specified use values from the
		# unique target referred to in the monitored data calculation
		if( $u >= 0 and not $nloc ) {
			my $comm = $target->[ $u ]{ Community };
			my $host = $target->[ $u ]{ Host };
			my $opt = $target->[ $u ]{ SnmpOpt };
			$nloc = "$comm\@$host$opt";
		}
		# Get the location from the RouterUptime keyword if that is defined
		# and $nloc has not otherwise been specified
		$nloc = $uploc if $uploc and not $nloc;
		# Get the device name if $nloc (community@host) has been specified
		# one way or the other
		debug('base', "Fetching sysName from: $noid:$nloc");
		( $name ) = snmpget( $nloc, $$rcfg{snmpoptions}{ $rou }, $noid ) if $nloc;
	}
  
	return ( $last{ _IN_ }, $last{ _OUT_ }, $uptime, $name, $time );
}

sub rateupcheck ($) {
    my $router = shift;
    if ($?) {
        my $value = $?;
        my $signal =  $? & 127; #ignore the most significant bit 
                                #as it is always one when it is a returning
                                #child says dave ...
        if (($MRTG_lib::OS ne 'UNIX') || ($signal != 127)) {
            my $exitval = $? >> 8;
            warn "$NOW: WARNING: rateup died from Signal $signal\n".
              " with Exit Value $exitval when doing router '$router'\n".
                " Signal was $signal, Returncode was $exitval\n"
        }
    }
}

sub clonedirectory {
    my($router,$cfg, $rcfg) = @_;
    require File::Copy;
    import File::Copy;

    return unless ( $$rcfg{'clonedirectory'}{$router} );

    my ($clonedstdir, $clonedsttarget ,$srcname, $dstname);

    ($clonedstdir, $clonedsttarget ) = split (/,|\s+/, $$rcfg{'clonedirectory'}{$router}) if ( $$rcfg{'clonedirectory'}{$router} =~ /,|\S\s+\S/ );

    if ( defined $clonedsttarget ) {
		$clonedsttarget =~ s/\s+//;
		$clonedsttarget = lc($clonedsttarget);
    } else {
        	$clonedstdir = $$rcfg{'clonedirectory'}{$router};
    }
    if ( $$rcfg{'directory'}{$router} ne $clonedstdir) {
	$clonedstdir =~ s/\s+$//;
        $clonedstdir .= "/" unless ($clonedstdir =~ /\/$/);
        my $fullpathsrcdir = "$$cfg{'logdir'}$$rcfg{'directory'}{$router}";
        my $fullpathdstdir = "$$cfg{'logdir'}$clonedstdir";

        die "$NOW: ERROR: Destination dir: $fullpathdstdir not found for cloning process\n" unless ( -e $fullpathdstdir );
        die "$NOW: ERROR: Destination dir: $fullpathdstdir is not a directory destination for cloning process\n" unless ( -d $fullpathdstdir );
        die "$NOW: ERROR: Destination dir: $fullpathdstdir is not writeable for cloning process\n" unless ( -w $fullpathdstdir );

        if ( defined $clonedsttarget ) {
        	debug('base', "Clone directory $fullpathsrcdir to $fullpathdstdir " . 
			       "renaming target $router to $clonedsttarget"); 
	} else {
        	debug('base', "Clone directory $fullpathsrcdir to $fullpathdstdir");
	}

        foreach my $srcfile (<$fullpathsrcdir$router\[.-\]*>) {
                debug('base', "copying $srcfile $fullpathdstdir");
                copy("$srcfile","$fullpathdstdir") or warn "$NOW: WARNING: Cloning $srcfile to $fullpathdstdir unsuccessful; $!\n";
                if ($srcfile =~ /\.html/i) {
                        debug('base', "altering $fullpathdstdir/$router.$$rcfg{'extension'}{$router}");
                        #
                        my $dirrel = "../" x ($$rcfg{'clonedirectory'}{$router} =~ tr|/|/|);
                        #
                        debug('base', "dirrel $dirrel $clonedstdir");
                        open(HTML,"$fullpathdstdir/$router.$$rcfg{'extension'}{$router}");
                        my @CLONEHTML = <HTML>;
                        close(HTML);
                        foreach ( @CLONEHTML ) {
	    			if ( defined $clonedsttarget and /$router/ ) {
                                       	debug('base', "altering $router to $clonedsttarget in html file");
					s/$router/$clonedsttarget/i;
				}
                                if ( /SRC=/i and /$$rcfg{'directory'}{$router}/ ) {
                                        debug('base', "altering from $_");
                                        s|(\.\./)+|$dirrel|;
                                        s|$$rcfg{'directory'}{$router}|$clonedstdir|;
                                        debug('base', "altering to $_");
                                }
                        }
                        open(HTML,">$fullpathdstdir/$router.$$rcfg{'extension'}{$router}");
                        print HTML $_ for ( @CLONEHTML );
                        close(HTML);
                }
	    	if ( defined $clonedsttarget ) {
			$srcfile =~ /.+\/(.+)?$/;
			$srcname = $1;
			$dstname = $srcname;
			$dstname =~ s/$router/$clonedsttarget/;
                        debug('base', "Clone renaming $srcname to $dstname at $fullpathdstdir");
                	rename("$fullpathdstdir/$srcname","$fullpathdstdir/$dstname") or 
				warn "$NOW: WARNING: Renaming $fullpathdstdir/$srcname to $fullpathdstdir/$dstname unsuccessful; $!\n";
		}
        }
    } else {
      warn "$NOW: WARNING: Cloning to the same place suspended. ; $!\n";
    }
}

sub writegraphics {
    my($router, $cfg, $rcfg, $inlast, $outlast, $time,$LOC, $opts) = @_;
  
    my($absmax,$maxv, $maxvi, $maxvo, $i, $period, $res);
    my(@exec, @mxvls, @metas);
    my(%maxin, %maxout, %maxpercent, %avin, %avout, %avmxin, %avmxout,  %avpercent, %cuin, %cuout, %cupercent);
    my($rrdinfo);

    @metas = ();
    $maxvi = $$rcfg{'maxbytes1'}{$router};
    $maxvo = $$rcfg{'maxbytes2'}{$router};
    if ($maxvi > $maxvo) {
        $maxv = $maxvi;
    } else {
        $maxv = $maxvo;
    }
    $absmax = $$rcfg{'absmax'}{$router};
    $absmax = $maxv unless defined $absmax;
    if ($absmax < $maxv) {
        die "$NOW: ERROR: AbsMax: $absmax is smaller than MaxBytes: $maxv\n";
    }


    # select whether the datasource gives relative or absolute return values.
    my $up_abs="u";
    $up_abs='m' if defined $$rcfg{'options'}{'perminute'}{$router};
    $up_abs='h' if defined $$rcfg{'options'}{'perhour'}{$router};
    $up_abs='d' if defined $$rcfg{'options'}{'derive'}{$router};
    $up_abs='a' if defined $$rcfg{'options'}{'absolute'}{$router};
    $up_abs='g' if defined $$rcfg{'options'}{'gauge'}{$router};

    my $dotrrd = "$$cfg{'logdir'}$$rcfg{'directory'}{$router}$router.rrd";
    my $dotlog = "$$cfg{'logdir'}$$rcfg{'directory'}{$router}$router.log";
    my $reallog = $$cfg{logformat} eq 'rrdtool' ? $dotrrd : $dotlog;

    if (defined $$cfg{maxage} and -e $reallog and time()-$$cfg{maxage} > (stat($reallog))[9]){
         warn "$NOW: ERROR: skipping update of $router. As $reallog is older than MaxAge ($$cfg{maxage} s)\n";
         return undef;
    }

    if ($$cfg{logformat} eq 'rrdtool') {
        debug('base',"start RRDtool section");
        # make sure we got some sane default here
        my %dstype = qw/u COUNTER a ABSOLUTE g GAUGE h COUNTER m COUNTER d DERIVE/;
        $up_abs = $dstype{$up_abs};
        # update the database.

        # set minimum/maximum values. use 'U' if we cannot get good values
        # the lower bound is hardcoded to 0
        my $absi = $maxvi;
        my $abso = $maxvo;
        $absi = $abso = $$rcfg{'absmax'}{$router}
            if defined $$rcfg{'absmax'}{$router};
        debug('base',"maxi:$absi, maxo:$abso");
        $absi = 'U' if $absi == 0;
        $abso = 'U' if $abso == 0;
        # check to see if we already have an RRD file or have to create it
        # maybe we can convert an .log file to the new rrd format
        if( $RRDs::VERSION >= 1.4 and $$cfg{rrdcached} and $$cfg{rrdcached} !~ /^unix:/ ) {
             # rrdcached in network mode.  No log conversion possible.
             # In this mode, we cannot use absolute paths.  So, we strip logdir from the name.
             $dotrrd = "$$rcfg{'directory'}{$router}$router.rrd";
             if( $RRDs::VERSION < 1.49 ) {
               # This version of RRD doesnt support info, create and tune
               debug('base',"Unable to verify RRD file with this version of rrdcached");
               if( !$main::verified_rrd{$dotrrd} ) {
                 warn "WARN: Unable to verify $dotrrd with this version of RRDTool\n";
                 $main::verified_rrd{$dotrrd} = 1;
               }
             } elsif( !$main::verified_rrd{$dotrrd} ) {
               # Test to see if it exists
               debug('base',"Attempting to verify RRD file via rrdcached");
               $rrdinfo = RRDs::info($dotrrd,'--daemon',$$cfg{rrdcached},'--noflush');
               if(!$rrdinfo) { # doesnt exist, or cannot be accessed
                  my $e = RRDs::error();
                  warn "$NOW: Cannot access $dotrrd; will attempt to (re)create it: $e\n" if $e;
  
                  # don't fail if interval is not set
                  my $interval = $$cfg{interval};
                  my $minhb = int($$cfg{interval} * 60)*2;
                  $minhb = 600 if ($minhb <600); 
                  my $rows = $$rcfg{'rrdrowcount'}{$router} || int( 4000 / $interval);
                  my $rows30m = $$rcfg{'rrdrowcount30m'}{$router} || 800;
                  my $rows2h = $$rcfg{'rrdrowcount2h'}{$router} || 800;
                  my $rows1d = $$rcfg{'rrdrowcount1d'}{$router} || 800;
                  my @args = ($dotrrd, '-b', $time-10, '-s', int($interval * 60),
                               "DS:ds0:$up_abs:$minhb:0:$absi",
                               "DS:ds1:$up_abs:$minhb:0:$abso",
                               "RRA:AVERAGE:0.5:1:$rows",
                               ( $interval < 30  ? ("RRA:AVERAGE:0.5:".int(30/$interval).":".$rows30m):()),
                                 "RRA:AVERAGE:0.5:".int(120/$interval).":".$rows2h,
                               "RRA:AVERAGE:0.5:".int(1440/$interval).":".$rows1d,
                               "RRA:MAX:0.5:1:$rows",
                               ( $interval < 30  ? ("RRA:MAX:0.5:".int(30/$interval).":".$rows30m):()),
                               "RRA:MAX:0.5:".int(120/$interval).":".$rows2h,
                               "RRA:MAX:0.5:".int(1440/$interval).":".$rows1d);
                  # do we have holt winters rras defined here ?
                  if (defined $$rcfg{'rrdhwrras'} and defined $$rcfg{'rrdhwrras'}{$router}){
                      push @args, split(/\s+/, $$rcfg{'rrdhwrras'}{$router});
                  }
                  push @args,"--daemon", $$cfg{rrdcached};
  
                  debug('base',"create $dotrrd via rrdcached");
                  debug('log', "RRDs::create(".join(',',@args).")");
                  RRDs::create(@args);
                  $e = RRDs::error();
                  die "$NOW: ERROR: Cannot create RRD ".join(',',@args)."- $e\n" if $e;
              } else {
                  # Does the RRD file need to be tuned?
                  if(
                      ($rrdinfo->{"ds[ds0].max"} != $absi) 
                      ||($rrdinfo->{"ds[ds1].max"} != $abso) 
                      ||($rrdinfo->{"ds[ds0].type"} ne $up_abs) 
                      ||($rrdinfo->{"ds[ds1].type"} ne $up_abs) 
                  ) {
                      debug('base',"RRD file needs to be tuned");
                      warn "$NOW: RRDFile $dotrrd needs to be tuned but cannot do this remotely.\n";
                  }
              }
              $main::verified_rrd{$dotrrd} = 1;
            } else {
               debug('base',"No need to verify this file again");
            }
        } elsif (-e $dotlog and not -e $dotrrd) {
             debug('base',"converting $dotlog to RRD format");
             if(defined $RRDs::VERSION and $RRDs::VERSION < 1.000271){
                die "$NOW: ERROR: RRDtool version 1.0.27 or later required to perform log2rrd conversion\n";
             }
             log2rrd($router,$cfg,$rcfg);
        } elsif (! -e $dotrrd) {
            #nope it seems we have to create a new one
            debug('base',"create $dotrrd");
            # create the rrd if it doesn't exist
            # don't fail if interval is not set
            my $interval = $$cfg{interval};
            my $minhb = int($$cfg{interval} * 60)*2;
            $minhb = 600 if ($minhb <600); 
            my $rows = $$rcfg{'rrdrowcount'}{$router} || int( 4000 / $interval);
            my $rows30m = $$rcfg{'rrdrowcount30m'}{$router} || 800;
            my $rows2h = $$rcfg{'rrdrowcount2h'}{$router} || 800;
            my $rows1d = $$rcfg{'rrdrowcount1d'}{$router} || 800;
            my @args = ($dotrrd, '-b', $time-10, '-s', int($interval * 60),
                         "DS:ds0:$up_abs:$minhb:0:$absi",
                         "DS:ds1:$up_abs:$minhb:0:$abso",
                         "RRA:AVERAGE:0.5:1:$rows",
                         ( $interval < 30  ? ("RRA:AVERAGE:0.5:".int(30/$interval).":".$rows30m):()),
                         "RRA:AVERAGE:0.5:".int(120/$interval).":".$rows2h,
                         "RRA:AVERAGE:0.5:".int(1440/$interval).":".$rows1d,
                         "RRA:MAX:0.5:1:$rows",
                         ( $interval < 30  ? ("RRA:MAX:0.5:".int(30/$interval).":".$rows30m):()),
                         "RRA:MAX:0.5:".int(120/$interval).":".$rows2h,
                         "RRA:MAX:0.5:".int(1440/$interval).":".$rows1d);
            # do we have holt winters rras defined here ?
            if (defined $$rcfg{'rrdhwrras'} and defined $$rcfg{'rrdhwrras'}{$router}){
                push @args, split(/\s+/, $$rcfg{'rrdhwrras'}{$router});
            }

            debug('log', "RRDs::create(".join(',',@args).")");
            RRDs::create(@args);
            my $e = RRDs::error();
            die "$NOW: ERROR: Cannot create RRD ".join(',',@args)."- $e\n" if $e;
        } elsif ( -M $dotrrd > 0 ) {
            # update the minimum/maximum according to maxbytes/absmax
            # and (re)set the data-source-type to reflect cfg changes
            # cost: 1 read/write cycle, but update will reuse the buffered data
            # in daemon mode this will only happen in the first round
            my @args = ($dotrrd, '-a', "ds0:$absi", '-a', "ds1:$abso",
                       '-d', "ds0:$up_abs", '-d', "ds1:$up_abs");
            debug('log', "RRDs::tune(@args)");
            my $start = gettimeofday();
            RRDs::tune(@args);
	    debug('prof',sprintf("RRDs::tune $dotrrd - %.3fs",gettimeofday()-$start));
            my $e = RRDs::error();
            warn "$NOW: ERROR: Cannot tune logfile: $e\n" if $e;
        }
        # update the rrd
        $inlast  = 'U' unless defined $inlast  and $inlast  =~ /\S/ and $inlast  ne '##UNDEF##';
        $outlast = 'U' unless defined $outlast and $outlast =~ /\S/ and $outlast ne '##UNDEF##';
        debug('log', "RRDs::update($dotrrd, '$time:$inlast:$outlast')");
        my $start = gettimeofday();
	my $rrddata = 0;
	if ( $RRDs::VERSION >= 1.4 and $$cfg{rrdcached} ){
	    RRDs::update($dotrrd, '--daemon', $$cfg{rrdcached}, "$time:$inlast:$outlast");
            debug('prof',sprintf("RRDs::update $dotrrd (rrdcached) - %.3fs",gettimeofday()-$start));
            $rrddata = \{ dummy => "" };
	} elsif ( $RRDs::VERSION >= 1.2 ){
	    $rrddata=RRDs::updatev($dotrrd, "$time:$inlast:$outlast");
            debug('prof',sprintf("RRDs::updatev $dotrrd - %.3fs",gettimeofday()-$start));
        } else {
            RRDs::update($dotrrd, "$time:$inlast:$outlast");
        debug('prof',sprintf("RRDs::update $dotrrd - %.3fs",gettimeofday()-$start));
        }
        my $e = RRDs::error(); 
        warn "$NOW: ERROR: Cannot update $dotrrd with '$time:$inlast:$outlast' $e\n" if ($e);

	if ( $RRDs::VERSION < 1.2 ){
             # get the rrdtool-processed values back from rrdtool
             # for the threshold checks (we cannot use the fetched data)
	     $start = gettimeofday();
             my $info =  RRDs::info($dotrrd);
	     debug('prof',sprintf("RRDs::info $dotrrd - %.3fs",gettimeofday()-$start));
	     my $lasttime =  $info->{last_update} - $info->{last_update} % $info->{step};        
             debug('log', "RRDs::info($dotrrd)");
             $e = RRDs::error(); 
             warn "$NOW: ERROR: Cannot 'info' $dotrrd: $e\n" if ($e);
             $start = gettimeofday();
             my $fetch = (RRDs::fetch($dotrrd,'AVERAGE','-s',$lasttime-1,'-e',$lasttime))[3];
             debug('prof',sprintf("RRDs::fetch $dotrrd - %.3fs",gettimeofday()-$start));
             $e = RRDs::error(); 
             warn "$NOW: ERROR: Cannot 'fetch' $dotrrd: $e\n" if ($e);
             debug('log', "RRDs::fetch($dotrrd,'AVERAGE','-s',$lasttime,'-e',$lasttime)");        
             $cuin{d}{$router} = $fetch->[0][0];
             $cuout{d}{$router} = $fetch->[0][1];
	} elsif ( $RRDs::VERSION >= 1.4 and $$cfg{rrdcached} ){
             # Cannot check thresholds
        } elsif($rrddata) {
             my $utime = $time - ($time % int($cfg->{interval}*60));
	     $cuin{d}{$router} = $rrddata->{"[$utime]RRA[AVERAGE][1]DS[ds0]"};
	     $cuout{d}{$router} = $rrddata->{"[$utime]RRA[AVERAGE][1]DS[ds1]"};
	     $cuin{d_hwfail}{$router} = $rrddata->{"[$utime]RRA[FAILURES][1]DS[ds0]"};
	     $cuout{d_hwfail}{$router} = $rrddata->{"[$utime]RRA[FAILURES][1]DS[ds1]"};
        }
        my $in = defined $cuin{d}{$router} ?  $cuin{d}{$router} : "???" ;
        my $out = defined  $cuout{d}{$router} ? $cuout{d}{$router} : "???" ;
        debug('log', " got: $in/$out");
        # the html pages and the graphics are created at "call time" so that's it!
        # (the returned hashes are empty, it's just to minimize the changes to mrtg)
        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {  
            return (\%maxin, \%maxout, \%maxpercent, \%avin, \%avout, \%avpercent, \%cuin, \%cuout, \%cupercent,  \%avmxin, \%avmxout);
        }
        return (\%maxin, \%maxout, \%avin, \%avout, \%cuin, \%cuout, \%avmxin, \%avmxout );

    }                 
    ########## rrdtool users have left here ###############

    ((($MRTG_lib::OS eq 'NT' or $MRTG_lib::OS eq 'OS2') and (-e "${FindBin::Bin}${MRTG_lib::SL}rateup.exe")) or
     (($MRTG_lib::OS eq 'NW') and (-e "SYS:/Mrtg/bin/rateup.nlm")) or
     (-x "${FindBin::Bin}${MRTG_lib::SL}rateup")) or 
       die "$NOW: ERROR: Can't Execute '${FindBin::Bin}${MRTG_lib::SL}rateup'\n";

    # rateup does not know about undef so we make inlast and outlast ready for rateup
    #warn "$NOW: ERROR: inlast is undefined. Skipping $router\n" unless defined $inlast;
    #warn "$NOW: ERROR: outlast is undefined. Skipping $router\n" unless defined $outlast;
    #return undef unless defined $inlast and defined $outlast;


    # set values to -1 to tell rateup about unknown values    
    $inlast = -1 unless defined $inlast;
    $outlast = -1 unless defined $outlast;
    
    # untaint in and out
    if ($inlast =~ /^([-0-9.]+)$/) {
        $inlast = $1;
    }
    if ($outlast =~ /^([-0-9.]+)$/) {
        $outlast = $1;
    }

    if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
        @exec = ("${FindBin::Bin}${MRTG_lib::SL}rateup", 
                 "$$cfg{'logdir'}$$rcfg{'directory'}{$router}","$router",
                 $time, $$rcfg{'options'}{'unknaszero'}{$router} ? '-z':'-Z',
                 "$up_abs"."p", $inlast, $outlast, $absmax,
                 "C", $$rcfg{'rgb1'}{$router},$$rcfg{'rgb2'}{$router},
                 $$rcfg{'rgb3'}{$router},$$rcfg{'rgb4'}{$router},
                 $$rcfg{'rgb5'}{$router});
    } else { 

        @exec = ("${FindBin::Bin}${MRTG_lib::SL}rateup", 
                 "$$cfg{'logdir'}$$rcfg{'directory'}{$router}","$router",
                 $time, $$rcfg{'options'}{'unknaszero'}{$router} ? '-z':'-Z',
                 "$up_abs", $inlast, $outlast, $absmax,
                 "c", $$rcfg{'rgb1'}{$router},$$rcfg{'rgb2'}{$router},
                 $$rcfg{'rgb3'}{$router},$$rcfg{'rgb4'}{$router});
    }

    # If this list grows anymore would it be more efficient to have an
    # array to look up the command line option to send to rateup rather
    # than have a long list to check?
    push (@exec, '-t') if defined $$rcfg{'options'}{'transparent'}{$router};
    push (@exec, '-0') if defined $$rcfg{'options'}{'withzeroes'}{$router};
    push (@exec, '-b') if defined $$rcfg{'options'}{'noborder'}{$router};
    push (@exec, '-a') if defined $$rcfg{'options'}{'noarrow'}{$router};
    push (@exec, '-i') if defined $$rcfg{'options'}{'noi'}{$router};
    push (@exec, '-o') if defined $$rcfg{'options'}{'noo'}{$router};
    push (@exec, '-l') if defined $$rcfg{'options'}{'logscale'}{$router};
    push (@exec, '-x') if defined $$rcfg{'options'}{'expscale'}{$router};
    push (@exec, '-m') if defined $$rcfg{'options'}{'secondmean'}{$router};
    push (@exec, '-p') if defined $$rcfg{'options'}{'printrouter'}{$router};

    my $maxx = $$rcfg{'xsize'}{$router}; 
    my $maxy = $$rcfg{'ysize'}{$router};
    my $xscale = $$rcfg{'xscale'}{$router}; 
    my $yscale = $$rcfg{'yscale'}{$router}; 
    my $growright = 0+($$rcfg{'options'}{'growright'}{$router} or 0);
    my $bits = 0+($$rcfg{'options'}{'bits'}{$router} or 0);
    my $integer = 0+($$rcfg{'options'}{'integer'}{$router} or 0);
    my $step = 5*60; 
    my $rop;
    my $ytics = $$rcfg{'ytics'}{$router};
    my $yticsf= $$rcfg{'yticsfactor'}{$router};
    my $timestrfmt = $$rcfg{'timestrfmt'}{$router};
    my $timestrpos = ${MRTG_lib::timestrpospattern}{uc $$rcfg{'timestrpos'}{$router}};

    if (not defined $$rcfg{'ylegend'}{$router}){
	if ($bits){
	    $$rcfg{'ylegend'}{$router} = &$LOC("Bits per minute")
		if defined $$rcfg{'options'}{'perminute'}{$router};
	    $$rcfg{'ylegend'}{$router} = &$LOC("Bits per hour")	    
		if defined $$rcfg{'options'}{'perhour'}{$router};
	} else {
	    $$rcfg{'ylegend'}{$router} = &$LOC("Bytes per minute")
		if defined $$rcfg{'options'}{'perminute'}{$router};
	    $$rcfg{'ylegend'}{$router} = &$LOC("Bytes per hour")	    
		if defined $$rcfg{'options'}{'perhour'}{$router};
	}
    }
	
    if ($$rcfg{'ylegend'}{$router}) {
        push (@exec, "l", "[$$rcfg{'ylegend'}{$router}]");
    }
    my $sign = ($$rcfg{'unscaled'}{$router} and $$rcfg{'unscaled'}{$router} =~ /d/) ? 1 : -1;

    if ($$rcfg{'pngtitle'}{$router}) {
        push (@exec, "T", "[$$rcfg{'pngtitle'}{$router}]");
    }
  
    if ($$rcfg{'timezone'}{$router}) {
        push (@exec, "Z", "$$rcfg{'timezone'}{$router}");
    }
  
    if ($$rcfg{'kilo'}{$router}) {
        push (@exec, "k", $$rcfg{'kilo'}{$router});
    }
    if ($$rcfg{'kmg'}{$router}) { 
        push (@exec, "K", $$rcfg{'kmg'}{$router});
    }
    if ($$rcfg{'weekformat'}{$router}) {
        push (@exec, "W", $$rcfg{'weekformat'}{$router});
    }
    my $SAGE = (time - $main::STARTTIME) / 3600 / 24; # current script age 
    if (not defined $$opts{'log-only'}){
      if (not defined $$rcfg{'suppress'}{$router} or $$rcfg{'suppress'}{$router} !~ /d/) {
        # VMS: should work for both now
        push (@exec, "i", "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-day.${main::GRAPHFMT}",
              $sign*$maxvi, $sign*$maxvo, $maxx, $maxy, ,$xscale, $yscale, $growright, $step, $bits, $ytics, $yticsf, $timestrfmt, $timestrpos);
        @mxvls = ("d");
        push (@metas, "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-day.${main::GRAPHFMT}",
              $$cfg{'interval'});
       }
  

    if (((not -e "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-week.${main::GRAPHFMT}") or
         ((-M "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-week.${main::GRAPHFMT}") + $SAGE  >= 0.5/24)) and
        (not defined $$rcfg{'suppress'}{$router}  or $$rcfg{'suppress'}{$router} !~/w/)
       ) {
        $step=30*60;
        $sign = (defined $$rcfg{'unscaled'}{$router}  and $$rcfg{'unscaled'}{$router} =~ /w/) ? 1 : -1;
        push (@mxvls , "w");
        $rop =(defined $$rcfg{'withpeak'}{$router}  and $$rcfg{'withpeak'}{$router} =~ /w/) ? "p" : "i"; 
        push (@exec, $rop ,"$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-week.${main::GRAPHFMT}",
              $sign*$maxvi, $sign*$maxvo,  $maxx, $maxy, $xscale, $yscale, $growright, $step, $bits, $ytics, $yticsf, $timestrfmt, $timestrpos);
        push (@metas, "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-week.${main::GRAPHFMT}", 30);
    }
  

    if (((not -e "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-month.${main::GRAPHFMT}") or
         (( -M "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-month.${main::GRAPHFMT}") + $SAGE >= 2/24))  and
        (not defined  $$rcfg{'suppress'}{$router} or $$rcfg{'suppress'}{$router} !~ /m/)) {
        $step=2*60*60;
        $sign = (defined $$rcfg{'unscaled'}{$router} and $$rcfg{'unscaled'}{$router} =~ /m/) ? 1 : -1;
        push (@mxvls , "m");
        $rop =(defined $$rcfg{'withpeak'}{$router} and $$rcfg{'withpeak'}{$router} =~ /m/) ? "p" : "i"; 
        push (@exec, $rop ,"$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-month.${main::GRAPHFMT}",
              $sign*$maxvi, $sign*$maxvo, $maxx, $maxy, $xscale, $yscale, $growright, $step, $bits, $ytics, $yticsf, $timestrfmt, $timestrpos);
        push (@metas, "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-month.${main::GRAPHFMT}", 120);
    }
  
    if (((not -e "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-year.${main::GRAPHFMT}") or
         (( -M "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-year.${main::GRAPHFMT}") + $SAGE  >= 1)) and
        (not defined $$rcfg{'suppress'}{$router} or $$rcfg{'suppress'}{$router} !~/y/)) {
        $step=24*60*60;
        $sign = (defined $$rcfg{'unscaled'}{$router}  and $$rcfg{'unscaled'}{$router} =~ /y/) ? 1 : -1;
        push (@mxvls , "y");
        $rop =(defined $$rcfg{'withpeak'}{$router}  and $$rcfg{'withpeak'}{$router} =~ /y/) ? "p" : "i"; 
        push (@exec, $rop, "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-year.${main::GRAPHFMT}",
              $sign*$maxvi, $sign*$maxvo, $maxx, $maxy, $xscale, $yscale, $growright, $step, $bits, $ytics, $yticsf, $timestrfmt, $timestrpos);
        push (@metas, "$$cfg{'imagedir'}$$rcfg{'directory'}{$router}${router}-year.${main::GRAPHFMT}", 1440);
    }
  }

    # VMS: this might work now ... or does VMS NOT know about pipes?
    # NT doesn't have fork() so an open(xxx,"-|") won't work
    # OS2 fork() have bug with socket handles. In RunAsDaemon mode it fail
    # after first loop (with "socket operation on non socket" message.

    if ($MRTG_lib::OS eq 'VMS' or $MRTG_lib::OS eq 'NT' or $MRTG_lib::OS eq 'OS2'){
        map { s/"/\\"/; $_ = '"'.$_.'"' if /\s/ } @exec;
        open (RATEUP, join (" ", @exec)."|") or
           do {
                warn "$NOW: WARNING: rateup (".(join " ", @exec ).
                          ") did not work: $!\n";
                return;
           }
    } elsif ($MRTG_lib::OS eq 'NW'){
        map { s/"/\\"/; $_ = '"'.$_.'"' if /\s/ } @exec;

        # Stuff around because of Perl problems.

        open (NWPARMS, ">"."$$cfg{'imagedir'}$router.dat") or
           do {
                warn "$NOW: WARNING: Rateup parameters [$$cfg{'imagedir'}$router.dat] [open] failed.\n";

                return;
           };
        print NWPARMS join (" ", @exec);
        close NWPARMS;

        # Now run Rateup with path to Parameters.

        open (RATEUP, "SYS:/Mrtg/bin/rateup -f $$cfg{'imagedir'}$router.dat"."|") or
           do {
                warn "$NOW: WARNING: SYS:/Mrtg/bin/rateup -f $$cfg{'imagedir'}$router.dat did NOT work.\n";

                return;
           }
    } else {
        $! = undef;
        open (RATEUP,"-|") or  
                do { exec @exec or
                     warn "$NOW: WARNING: rateup (".(join " ", @exec ).
                          ") did not work: $!\n";
                };

    }
    
    debug('log', join(" ", @exec));


    if (open (HTML,"<$$cfg{'htmldir'}$$rcfg{'directory'}{$router}$router.$$rcfg{'extension'}{$router}")) {
        for ($i=0 ; $i<200 ; $i++) {
            last if eof(HTML);
            $_= <HTML>;
            if (/<!-- maxin ([dwmy]) (\d*)/) {
                $maxin{$1}{$router}=$2 || 0;
            }

            if (/<!-- maxout ([dwmy]) (\d*)/) {
                $maxout{$1}{$router}=$2 || 0;
            }

            if (/<!-- maxpercent ([dwmy]) (\d*)/) {
                $maxpercent{$1}{$router}=$2 || 0;
            }

            if (/<!-- avin ([dwmy]) (\d*)/) {
                $avin{$1}{$router}=$2 || 0;
            }

            if (/<!-- avout ([dwmy]) (\d*)/) {
                $avout{$1}{$router}=$2 || 0;
            }

            if (/<!-- avpercent ([dwmy]) (\d*)/) {
                $avpercent{$1}{$router}=$2 || 0;
            }

            if (/<!-- cuin ([dwmy]) (\d*)/) {
                $cuin{$1}{$router}=$2 || 0;
            }

            if (/<!-- cuout ([dwmy]) (\d+)/) {
                $cuout{$1}{$router}=$2 || 0;
            }
     
            if (/<!-- cupercent ([dwmy]) (\d+)/) {
                $cupercent{$1}{$router}=$2 || 0;
            }
            if (/<!-- avmxin ([dwmy]) (\d*)/) {
                $avmxin{$1}{$router}=$2 || 0;
            }

            if (/<!-- avmxout ([dwmy]) (\d*)/) {
                $avmxout{$1}{$router}=$2 || 0;
            }
        }
        close HTML;
    }
  
    foreach $period (@mxvls) {
        $res = <RATEUP>; 
        if (not defined $res and eof(RATEUP)){
            warn "$NOW: ERROR: Skipping webupdates because rateup did not return anything sensible\n";
            close RATEUP;
            rateupcheck $router;
            return;
        };
        chomp $res;
        $maxin{$period}{$router}=sprintf("%.0f",$res || 0);
        chomp($res = <RATEUP>); 
        $maxout{$period}{$router}=sprintf("%.0f",$res || 0);

        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
            chomp($res = <RATEUP>); 
            $maxpercent{$period}{$router}=sprintf("%.0f",$res || 0);
        }

        chomp($res = <RATEUP>); 
        $avin{$period}{$router}=sprintf("%.0f",$res || 0);
        chomp($res = <RATEUP>); 
        $avout{$period}{$router}=sprintf("%.0f",$res || 0);

        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
            chomp($res = <RATEUP>); 
            $avpercent{$period}{$router}=sprintf("%.0f",$res || 0);
        }

        chomp($res = <RATEUP>); 
        $cuin{$period}{$router}=sprintf("%.0f",$res || 0);
        chomp($res = <RATEUP>); 
        $cuout{$period}{$router}=sprintf("%.0f",$res || 0);

        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
            chomp($res = <RATEUP>); 
            $cupercent{$period}{$router}=sprintf("%.0f",$res || 0);
        }

        chomp($res = <RATEUP>);
        debug('avmx',"avmxin  $res");        
        $avmxin{$period}{$router}=sprintf("%.0f",$res || 0);     
        chomp($res = <RATEUP>);
        debug('avmx',"avmxout $res");        
        $avmxout{$period}{$router}=sprintf("%.0f",$res || 0);     
        
    }
    close(RATEUP);
    rateupcheck $router;
    if ( defined $$cfg{'writeexpires'}  and $$cfg{'writeexpires'} =~ /^y/i ) {
        my($fil,$exp);
        while ( $fil = shift(@metas) ) {
            $exp = &expistr(shift(@metas));
            open(META, ">$fil.meta");
            print META "Expires: $exp\n";
            close(META);
        }
    }

    if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
        return (\%maxin, \%maxout, \%maxpercent, \%avin, \%avout, \%avpercent, \%cuin, \%cuout, \%cupercent, \%avmxin, \%avmxout);
    } else {
        return (\%maxin, \%maxout, \%avin, \%avout, \%cuin, \%cuout, \%avmxin, \%avmxout);
    }
}

#format 10*$kilo to 10 kB/s
sub fmi {
    my($number, $maxbytes, $router, @foo) = @_;
    return "?????" unless defined $number;
    my($rcfg,$LOC)=@foo;
    my @short= ();
    my $mul = 1;
    if ($$rcfg{'kmg'}{$router}) {
        my($i);
        if (defined $$rcfg{'shortlegend'}{$router}) {
            foreach $i (split(/,/, $$rcfg{'kmg'}{$router})) {
                $short[$#short+1] = "$i"."$$rcfg{'shortlegend'}{$router}";
            }
        }
        elsif ($$rcfg{'options'}{'bits'}{$router}) {
            foreach $i (split(/,/, $$rcfg{'kmg'}{$router})) {
                if ($$rcfg{'options'}{'perminute'}{$router}) {
                    $short[$#short+1] = "$i".&$LOC("b/min");
                } elsif ($$rcfg{'options'}{'perhour'}{$router}) {
                    $short[$#short+1] = "$i".&$LOC("b/h");
                } else {
                    $short[$#short+1] = "$i".&$LOC("b/s");
                }
            }
            $mul= 8;
        } else {
            foreach $i (split(/,/, $$rcfg{'kmg'}{$router})) {
                if ($$rcfg{'options'}{'perminute'}{$router}) {
                    $short[$#short+1] = "$i".&$LOC ("B/min");
                } elsif ($$rcfg{'options'}{'perhour'}{$router}) {
                    $short[$#short+1] = "$i".&$LOC("B/h");
                } else {
                    $short[$#short+1] = "$i".&$LOC("B/s");
                }
            }
            $mul= 1;
        }
    } else {
        if (defined $$rcfg{'options'}{'bits'}{$router}) {
            if ($$rcfg{'options'}{'perminute'}{$router}) {
                @short = (&$LOC("b/min"),&$LOC("kb/min"),&$LOC("Mb/min"),&$LOC("Gb/min"));
            } elsif (defined $$rcfg{'options'}{'perhour'}{$router}) {
                @short = (&$LOC("b/h"),&$LOC("kb/h"),&$LOC("Mb/h"),&$LOC("Gb/h"));
            } else {
                @short = (&$LOC("b/s"),&$LOC("kb/s"),&$LOC("Mb/s"),&$LOC("Gb/s"));
            }
            $mul= 8;
        } else {
            if ($$rcfg{'options'}{'perminute'}{$router}) {
                @short = (&$LOC("B/min"),&$LOC("kB/min"),&$LOC("MB/min"),&$LOC("GB/min"));
            } elsif ($$rcfg{'options'}{'perhour'}{$router}) {
                @short = (&$LOC("B/h"),&$LOC("kB/h"),&$LOC("MB/h"),&$LOC("GB/h"));
            } else {
                @short = (&$LOC("B/s"),&$LOC("kB/s"),&$LOC("MB/s"),&$LOC("GB/s"));
            }
            $mul= 1;
        }
        if ($$rcfg{'shortlegend'}{$router}) {
            @short = ("$$rcfg{'shortlegend'}{$router}",
                      "k$$rcfg{'shortlegend'}{$router}",
                      "M$$rcfg{'shortlegend'}{$router}",
                      "G$$rcfg{'shortlegend'}{$router}");
        }
    }
    my $digits=length("".$number*$mul);
    my $divm=0;
    #
    #  while ($digits-$divm*3 > 4) { $divm++; }
    #  my $divnum = $number*$mul/10**($divm*3);
    my $divnum=$number*$mul*$$rcfg{'factor'}{$router};
    #  while ($divnum/$$rcfg{'kilo'}{$router} >= 10*$$rcfg{'kilo'}{$router} and $divnum<$#short) {
    while (($divnum >= 10*$$rcfg{'kilo'}{$router} or $short[$divm] =~ /^-/) and
           $divm<$#short) {
        $divm++;
        $divnum /= $$rcfg{'kilo'}{$router};
    }
    my $perc;
    if ($number == 0 || $maxbytes == 0) {
        $perc = 0;
    } else {
        $perc = 100/$maxbytes*$number;
    }
    if (defined $$rcfg{'options'}{'integer'}{$router}) {
        if ($$rcfg{'options'}{'nopercent'}{$router}) {
            return sprintf("%.0f %s",$divnum,$short[$divm]);
        } else {
            return sprintf("%.0f %s (%2.1f%%)",$divnum,$short[$divm],$perc);
        }
    } else {
        if (defined $$rcfg{'options'}{'nopercent'}{$router}) {
            return sprintf("%.1f %s",$divnum,$short[$divm]); # Added: FvW
        } else {
            return sprintf("%.1f %s (%2.1f%%)",$divnum,$short[$divm],$perc);
        }
        return sprintf("%.1f %s (%2.1f%%)",$divnum,$short[$divm],$perc);
    }
}


sub writehtml {
    my($router, $cfg, $rcfg, $maxin, $maxout, $maxpercent,
       $avin, $avout, $avmxin, $avmxout, $avpercent, 
       $cuin, $cuout, $cupercent, $uptime, $name, $LOC) = @_;
  
    my($VERSION,$Today,$peri);
  
    my($persec);

    if (defined $$rcfg{'options'}{'bits'}{$router}) {
        $persec = &$LOC("Bits");
    } else {
        $persec = &$LOC("Bytes");
    }

    #  Work out the Colour legend
    my($leg1, $leg2, $leg3, $leg4, $leg5);
    if ($$rcfg{'legend1'}{$router}) {
        $leg1 = $$rcfg{'legend1'}{$router};
    } else {
        if ($$rcfg{'options'}{'perminute'}{$router}) {
            $leg1=&$LOC("Incoming Traffic in $persec per Minute");
        } elsif ($$rcfg{'options'}{'perhour'}{$router}) {
            $leg1=&$LOC("Incoming Traffic in $persec per Hour");
        } else {
            $leg1=&$LOC("Incoming Traffic in $persec per Second");
        }
    }
    if ($$rcfg{'legend2'}{$router}) {
        $leg2 = $$rcfg{'legend2'}{$router};
    } else {
        if ($$rcfg{'options'}{'perminute'}{$router}) {
            $leg2=&$LOC("Outgoing Traffic in $persec per Minute");
        } elsif ($$rcfg{'options'}{'perhour'}{$router}) {
            $leg2=&$LOC("Outgoing Traffic in $persec per Hour");
        } else {
            $leg2=&$LOC("Outgoing Traffic in $persec per Second");
        }	
    }
    if ($$rcfg{'legend3'}{$router}) {
        $leg3 = $$rcfg{'legend3'}{$router};
    } else {
        $leg3 = &$LOC("Maximal 5 Minute Incoming Traffic");
    }
    if ($$rcfg{'legend4'}{$router}) {
        $leg4 = $$rcfg{'legend4'}{$router};
    } else {
        $leg4 = &$LOC("Maximal 5 Minute Outgoing Traffic");
    }
    if ($$rcfg{'legend5'}{$router}) {
        $leg5 = $$rcfg{'legend5'}{$router};
    } else {
        $leg5 = "(($leg1)/($leg2))*100";
    }
    # Translate the color names
    $$rcfg{'col1'}{$router}=&$LOC($$rcfg{'col1'}{$router});
    $$rcfg{'col2'}{$router}=&$LOC($$rcfg{'col2'}{$router});
    $$rcfg{'col3'}{$router}=&$LOC($$rcfg{'col3'}{$router});
    $$rcfg{'col4'}{$router}=&$LOC($$rcfg{'col4'}{$router});
    $$rcfg{'col5'}{$router}=&$LOC($$rcfg{'col5'}{$router});

    my $dirrel = "../" x ($$rcfg{'directory_web'}{$router} =~ tr|/|/|);

    $Today=&$LOC(datestr(time));
    $VERSION = "2.17.3";
    open (HTML,">$$cfg{'htmldir'}$$rcfg{'directory'}{$router}$router.$$rcfg{'extension'}{$router}") || 
      do { warn ("$NOW: WARNING: Writing $router.$$rcfg{'extension'}{$router}: $!");
      	   next };
    # this unforutnately confuses IE greatly ... so we have to comment
    # it out for now ... :-(
    # print HTML '<?xml version="1.0" encoding="' . &$LOC('iso-8859-1') . '"?>' . "\n";
    print HTML '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/dtd/xhtml11.dtd">' . "\n";
    print HTML "<html>\n";
    my $interval =$$cfg{'interval'};
    my $expiration = &expistr($interval);
    my $refresh =  defined $$cfg{'refresh'} ? $$cfg{'refresh'} : 300;
    my $namestring = &$LOC("the device");  
    print HTML "<!-- Begin Head -->\n";
    print HTML <<"TEXT";    
	<head>
		<title>$$rcfg{'title'}{$router}</title>
		<meta http-equiv="refresh" content="$refresh" />
		<meta http-equiv="pragma" content="no-cache" />
		<meta http-equiv="cache-control" content="no-cache" />
		<meta http-equiv="expires" content="$expiration" />
		<meta http-equiv="generator" content="MRTG $VERSION" />
		<meta http-equiv="date" content="$expiration" />
TEXT
    print HTML "\t\t" . '<meta http-equiv="content-type" content="text/html; charset='.&$LOC('iso-8859-1') . "\" />\n";

    foreach $peri (qw(d w m y)) {
        print HTML <<"TEXT";
<!-- maxin $peri $$maxin{$peri}{$router} -->
<!-- maxout $peri $$maxout{$peri}{$router} -->
TEXT
        if ($$rcfg{'options'}{'dorelpercent'}{$router} and defined $$maxpercent{$peri}{$router}) {
            print HTML <<"TEXT";
<!-- maxpercent $peri $$maxpercent{$peri}{$router} -->
TEXT
        }
        print HTML <<"TEXT";
<!-- avin $peri $$avin{$peri}{$router} -->
<!-- avout $peri $$avout{$peri}{$router} -->
TEXT
        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
            print HTML <<"TEXT";
<!-- avpercent $peri $$avpercent{$peri}{$router} -->
TEXT
        }
        
        print HTML "<!-- cuin $peri $$cuin{$peri}{$router} -->\n"
           if defined $$cuin{$peri}{$router};
        print HTML "<!-- cuout $peri $$cuout{$peri}{$router} -->\n"
           if defined $$cuout{$peri}{$router};

        if ($$rcfg{'options'}{'dorelpercent'}{$router} and $$cupercent{$peri}{$router} ) {
            print HTML <<"TEXT";
<!-- cupercent $peri $$cupercent{$peri}{$router} -->
TEXT
        }
        print HTML <<"TEXT" if  $$avmxin{$peri}{$router} and $$avmxout{$peri}{$router};
<!-- avmxin $peri $$avmxin{$peri}{$router} -->
<!-- avmxout $peri $$avmxout{$peri}{$router} -->
TEXT

    }

    $namestring = "<strong>'$name'</strong>" if $name;

    defined $$rcfg{backgc}{$router} or $$rcfg{backgc}{$router} = "#fff";

    $$rcfg{'rgb1'}{$router} = "" unless defined $$rcfg{'rgb1'}{$router};
    $$rcfg{'rgb2'}{$router} = "" unless defined $$rcfg{'rgb2'}{$router};
    $$rcfg{'rgb3'}{$router} = "" unless defined $$rcfg{'rgb3'}{$router};
    $$rcfg{'rgb4'}{$router} = "" unless defined $$rcfg{'rgb4'}{$router};
    $$rcfg{'rgb5'}{$router} = "" unless defined $$rcfg{'rgb5'}{$router};
    $$rcfg{'rgb6'}{$router} = "" unless defined $$rcfg{'rgb6'}{$router};

    print HTML "
		<style type=\"text/css\">
			body {
				background-color: $$rcfg{'backgc'}{$router};
			}
			div {
				border-bottom: 2px solid #aaa;
				padding-bottom: 10px;
				margin-bottom: 5px;
			}
			div h2 {
				font-size: 1.2em;
			}
			div.graph img {
				margin: 5px 0;
			}
			div.graph table, div#legend table {
				font-size: .8em;
			}
			div.graph table td {
				padding: 0 10px;
				text-align: right;
			}
			div table .in th, div table td span.in {
				color: $$rcfg{'rgb1'}{$router};
			}
			div table .out th, div table td span.out {
				color: $$rcfg{'rgb2'}{$router};
			}";

	 print HTML "
			div table .inpeak th {
				color: $$rcfg{'rgb3'}{$router};
			}
			div table .outpeak th {
				color: $$rcfg{'rgb4'}{$router};
			} " if defined $rcfg->{withpeak}{$router};

    print HTML "
			div table .relpercent th {
				color: $$rcfg{'rgb5'}{$router};
			}" if ( $$rcfg{'options'}{'dorelpercent'}{$router} );
	 
    print HTML "
			div#legend th {
				text-align: right;
			}
			div#footer {
				border: none;
				font-size: .8em;
				font-family: Arial, Helvetica, sans-serif;
				width: 476px;
			}
			div#footer img {
				border: none;
				height: 25px;
			}
			div#footer address {
				text-align: right;
			}
			div#footer #version {
				margin: 0;
				padding: 0;
				float: left;
				width: 88px;
				text-align: right;
			}
		</style>";

    # allow for \n in addhead
    defined $$rcfg{addhead}{$router} or $$rcfg{addhead}{$router} = "";
    defined $$rcfg{pagetop}{$router} or $$rcfg{pagetop}{$router} = "";

    if (defined $$rcfg{bodytag}{$router}) {
        if ($$rcfg{bodytag}{$router} !~ /<body/i) {
                $$rcfg{bodytag}{$router} = "<body $$rcfg{bodytag}{$router}>";
        }
    } else {
        $$rcfg{bodytag}{$router} = "<body>";
    }

    $$rcfg{addhead}{$router} =~ s/\\n/\n/g if defined $$rcfg{addhead}{$router};

    print HTML "
$$rcfg{'addhead'}{$router}
	</head>
$$rcfg{bodytag}{$router}
$$rcfg{'pagetop'}{$router}";
    print HTML "<p>";
    if (defined $$rcfg{'timezone'}{$router}){    
    print HTML     
      &$LOC("The statistics were last updated <strong>$Today $$rcfg{'timezone'}{$router}</strong>");
    } else {
    print HTML     
      &$LOC("The statistics were last updated <strong>$Today</strong>");
    }
    if ($uptime and ! $$rcfg{options}{noinfo}{$router}) {
        print HTML
          ",<br />\n".
        &$LOC("at which time $namestring had been up for <strong>$uptime</strong>.")
    }
    print HTML "</p>\n<!-- End Head -->";
   
    my %sample= ('d' => "`Daily' Graph (".$interval.' Minute',
                 'w' => "`Weekly' Graph (30 Minute",
                 'm' => "`Monthly' Graph (2 Hour",
                 'y' => "`Yearly' Graph (1 Day");
  
    my %full = ('d' => 'day',
                'w' => 'week',
                'm' => 'month',
                'y' => 'year');
  
    my $InCo;
    if (!(defined $$rcfg{'options'}{'noi'}{$router})) {
    if (exists $$rcfg{'legendi'}{$router}) {
        if ($$rcfg{'legendi'}{$router} ne "") {
            $InCo=$$rcfg{'legendi'}{$router};
        }
    } else {
        $InCo=&$LOC("In");
    }
    }
    
    my $OutCo;
    if (!(defined $$rcfg{'options'}{'noo'}{$router})) {
    if (exists $$rcfg{'legendo'}{$router}) {
        if ($$rcfg{'legendo'}{$router} ne "") {
            $OutCo=$$rcfg{'legendo'}{$router};
        }
    } else {
        $OutCo=&$LOC("Out");
    }
    }
    my $PercentCo;
    if (defined $$rcfg{'legend5'}{$router}) {
        if ($$rcfg{'legend5'}{$router} ne "") {
            $PercentCo=$$rcfg{'legend5'}{$router};
        }
    } else {
        $PercentCo=&$LOC("Percentage");
    }
  
    foreach $peri (qw(d w m y)) {
        next if defined $$rcfg{'suppress'}{$router} and $$rcfg{'suppress'}{$router} =~/$peri/;
        my $gifw;
        if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
            $gifw=sprintf("%.0f",($$rcfg{'xsize'}{$router}*$$rcfg{'xscale'}{$router}+
                                  +100+30) *$$rcfg{'xzoom'}{$router});
        } else {
            $gifw=sprintf("%.0f",($$rcfg{'xsize'}{$router}*$$rcfg{'xscale'}{$router}
                                  +100) *$$rcfg{'xzoom'}{$router});
        }
        my $gifh=sprintf("%.0f",($$rcfg{'ysize'}{$router}*$$rcfg{'yscale'}{$router}+35)
                         *$$rcfg{'yzoom'}{$router});
                 
        # take the image directory away from the html directory to give us relative links


	my $imagepath = ( $cfg->{htmldir} ne $cfg->{imagedir} ) ? "$dirrel$$cfg{imagehtml}$$rcfg{directory_web}{$router}" : "";
        print HTML "
<!-- Begin $sample{$peri} interval) -->
		<div class=\"graph\">
			<h2>".&$LOC("$sample{$peri}").&$LOC(' Average)')."</h2>
			<img src=\"$imagepath$router-$full{$peri}.${main::GRAPHFMT}\" title=\"$full{$peri}\" alt=\"$full{$peri}\" />
			<table>
				<tr>
					<th></th>
					<th scope=\"col\">" . &$LOC("Max") . "</th>
					<th scope=\"col\">" . &$LOC("Average") . "</th>
					<th scope=\"col\">" . &$LOC("Current") . "</th>
				</tr>";
        my(@foo)=($rcfg,$LOC);
        print HTML "
				<tr class=\"in\">
					<th scope=\"row\">" . $InCo . "</th>
					<td>".&fmi($$maxin{$peri}{$router}, $$rcfg{'maxbytes1'}{$router}, $router, @foo)."</td>
					<td>".&fmi($$avin{$peri}{$router}, $$rcfg{'maxbytes1'}{$router}, $router, @foo)." </td>
					<td>".&fmi($$cuin{$peri}{$router}, $$rcfg{'maxbytes1'}{$router}, $router, @foo)." </td>
				</tr>" if $InCo;
        print HTML "
				<tr class=\"out\">
					<th scope=\"row\">" . $OutCo . "</th>
					<td>".&fmi($$maxout{$peri}{$router}, $$rcfg{'maxbytes2'}{$router}, $router, @foo)." </td>
					<td>".&fmi($$avout{$peri}{$router}, $$rcfg{'maxbytes2'}{$router}, $router, @foo)." </td>
					<td>".&fmi($$cuout{$peri}{$router}, $$rcfg{'maxbytes2'}{$router}, $router, @foo)." </td>
				</tr>" if $OutCo;
        print HTML "
				<tr class=\"relpercent\">
					<th scope=\"row\">" . $PercentCo . "</th>
					<td>".sprintf("%0.1f %%",($$maxpercent{$peri}{$router} || 0))." </td>
					<td>".sprintf("%0.1f %%",($$avpercent{$peri}{$router} || 0 ))." </td>
					<td>".sprintf("%0.1f %%",($$cupercent{$peri}{$router} || 0 ))." </td>
				</tr>" if ($$rcfg{'options'}{'dorelpercent'}{$router} and $PercentCo);
print HTML "
				<tr>
					<td colspan=\"8\">
						" . &$LOC("Average max 5 min values for $sample{$peri} interval):") . "
						<span class=\"in\">$InCo</span> " . &fmi($$avmxin{$peri}{$router}, $$rcfg{'maxbytes1'}{$router}, $router, @foo) . "/
						<span class=\"out\">$OutCo</span> " . &fmi($$avmxout{$peri}{$router}, $$rcfg{'maxbytes2'}{$router}, $router, @foo) . "
					</td>
				</tr>" if ($$rcfg{'options'}{'avgpeak'}{$router} and $InCo and $OutCo);
        print HTML "
			</table>
		</div>
<!-- End $sample{$peri} interval) -->\n";
}

    if (!(defined $$rcfg{'options'}{'nolegend'}{$router})) {
    print HTML "
<!-- Begin Legend -->
		<div id=\"legend\">
			<table>";
    print HTML "
				<tr class=\"in\">
					<th scope=\"row\">$$rcfg{'col1'}{$router} ###</th>
					<td>$leg1</td>
				</tr>" if $InCo;
    print HTML "
				<tr class=\"out\">
					<th scope=\"row\">$$rcfg{'col2'}{$router} ###</th>
					<td>$leg2</td>
				</tr>" if $OutCo;
    if ($$rcfg{'withpeak'}{$router}) {
        print HTML "
				<tr class=\"inpeak\">
					<th scope=\"row\">$$rcfg{'col3'}{$router} ###</th>
					<td>$leg3</td>
				</tr>" if $InCo;
        print HTML "
				<tr class=\"outpeak\">
					<th scope=\"row\">$$rcfg{'col4'}{$router} ###</th>
					<td>$leg4</td>
				</tr>" if $OutCo;
    }
    if ($$rcfg{'options'}{'dorelpercent'}{$router}) {
        print HTML "
				<tr class=\"relpercent\">
					<th scope=\"row\">$$rcfg{'col5'}{$router} ###</th>
					<td>$leg5</td>
				</tr>";
    }
        print HTML "
			</table>
		</div>
<!-- End Legend -->";
    }

    if (!(defined $$rcfg{'options'}{'nobanner'}{$router})) {
    my $gifPath;

    if (defined $$cfg{icondir}) {
        $gifPath = $$cfg{icondir};
        #lets make sure there is a trailing path separator
        $gifPath =~ s|/*$|/|;
    } else {
	$gifPath = "$dirrel$$cfg{imagehtml}";
    }

    print HTML<<TEXT;
<!-- Begin MRTG Block -->
		<div id="footer">
			<a href="http://oss.oetiker.ch/mrtg/"><img src="${gifPath}mrtg-l.${main::GRAPHFMT}" width="63" title="MRTG" alt="MRTG" /><img src="${gifPath}mrtg-m.${main::GRAPHFMT}" width="25" title="MRTG" alt="MRTG" /><img src="${gifPath}mrtg-r.${main::GRAPHFMT}" width="388" title="Multi Router Traffic Grapher" alt="Multi Router Traffic Grapher" /></a>
			<p id="version">$VERSION</p>
			<address>
				<a href="http://tobi.oetiker.ch/">Tobias Oetiker</a>
				<a href="mailto:tobi+mrtglink\@oetiker.ch">&lt;tobi\@oetiker.ch&gt;</a><br />
TEXT
    print HTML &$LOC("and");
    print HTML<<TEXT;
				<a href="http://www.bungi.com/">Dave Rand</a>
				<a href="mailto:dlr\@bungi.com">&lt;dlr\@bungi.com&gt;</a>
TEXT

    # We don't need this any more.
    undef $gifPath;

    if ($MRTG_lib::OS eq 'VMS') {
        print HTML "<br />
				".&$LOC("Ported to OpenVMS Alpha by")." <a href=\"http://www.cerberus.ch/\">Werner Berger</a>
				<a href=\"mailto:werner.berger\@cch.cerberus.ch\">&lt;werner.berger\@cch.cerberus.ch&gt;</a>";
    }
# There is not realy any significant portion of code from Studard left and
# none of his addresses work anymore. -- Tobi  2001-06-04
#    if ($MRTG_lib::OS eq 'NT') {
#        print HTML 
#          "<div>
#  ".&$LOC("Ported to WindowsNT by")."
#  <NOBR><small><A HREF=\"http://www.testlab.orst.edu/\">Stuart Schneider</A>
#  <A HREF=\"mailto:schneis\@testlab.orst.edu\">
#  &lt;schneis\@testlab.orst.edu&gt;</A></NOBR></div>
# ";
#    }
    if ( 
        $$cfg{'language'} and 
        defined($lang2tran::LOCALE{"\L$$cfg{'language'}\E"}) and
        ($LOC != $lang2tran::LOCALE{"default"})) 
    {
        if (defined($credits::LOCALE{"\L$$cfg{'language'}\E"})) {
            print HTML "<br />
				".$credits::LOCALE{"\L$$cfg{'language'}\E"};
        } else {
            print HTML "<br />
				".$credits::LOCALE{'default'};
        }
        ;
    }
    print HTML <<TEXT
			</address>
		</div>
		<!-- End MRTG Block -->
TEXT
    }

    print HTML $$rcfg{'pagefoot'}{$router} if defined $$rcfg{'pagefoot'}{$router};
    print HTML <<TEXT;
	</body>
</html>

TEXT
    close HTML;

    if (defined $$cfg{'writeexpires'}  and $$cfg{'writeexpires'} =~ /^y/i) {
        open(HTMLG, ">$$cfg{'htmldir'}$$rcfg{'directory'}{$router}$router.".
	     "$$rcfg{'extension'}{$router}.meta") ||
	       do {
		   warn "$NOW: WARNING: Writing $$cfg{'htmldir'}$$rcfg{'directory'}{$router}$router.".
		     "$$rcfg{'extension'}{$router}.meta: $!\n";
		   next
	       };

        print HTMLG "Expires: $expiration\n";
        close(HTMLG);
    }
}


sub printusage {
    print <<USAGEDESC;
Usage: mrtg <config-file>

mrtg-2.17.3 - Multi Router Traffic Grapher

Copyright 1995-2006 by Tobias Oetiker
Licensed under the Gnu GPL.

If you want to know more about this tool, you might want
to read the docs. You can find everything on the
mrtg website:

http://oss.oetiker.ch/mrtg/

USAGEDESC
    exit(1);
}


sub lockit {
    my ($lockfile,$templock) = @_;
    if ($MRTG_lib::OS eq 'VMS' or $MRTG_lib::OS eq 'NT'  or $MRTG_lib::OS eq 'OS2') {
        # too sad NT and VMS can't do links we'll do the diletants lock
        if (-e $lockfile and not unlink $lockfile) {
            my($lockage) = time()-(stat($lockfile))[9];
            die "$NOW: ERROR: I guess another mrtg is running. A lockfile ($lockfile)\n".
                 "       aged $lockage seconds is hanging around and I can't remove\n".
                 "       it because another process is still using it.";
        }
      
        open (LOCK, ">$lockfile") or 
          die "$NOW: ERROR: Creating lockfile $lockfile: $!\n";
        print LOCK "$$\n";
        close LOCK;
        open (LOCK, "<$lockfile") or 
          die "$NOW: ERROR: Reading lockfile $lockfile for owner check: $!\n";
        my($read)=<LOCK>;
        chomp($read);
        die "$NOW: ERROR: Someone else just got the lockfile $lockfile\n" 
          unless  $$ == $read;
    } else {
        # now, lets do it the UNIX way ... Daves work ...
        open(LOCK,">$templock") or die "$NOW: ERROR: Creating templock $templock: $!";
        $main::Cleanfile = $templock;
        if (!link($templock,$lockfile)) { # Lock file exists - deal with it.
            my($nlink,$lockage) = (stat($lockfile))[3,9]; 
            $lockage = time() - $lockage;
            if ($nlink < 2 or $lockage > 30*60) { #lockfile is alone and old
                unlink($lockfile) 
                  || do{ unlink $templock; 
                         die "$NOW: ERROR: Can't unlink stale lockfile ($lockfile). Permissions?\n"};
                link($templock,$lockfile) 
                  || do{ unlink $templock; 
                         die "$NOW: ERROR: Can't create lockfile ($lockfile).\n".
                           "Permission problem or another mrtg locking succesfully?\n"};
            } else {
                unlink $templock;
                die "$NOW: ERROR: It looks as if you are running two copies of mrtg in parallel on\n".
                    "       the same config file. There is a lockfile ($lockfile) and it is\n".
                    "       is only $lockage seconds old ... Check your crontab.\n".
                    "       (/etc/crontab and /var/spool/cron/root) \n"
                        if $lockage < 4;
      
                die  "$NOW: ERROR: I guess another mrtg is running. A lockfile ($lockfile) aged\n".
                     "$lockage seconds is hanging around. If you are sure that no other mrtg\n".
                     "is running you can remove the lockfile\n";
          
            }
        
        }
    }
}

sub threshmail ($$$$){
    my $server = shift;
    my $from = shift;
    my $to = shift;
    my $message = shift;
    debug('base',"sending threshmail from $from to $to");
    my $smtp = Net::SMTP->new([split /\s*,\s*/, $server],Timeout=>5) or
	do { warn "$NOW: ERROR: could not send thresholdmail to $to"; return };
    $smtp->mail($from);
    $smtp->to(split(/\s*,\s*/, $to));
    $smtp->data();
    $smtp->datasend($message);
    $smtp->dataend();
    $smtp->quit;
}   

sub threshcheck {
    # threshold checking by Tom Muggli
    # ... fsck'd up but fixed by Juha Laine
    my ($cfg,$rcfg,$cfgfile,$router,$cuin,$cuout) = @_;
    my $threshfile;
    my %cu = ( i=> $cuin, o=>$cuout );
    # are we going to keep state ?
    if (defined $$cfg{'threshdir'}){
        ensureSL(\$$cfg{'threshdir'});
        $threshfile = $$cfg{'threshdir'}.(split /\Q$MRTG_lib::SL\E/, $cfgfile)[-1].".$router";
    }

    # setup environment for external scripts
    if (defined $rcfg->{'threshdesc'}{$router}) {
        $ENV{THRESH_DESC}=$rcfg->{'threshdesc'}{$router};
    } else {
        delete $ENV{THRESH_DESC};
    }
    if (defined $rcfg->{'hwthreshdesc'}{$router}) {
        $ENV{HWTHRESH_DESC}=$rcfg->{'hwthreshdesc'}{$router};
    } else {
        delete $ENV{HWTHRESH_DESC};
    }

    for my $dir (qw(i o)){ # in and out
        my %thresh = (
                thresh => $cu{$dir}{d}{$router},
                
        # if we are looking at an rrd with holtwinters RRAs
        # we get a failures count.
                hwthresh => $cu{$dir}{d_hwfail}{$router}
        );
        for my $type (keys %thresh){
            my $threshval = $thresh{$type};
            next if not defined $threshval;
            for my $bound (qw(min max)){
	            # skip unless a threshold is defined for this "$router"
                my $boundval = $rcfg->{$type.$bound.$dir}{$router};
                next unless defined $boundval;
    
                my $realval = "";
    	        my $realthresh = "";
    
                if ($boundval =~ s/%$//) { # defined in % of maxbytes
                    # 2 decimals in %   
        		    $realval = "% ($threshval)";
	                $realthresh = "% (".sprintf("%.1f",($rcfg->{"maxbytes".($dir eq 'i' ? 1 : 2)}{$router} * $boundval / 100)).")";
                    $threshval = sprintf "%.1f", ($threshval / $rcfg->{"maxbytes".($dir eq 'i' ? 1 : 2)}{$router} * 100); # the new code
                }
    	        my $msghead = "";
                $msghead = "From: $cfg->{threshmailsender}\nTo: $rcfg->{${type}.'mailaddress'}{$router}"
	    	        if $rcfg->{${type}.'mailaddress'}{$router} and $cfg->{threshmailsender};
    	        my $pagetop = $rcfg->{pagetop}{$router} || '';
    	        $pagetop =~ s|<h1>.*?</h1>||;
                $pagetop =~ s|\s*<tr>\s*<td>(.*?)</td>\s*<td>(.*?)</td>\s*</tr>\s*|$1 $2\n|g;
	        $pagetop =~ s|\s*<.+?>\s*\n?||g;

         	my $msgbody = <<MESSAGE;
    
$rcfg->{title}{$router}

   Target: $router
     Type: $type
Direction: $dir
    Bound: $bound
Threshold: $boundval$realthresh
  Current: $threshval$realval

$pagetop

MESSAGE
	            $msgbody .= "\n$rcfg->{$type.'desc'}{$router}\n" if $rcfg->{$type.'desc'}{$router};
	
                
                if (($bound eq 'min' and $boundval > $threshval) or
                    ($bound eq 'max' and $boundval < $threshval)) {
    		        # threshold was broken...
	    	        my $message = <<MESSAGE;
$msghead
Subject: [MRTG-TH] BROKEN $router $type $bound $dir ( $boundval$realthresh vs $threshval$realval )

Threshold BROKEN
----------------
$msgbody
MESSAGE
                    my @exec = ( $rcfg->{$type.'prog'.$dir}{$router}, $router,
			            $rcfg->{$type.$bound.$dir}{$router}, $threshval,($rcfg->{$type.'desc'}{$router} ||"No Description"));
 
                    # Check if we use the status file or not...
                    if ( defined $threshfile ) {
		                if ( not -e $threshfile.".".$type.$bound.uc($dir) ) {
			            # Create a file to indicate a threshold problem for the time after the problem
			                open THRESHTOUCH, ">".$threshfile.".".$type.$bound.uc($dir)
			                    or warn "$NOW: WARNING: Creating $threshfile.".$bound.uc($dir).": $!\n";
			                close THRESHTOUCH;
			                if (defined $rcfg->{$type.'prog'.$dir}{$router}){
                                debug('base',"run threshprog$dir: ".(join ",",@exec));
                     	        system @exec;
			                }
			                threshmail $cfg->{threshmailserver},$cfg->{threshmailsender},$rcfg->{$type.'mailaddress'}{$router},$message
    			                if $rcfg->{$type.'mailaddress'}{$router}
            	        } 
                        else {
			                debug('base',"NOT acting on BROKEN threshold since $threshfile.$type$bound$dir exists");
		                }
		            } elsif ( not defined $cfg->{$type.'hyst'} or 
	                     ($bound eq 'min' and $boundval - $cfg->{$type.'hyst'}* $boundval < $threshval) or
                            ($bound eq 'max' and $boundval + $cfg->{$type.'hyst'}* $boundval > $threshval)
  			            ) {
        		     # no threshold dir so run on every 'break'
		                if (defined $rcfg->{$type.'prog'.$dir}{$router}){
                            debug('base',"run ${type}prog$dir: ".(join ",",@exec));
                            system @exec;
          		        }
            	        threshmail $cfg->{threshmailserver},$cfg->{threshmailsender},$rcfg->{$type.'mailaddress'}{$router},$message
                            if $rcfg->{$type.'mailaddress'}{$router};
		            }
                } else {
  		            # no threshold broken ...
		            my @exec = ( $rcfg->{$type.'progok'.$dir}{$router}, $router,
			                 $rcfg->{$type.$bound.$dir}{$router}, $threshval);
		            my $message = <<MESSAGE;
$msghead
Subject: [MRTG-TH] UN-BROKEN $router $type $bound $dir ( $rcfg->{$type.$bound.$dir}{$router} vs $threshval)

Threshold UN-BROKEN
-------------------
$msgbody
MESSAGE

		            # Check if we use the status file or not...
		            if ( defined $threshfile ) {
		                if ( -e $threshfile.".".$type.$bound.uc($dir) ){
			                unlink "$threshfile.".$type.$bound.uc($dir);
		                    if (defined $rcfg->{$type.'progok'.$dir}{$router}){
                                debug('base',"run ${type}progok$dir: ".(join ",",@exec));
                     	        system @exec;
    		                }
			                threshmail $cfg->{threshmailserver},$cfg->{threshmailsender},$rcfg->{$type.'mailaddress'}{$router},$message
                                if $rcfg->{$type.'mailaddress'}{$router};
		                }
		            }   
                }
            } # for my $bound ...
        } # for my $type
    } # for my $dir
}

sub getexternal ($) {
    my $command = shift;
    my $in=undef;
    my $out=undef;
    my $uptime="unknown";
    my $name="unknown";

    open (EXTERNAL , $command."|")
	or warn "$NOW: WARNING: Running '$command': $!\n";

    warn "$NOW: WARNING: Could not get any data from external command ".
	"'".$command.
	    "'\nMaybe the external command did not even start. ($!)\n\n" if eof EXTERNAL;

    chomp( $in=<EXTERNAL>) unless eof EXTERNAL;
    chomp( $out=<EXTERNAL>) unless eof EXTERNAL;
    chomp( $uptime=<EXTERNAL>) unless eof EXTERNAL;
    chomp( $name=<EXTERNAL>) unless eof EXTERNAL;

    close EXTERNAL;

    # strip returned date
    $uptime  =~ s/^\s*(.*?)\s*/$1/;
    $name  =~ s/^\s*(.*?)\s*/$1/;

    # do we have numbers in the external programs answer ?
    if ( not defined $in ) {
	warn "$NOW: WARNING: Problem with External get '$command':\n".
	    "   Expected a Number for 'in' but nothing'\n\n";        
    } elsif ( $in eq 'UNKNOWN' ) {
        $in = undef;
    } elsif ( $in !~ /([-+]?\d+(.\d+)?)/ ) {
	warn "$NOW: WARNING: Problem with External get '$command':\n".
	    "   Expected a Number for 'in' but got '$in'\n\n";
	$in = undef;
    } else {
        $in = $1;
    }

    if ( not defined $out ) {
	warn "$NOW: WARNING: Problem with External get '$command':\n".
	    "   Expected a Number for 'out' but nothing'\n\n";
    } elsif ( $out eq 'UNKNOWN' ) {
        $out = undef;
    } elsif ( $out !~ /([-+]?\d+(.\d+)?)/ ) {
	warn "$NOW: WARNING: Problem with External get '$command':\n".
	    "   Expected a Number for 'out' but got '$out'\n\n";
	$out = undef;
    } else {
        $out = $1;
    }
    debug('snpo',"External result:".($in||"undef")." out:".($out||"undef")." uptime:".($uptime||"undef")." name:".($name||"undef"));
    return ($in,$out,time,$uptime,$name);
}

sub getsnmparg ($$$$){
    my $confcache = shift;
    my $target = shift;
    my $cfg = shift;
    my $populated = shift;
    my $retry = 0;

    my $hostname = $$target{Host};
    my $hostkey = "$$target{Community}\@$$target{Host}$$target{SnmpOpt}";

    if ($$target{ipv4only}) {
        if (not ( $hostname =~ /^\d+\.\d+\.\d+\.\d+$/ or gethostbyname $hostname) ){
            warn "$NOW: WARNING: Skipping host $hostname as it does not resolve to an IPv4 address\n";
            return 'DEADHOST';
        }
    } else {
         if($hostname =~ /^\[(.*)\]$/) {
            # Numeric IPv6 address. Check that it's valid
            $hostname = substr($hostname, 1);
            chop $hostname;
            if(! inet_pton(AF_INET6(), $hostname)) {
                warn "$NOW: WARNING: Skipping host $hostname: invalid IPv6 address\n";
                return 'DEADHOST';
            }
        } else {
            # Hostname. Look it up
            my @res;
            my ($too,$port,$otheropts) = split(':', $$target{SnmpOpt}, 3);
            $port = 161 unless defined $port;
            @res = getaddrinfo($hostname, $port, Socket::AF_UNSPEC(), Socket::SOCK_DGRAM());
            if (scalar (@res) < 5) {
                warn "$NOW: WARNING: Skipping host $hostname as it does not resolve to an IPv4 or IPv6 address\n";
                return 'DEADHOST';
            }
        }
    }
  RETRY:
    my @ifnum = ();
    my @OID = ();
    # Find apropriate Interface to poll from
    for my $i (0..1) {
	if ($$target{IfSel}[$i] eq 'If') {
	    $ifnum[$i] = ".".$$target{Key}[$i];
	    debug('snpo',"simple If: $ifnum[$i]");
	} elsif($$target{IfSel}[$i] eq 'None') {
            $ifnum[$i] = "";
        } else {
            $$target{Key}[$i] =~ s/\s+$//; # no trainling whitespace in keys ...

	    if (not defined readfromcache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i])) {
		debug('snpo',"($i) Populate ConfCache for $$target{Host}$$target{SnmpOpt}");
		populateconfcache($confcache,"$$target{Community}\@$$target{Host}$$target{SnmpOpt}",$$target{ipv4only},1,$$target{snmpoptions});
		$$populated{$hostname} = 1; # set cache population to true for this cycle and host
	    }
 	    if (not defined readfromcache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i])) {
                warn "$NOW: WARNING: Could not match host:'$$target{Community}\@$$target{Host}$$target{SnmpOpt}' ref:'$$target{IfSel}[$i]' key:'$$target{Key}[$i]'\n";
		return 'NOMATCH';
	    } else {
		$ifnum[$i] = ".".readfromcache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i]);
		debug('snpo',"($i) Confcache Match $$target{Key}[$i] -> $ifnum[$i]");
	    }
	}
	if ($ifnum[$i] !~ /^$|^\.\d+$/) {
	    warn "$NOW: WARNING: Can not determine".
	      " ifNumber for $$target{Community}\@$$target{Host}$$target{SnmpOpt} \tref: '$$target{IfSel}[$i]' \tkey: '$$target{Key}[$i]'\n";
	    return 'NOMATCH';
	}
    }
    for my $i (0..1) {
	# add ifget methodes call for a cross check;
	for ($$target{IfSel}[$i]) {
	    /^Eth$/ && do {
		push @OID, "ifPhysAddress".$ifnum[$i]; last
	    };
	    /^Ip$/ && do {
		push @OID, "ipAdEntIfIndex".".".$$target{Key}[$i];last
	    };
	    /^Descr$/ && do {
		push @OID, "ifDescr".$ifnum[$i]; last
	    };
	    /^Type$/ && do {
		push @OID, "ifType".$ifnum[$i]; last
	    };
	    /^Name$/ && do {
		push @OID, "ifName".$ifnum[$i]; last
	    };
	}
	push @OID ,$$target{OID}[$i].$ifnum[$i];
    }
    # we also want to know uptime and system name unless we are
    if ( not defined $$cfg{nomib2} and $$cfg{logformat} ne 'rrdtool' ) {
      if ( $OID[0] !~ /^cache.+$/ and
           $OID[0] !~ /^\Q1.3.6.1.4.1.3495.1\E/ ) {
           push @OID, qw(sysUptime sysName);
      } else {
           push @OID, qw(cacheUptime cacheSoftware cacheVersionId)
      }
    }

    # pull that data
    debug('snpo',"SNMPGet from $$target{Community}\@$$target{Host}$$target{SnmpOpt} -- ".(join ",", @OID));
    my @ret;
    
    # make sure we have no error messages hanging round.
    
    $SNMP_Session::errmsg = undef;
    $Net_SNMP_util::ErrorMessage = undef;

    my $targtemp = $$target{Community}.'@'.$$target{Host}.$$target{SnmpOpt};
    $targtemp = v4onlyifnecessary($targtemp, $$target{ipv4only});
    
    my @snmpoids = grep !/^(Pseudo|WaLK|GeTNEXT|CnTWaLK)|IndexPOS/, @OID;
        
    if (defined $$cfg{singlerequest}){
#LH        local $BER::pretty_print_timeticks = 0;
	foreach my $oid (@snmpoids){
            push @ret, snmpget($targtemp,$$target{snmpoptions},$oid);
	}
    } else {
	@ret = snmpget($targtemp,$$target{snmpoptions},@snmpoids);
    }
    my @newret;
    for (@OID) {
        /^PseudoZero$/ && do { push @newret, 0; next; };
        /^PseudoOne$/ && do { push @newret, 1; next; };
        s/^WaLK(\d*)// && do { my $idx = $1 || 0; my $oid=$_;push @newret, (split /:/, (snmpwalk($targtemp,$$target{snmpoptions},$oid))[$idx],2)[1]; 
                          debug('snpo',"snmpwalk '$oid' -> ".($newret[-1]||'UNDEF'));next};
        s/^GeTNEXT// && do { my $oid=$_;push @newret, (split /:/, snmpgetnext($targtemp,$$target{snmpoptions},$oid),2)[1]; 
                          debug('snpo',"snmpgetnext '$oid' -> ".($newret[-1]||'UNDEF'));next};
	s/^CnTWaLK// && do { my $oid=$_;my @insts= (snmpwalk($targtemp,$$target{snmpoptions},$_)); 
	    		undef @insts if( $insts[1] || '') =~/no/i; push @newret, scalar @insts;
			debug('snpo',"snmpCountwalk '$oid' -> ".($newret[-1]||'UNDEF'));next};
        /IndexPOS.*\.(\d*)/ && do { my $idx=$1; s/IndexPOS/$idx/; s/\.\d*$//; push @newret, snmpget($targtemp,$$target{snmpoptions},$_); 
                          debug('snpo', "snmpget of oid '$_' after replacement of IndexPOS"); next};
        push @newret, shift @ret;
    }
    @ret = @newret;
    debug('snpo',"SNMPfound -- ".(join ", ", map {"'".($_||"undef")."'"}  @ret));
    $ret[-2] = $ret[-2].' '.$ret[-1] if $OID[-1] and $OID[-1] eq 'cacheVersionId';
    my $time = time;
    my @final;
    # lets do some reality check
    for my $i (0..1) {
	# some ifget methodes call for a cross check;
	for ($$target{IfSel}[$i]) {
	    /^Eth$/ && do {
		my $bin = shift @ret || 0xff;
		my $eth = unpack 'H*', $bin;
		my @eth;
		while ($eth =~ s/^..//){
		    push @eth, $&;
		}
		my $phys=join '-', @eth;
		if ($phys ne $$target{Key}[$i]) {
		    debug('snpo', "($i) eth if crosscheck got $phys expected $$target{Key}[$i]");
		    if (not $retry) {
			$retry=1;
			# remove broken entry
			storeincache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i],undef);
			debug('repo',"($i) goto RETRY force if cache repopulation");
			goto RETRY;
		    } else {
			warn "$NOW: WARNING: could not match&get".
			    " $$target{Host}$$target{SnmpOpt}/$$target{OID}[$i] for Eth $$target{Key}[$i]\n";
			return 'NOMATCH';
		    }
		};
		debug ('snpo',"($i) Eth crosscheck OK");
	    };
	    /^Ip$/ && do {
		my $if = shift @ret || 'none';
		if ($ifnum[$i] ne '.'.$if) {
		    debug('repo', "($i) IP if crosscheck got .$if expected $ifnum[$i]");
		    if (not $retry) {
			$retry=1;
			# remove broken entry
			storeincache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i],undef);   
			debug('repo',"($i) goto RETRY force if cache repopulation");
			goto RETRY;
		    } else {
			warn "$NOW: WARNING: could not match&get".
			    " $$target{Host}$$target{SnmpOpt}/$$target{OID}[$i] for IP $$target{Key}[$i]\n";
			return 'NOMATCH';
		    }
		}
		debug ('snpo',"($i) IP crosscheck OK");
	    };
	    /^(Descr|Name|Type)$/ && do {
		my $descr = shift @ret || 'Empty';
                $descr =~ s/[\0- ]+$//; # remove excess spaces and stuff
		if ($descr ne $$target{Key}[$i]) {
		    debug('repo', "($i) $_ if crosscheck got $descr expected $$target{Key}[$i]");
		    if (not $retry) {
			$retry=1;
			# remove broken entry
			storeincache($confcache,$hostkey,$$target{IfSel}[$i],$$target{Key}[$i],undef);   
			debug('repo',"($i) goto RETRY force if cache repopulation");
			goto RETRY;
		    } else {
			warn "$NOW: WARNING: could not match&get".
			    " $$target{Host}$$target{SnmpOpt}/$$target{OID}[$i] for $_ '$$target{Key}[$i]'\n";
			return 'NOMATCH';
		    }
		} 
		debug ('snpo',"($i) $_ crosscheck OK");
	    };
	}
	# no sense continuing here ... if there is no data ...      
 	if (defined $SNMP_Session::errmsg and $SNMP_Session::errmsg =~ /no response received/){
            $SNMP_Session::errmsg = undef;
	    warn "$NOW: WARNING: skipping because at least the query for $OID[0] on  $$target{Host} did not succeed\n";
	    return 'DEADHOST';
        }
 	if (defined $Net_SNMP_util::ErrorMessage and $Net_SNMP_util::ErrorMessage =~ /No response from remote/){
            $Net_SNMP_util::ErrorMessage = undef;
	    warn "$NOW: WARNING: skipping because at least the query for $OID[0] on  $$target{Host} did not succeed\n";
	    return 'DEADHOST';
	}	
	if ($$target{OID}[$i] =~ /if(Admin|Oper)Hack/) {
	    push @final, ((shift @ret) == 1) ? 1:0;
	} else {
	    push @final, shift @ret;
	}
    }
    
    my @res = ( @final,$time, @ret);
    
    # Convert in and out values to integers with a user-defined subroutine
    # specified by the Conversion target key
    if( $target->{ Conversion } ) {
        foreach my $ri( 0..1 ) {
            next unless defined $res[ $ri ];
	    local $SIG{__DIE__};
            my $exp = "&MRTGConversion::$target->{ Conversion }( \$res[\$ri] )";
            $res[ $ri ] = eval $exp;
            warn "$NOW: WARNING: evaluation of \"$exp\" failed\n$@\n" if $@;
        }
    }

    # have some cleanup first, it seems that some agents
    # are adding newlines to what they return
    map{ $_ =~ s/\n|\r//g if defined $_ } @res;
    map{ $_ =~ s/^\s+//g if defined $_ } @res;
    map{ $_ =~ s/\s+$//g if defined $_ } @res;
    
    # in and out should be numbers only
	for my $ri (0..1){
	    # for folks using rrdtool I am allowing numbers 
	    # with decimals here
	    if ( defined $res[$ri] and $res[$ri] !~ /^[-+]?\d+(.\d+)?$/ ) {
		warn "$NOW: WARNING: Expected a number but got '$res[$ri]'\n";
		$res[$ri] = undef;
		
	    }
	}
	return @res;
    }


# read target function ...
sub readtargets ($$$) {
    my ($confcache,$target,$cfg) = @_;
    my $forks = $$cfg{forks};
    my $trgnum = $#{$target}+1;
    if (defined $forks and $forks > 1  and $trgnum > 1){
        $forks = $trgnum if $forks > $trgnum;
        my $split = int($trgnum / $forks) + 1;       
	my @hand;
	# get them forks to work ... 
	for (my $i = 0; $i < $forks;$i++) {
	    local *D;
            my $sleep_count=0;
            my $pid;
            do {
               $pid = open(D, "-|");
                unless (defined $pid) {
                    warn "$NOW: WARNING cannot fork: $!\n";
                    die "$NOW: ERROR bailing out after 6 failed forkattempts"
                         if $sleep_count++ > 6;
                    sleep 10;
                }
            } until defined $pid;
	    if ($pid) { # parent
     		$hand[$i] = *D; # funky file handle magic ... 
		debug ('fork',"Parent $$ after fork of child $i");
	    } else {  # child
		debug ('fork',"Child $i ($$) after fork");
		my $res = "";
                my %deadhost;
                my %populated;
		for (my $ii = $i * $split; 
		     $ii < ($i+1) * $split and $ii < $trgnum;
		     $ii++){
		    my $targ = $$target[$ii];
		    my @res;
		    if ($$targ{Methode} eq 'EXEC') {
			@res = getexternal($$targ{Command});
		    } else { # parent
                        if (not $deadhost{$$targ{Community}.$$targ{Host}}) {      
        	  	    @res = getsnmparg($confcache,$targ,$cfg,\%populated);
                            if ( $res[0] and $res[0] eq 'DEADHOST') {
                                # guess we got a blank here
                                @res = ( undef,undef,time,undef,undef);
                                $deadhost{$$targ{Community}.$$targ{Host}} = 1;
                                warn "$NOW: WARNING: no data for $$targ{OID}[0]&$$targ{OID}[1]:$$targ{Community}\@$$targ{Host}. Skipping further queries for Host $$targ{Host} in this round.\n"
                            } elsif ($res[0] and $res[0] eq 'NOMATCH'){
                                @res = (undef,undef,time,undef,undef);
                            }
                        } else {
                            @res = ( undef,undef,time,undef,undef);
                        }
		    }
		
		    for (my $iii=0;$iii<5;$iii++){
			if (defined $res[$iii]){
                            $res .= "$res[$iii]\n";
			} else {
                            $res .= "##UNDEF##\n";
			}
		    }
		}
		debug ('fork',"Child $i ($$) waiting to deliver");
		print $res; # we only talk after the work has been done to
                  	    # otherwhise we might get blocked 
                # return updated hosts from confcache
                writeconfcache($confcache,'&STDOUT')
                        if defined $$confcache{___updated};
		exit 0;
	    }
	    
	}
	# happy reaping ... 
        my $vin =''; # vector of pipe file-descriptors from children
	for (my $i = 0; $i < $forks;$i++) {
            vec($vin, fileno($hand[$i]), 1) = 1;
        }
        my $left = $forks;
        while ($left) {
            my $rout = $vin; # read vector
            my $eout = $vin; # exception vector
            my $nfound = select($rout, undef, $eout, undef); # no timeout
            if (1 > $nfound) {
               die sprintf("$NOW: ERROR: select returned %d: $!\n", $nfound);
            }
	    for (my $i = 0; $i < $forks; $i++) {
                next unless defined $hand[$i] and defined fileno($hand[$i]);
# this does not seem to work reliably
#                if (vec($eout, fileno($hand[$i]), 1)) {
#		   die "$NOW: ERROR: fork $i has died ahead of time?\n";
#                }
                next unless vec($rout, fileno($hand[$i]), 1);

                vec($vin, fileno($hand[$i]), 1) = 0; # remove this child fd

	        debug ('fork',"Parent reading child $i");
	        my $h = $hand[$i];
	        for (my $ii = $i * $split; 
		     $ii < ($i+1) * $split and $ii < $trgnum;
		     $ii++){ 
		    my $targ = $$target[$ii];
		    my @res;
		    for (0..4){
		        my $line = <$h>; # must be a simple scalar here else it wont work
		        die "$NOW: ERROR: fork $i has died ahead of time ...\n" if not defined $line;
		        chomp $line;
    #                    debug ('fork',"reading for $ii $line");
		        $line = undef if $line eq "##UNDEF##";                
		        push @res,$line;
		    };
    
		    ($$targ{_IN_},
		     $$targ{_OUT_},
		     $$targ{_TIME_},
		     $$targ{_UPTIME_},
		     $$targ{_NAME_}) = @res; 
                     if ($] >= 5.0061){
                         $$targ{_IN_} = Math::BigFloat->new($$targ{_IN_}) if $$targ{_IN_};
                         $$targ{_OUT_} = Math::BigFloat->new($$targ{_OUT_}) if $$targ{_OUT_};
                     }
                }     
                # feed confcache entries
                my $lasthost ="";
                while (<$h>){
                    chomp;
                    my ($host,$method,$key,$value) = split (/\t/, $_);
                    if ($host ne $lasthost){
        	         debug ('fork',"start clearing confcache on first entry for target $host");
                         clearfromcache($confcache,$host);
        	         debug ('fork',"finished clearing confcache");        
                    }
                    $lasthost = $host;
                    storeincache($confcache,$host,$method,$key,$value);
                 }
                 close $h;
                 --$left;
            }
        }
	            
    } else {
        my %deadhost;
        my %populated;
	foreach my $targ (@$target) {
	    if ($$targ{Methode} eq 'EXEC') {
		debug('snpo', "run external $$targ{Command}");
		($$targ{_IN_},
		 $$targ{_OUT_},
		 $$targ{_TIME_},
		 $$targ{_UPTIME_},
		 $$targ{_NAME_}) = getexternal($$targ{Command});
	    } elsif ($$targ{Methode} eq 'SNMP' and not $deadhost{$$targ{Host}}) {
		debug('snpo', "run snmpget from $$targ{OID}[0]&$$targ{OID}[1]:$$targ{Community}\@$$targ{Host}");
		($$targ{_IN_},
		 $$targ{_OUT_},
		 $$targ{_TIME_},
		 $$targ{_UPTIME_},
		 $$targ{_NAME_}) = getsnmparg($confcache,$targ,$cfg,\%populated);
               if ( $$targ{_IN_} and $$targ{_IN_} eq 'DEADHOST') {
                   $$targ{_IN_} = undef;
                   $$targ{_TIME_} =time;
                   # guess we got a blank here
                   $deadhost{$$targ{Host}} = 1;
                   warn "$NOW: WARNING: no data for $$targ{OID}[0]&$$targ{OID}[1]:$$targ{Community}\@$$targ{Host}. Skipping further queries for Host $$targ{Host} in this round.\n"
               } 
               if (  $$targ{_IN_} and $$targ{_IN_} eq 'NOMATCH') {   
                   $$targ{_IN_} = undef;
                   $$targ{_TIME_} =time;
               }
       
	    } else {
                 $$targ{_IN_} = undef;
                 $$targ{_OUT_} = undef;
                 $$targ{_TIME_} = time;
                 $$targ{_UPTIME_} = undef;
                 $$targ{_NAME_} = undef;
            }
            if ($] >= 5.008 ){
                    $$targ{_IN_} = new Math::BigFloat "$$targ{_IN_}" if $$targ{_IN_};
                    $$targ{_OUT_} = new Math::BigFloat "$$targ{_OUT_}" if $$targ{_OUT_};
            }
                
	}       
    }
        
}

sub imggen ($) {
        my $dir = shift;
        if ( ! -r "$dir${main::SL}mrtg-l.png" and  open W, ">$dir${main::SL}mrtg-l.png" ){
                binmode W;
                print W unpack ('u', <<'UUENC');
MB5!.1PT*&@H    -24A$4@   #\    9! ,   !TA.O'    &%!,5$5]9GTT
M79A?8HB(9WFR;6G_=DWM=%35<5R_M[A2     6)+1T0'%F&(ZP   1%)1$%4
M>-JMDKUOPD ,Q:E4]CH?S0PMG8-.$6L1A*YMJ,D<T>Q%5?[_ON>$Y (2$R>=
MY;-^OF=;GNCM\SFY#_#GW$IU0WMP/#O5HSGNW8"9R)/92$NQ\Z:GUDG/@.@!
M)CP#4H\ >LT>)NB!A0]8,"]&0.(#WY92V<\$=FM4<P7$:Q,JN\^BGRV+WOX2
MX.<2+4VH!U01B-LYX#V3B*U(1N 5[K,/?(G,)1!!9-%WX0.HYX7 :0!"]0&4
MMV*/Z"/N@&8$P,N8!:FD[!4\ #7EN$G1 <M+"0*0B0&$!#:MQ@#P#?WIO@,^
M+KI@K$9V#B"P03V,!\5)T]1T#*A,8P"P.%JZ1USGL%%IPTC.#<ONMK2W@']'
M6*MJXQ-D&    $-T15AT4V]F='=A<F4 0"@C*4EM86=E36%G:6-K(#0N,BXY
M(#DY+S Y+S Q(&-R:7-T>4!M>7-T:6,N97,N9'5P;VYT+F-O;>WHV?     J
M=$58=%-I9VYA='5R90!D,C(W8S<T.3AA-3 Q93=F830U,#@V8SEF9C0T8F(Y
K8ULTB'X    .=$58=%!A9V4 -C-X,C4K,"LP&!)XE     !)14Y$KD)@@F(Y
UUENC
close W;
        }
        if ( ! -r "$dir${main::SL}mrtg-m.png" and  open W, ">$dir${main::SL}mrtg-m.png" ){
                binmode W;
                print W unpack ('u', <<'UUENC');
MB5!.1PT*&@H    -24A$4@   !D    9! ,    VQYA0    &%!,5$5]9GTT
M79A588QN9(*7:73_=DWL=%31<F'8YWD&     6)+1T0'%F&(ZP   (!)1$%4
M>-IC"$4"!0P$>"E&2B:I,%Z((!"(I$)X88H@GJ :A)<$Y@@*I8)YAA">("N(
M%PYD"#L+"IJ#Y4!FN(86N4',# )J"4TO*R\O!_$"@::'@HTEQ /K _&$0+P 
M(.T:6@A2@62?H#B*6TRQN#,<Q0^AP<C^ _K=&,GO1(89 ,3!45'T;[0_    
M0W1%6'13;V9T=V%R90! *",I26UA9V5-86=I8VL@-"XR+CD@.3DO,#DO,#$@
M8W)I<W1Y0&UY<W1I8RYE<RYD=7!O;G0N8V]M[>C9\    "IT15AT4VEG;F%T
M=7)E #1E,S8X-S$P,38Q-S)A96%B.3,Y8SEA,F5D-31B86(U@DWZ,@    ET
M15AT1&5L87D ,C4P(RC.$P    YT15AT4&%G90 R-7@R-2LP*S"#D2 ?    
) $E%3D2N0F""
UUENC
close W;
        }
        if ( ! -r "$dir${main::SL}mrtg-r.png" and  open W, ">$dir${main::SL}mrtg-r.png" ){
                binmode W;
                print W unpack ('u', <<'UUENC');
MB5!.1PT*&@H    -24A$4@   80    9! ,   ##'$3)    &%!,5$4T79@\
M8YQ5=JAPC;>:K\S\_?[5WNFZR-PB%CO!     6)+1T0'%F&(ZP  !=5)1$%4
M>-KM6$ESVE@0;BW 58: K_)"YDH(.%=YL/"511)7O""N3AS!WY_^NM^3Q)+,
M4C55DZJ1*2&]U]O7Z\,4T"]__0_A;US.O\7$$#H*PR=R[_'@#? A9X3KLW,K
MNRX_*L=MGK^#PQ)[$USW+J@'U)E,!JI<V>GS9"+RG0^B!(NDM,ZMB'G,M_?6
MF@^[_#7D[U)*!V_N!#+4$)>M@+Z(.J/1)PNAI4]=5K# 0_,)'Z(4UXH*A<#/
M2SQ\3+?[=!F4Q&M?Z!8@2-?4X+O*L^Q\$PPQ;MA.R= 65RRWR/:[U&#PTVR_
MR4*JI#3?9#E-$U)#W)5*GE&3[Y&!T%P+?QR2)U;UUOB(0@A0"-Z*.AOVC)=^
MY=L&-T/L"$G !,KBW"V-3PU[.\8W@5N7J)W(?L'&WB5LP6_*X10OP+2L21G/
MH7OA=#:1&M)F-1FI\^A+8B&H %;A+\U>LP8A)HN^RZOC9^BZY#=#_&10NA8"
M.5E !^R7H/2R=0G!6PH%1\%-!W@<"GU+PN4Q.Z2D6-K!2-;D]-=J"-2H?&C>
M7"B$ABCW."HV-PX@%"6$YHS<3:@.K!$K2;N"4-0A\)X'.R[?%R4$MXQ"TT9,
M7*Y:IP)!8N0L=Z0IVUJH(9!51H%B1)9A]$%,S3QB[_P0 EA;B\ W*KM/%?%Q
M%*@8'$*0K?Y@54'0*+ !XZ@&P;C'2N$W?SU&\BX"Z"YKH08ATBB,^WCHW[U5
MCK6U$!U'H3$WA9<<1\%+2I8R"H:]@ZT=Q8%9LK1%Z!1AA< XH902XAM@X#<;
MA?;J) HL-F[!KJ*U%KC:D<XFTOAKZ35^+8FU7-S5\.8Z!(N;U7P)]B93.@G!
M4XWWZ^$U)]+-]? "M9#5YI*_+%^LE''@S[5Q]&951\J&PYL0-FJ],-<4J>DD
M_NQ\.9M$RD9?TE!AX\HJ8E,+IJE^'Q6+.H1X\K#A;V\FI.B6F=)&B$+E>'9T
M51>-EPD:$VVE;#C>'CJ2:=.FJ?9>1_'20-CQ'_ESAN"5Y?Q4LT'=SFS?^.7*
MYFU%;!(IFTP>!K!Q%=8AL.)7D@8/AL;K:#3A#LW#*>0H> <0(-"]YF!:*>X2
MUG&GD;D08Z0] ,((4XWG0O;)0-@2UTPW8@V^G0NG46BO^FNB,@I.7A$?EO.W
MK+1)V<4R&H<$E]MR-K7@GD!HB;DL!4G%N>VP;?YJCPE?\''#<:4C!?S7?-IH
MXG%'2N"B.&2Y/^M(*ZE!6PM.]L..5#4997<P;JG(\SP]:JKLCZP&03+3&=[<
M+B$% [N;Y?E&PQ<80[RJG)_Z(@Q;TERV&)DG48AJY>R@5W:5"SWE* JV([U5
M*6W8H>EBM=_O>9B8CF2C0)M:.1L)@-*(!$_\^+C?S8TF.FJJO;6?& AP20*A
MB6DR[*FS':G[7)5<<U$1VXYD6)RRO9L]:$)C@=3CT19'%00G53RMF96R55J+
M^! "2],!%$B88CAS9?S S>_,&2F1-N>:+LBJ2^+#Z1Q1?WV02(3PR2/<JV<D
M8Q.O/]<@&#R<B4S6-\.SK+HS<Z&W4 @@Z!9<VSE0D)SWSI^1H"+^*H" Q!(?
M3V<3W\H#'^=H&(1Z-F<D4PNA"F+#Y+TKRSC#,!DG/8=#*D;C73LC60B>'*IX
M=,_1!P+ %2,A]5Q'TBSR49QN_$P5\?$9Z>2 P=;DXN8B..I(+ 2/'76SBU,P
MC9=6BD28R\^O)=+1&2E2"#/C%CX7M++)J&#SFMP*GD^F,_SCC+.'42'H+;&)
M0LH]YTU8>HM#"!3_GI@4.:R%*_3\U\EC:M+I8_I]-,T&9*3H0:4U/RYG:-+9
M):7)9D,JX$_9*=,TW>)74"X0F@ Y50B83W?\'H!$"]80*XF;"P2P>%NUJ&2_
M?-51V7N3)7)?E!]B_$V:OMMJ^,+CZMYPMK??9;'SXBG"J;4C%PBPVX5^T]1"
M6U-M/;K_[#>U>Q4<$?_I=?&SS>NP_(5\X=Z<<ITR.Y5YP7_B/QC_Z/\"?]4_
MO\3U!QLJ>FT="M4^    0W1%6'13;V9T=V%R90! *",I26UA9V5-86=I8VL@
M-"XR+CD@.3DO,#DO,#$@8W)I<W1Y0&UY<W1I8RYE<RYD=7!O;G0N8V]M[>C9
M\    "IT15AT4VEG;F%T=7)E #$R,3<U939B,S$X,S,S-V0S.#%F,#%C-C-C
M9F,T,S9ELPXRP0    ]T15AT4&%G90 S.#AX,C4K,"LP4K-IB0    !)14Y$
$KD)@@C9E
UUENC
close W;
        }

}

# Local Variables:
# mode: cperl
# eval: (cperl-set-style "PerlStyle")
# mode: flyspell
# mode: flyspell-prog
# End:
#
# vi: sw=4
