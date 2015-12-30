#!/usr/bin/perl

#
# apache.pl
#
# Interface for Apache and MRTG
#
# Copyright 2006 by Steffen Land, info@apachelounge.com .  All rights reserved.
#


$host = "localhost";
$port ="80";
$CACHE_FILE = "apache.cache";

sub RetrieveStats(){
  $null = @ENV{COMPUTERNAME} ? "nul" : "/dev/null" ;
  `curl  -m 10 http://$host:$port/server-status?auto -A \"ApacheLounge Monitor\" > $CACHE_FILE 2>$null`;
}
sub Validate() {
  if ((scalar(@ARGV) < 2) || ($ARGV[0] eq '')) {
     print "ERR: invalid arguments.\n";
     exit;
  }
}
Validate();
@type = ($ARGV[0],$ARGV[1]);
while (@ARGV) { $x=shift(@ARGV); if ($x =~ /-conf/) {require shift(@ARGV);}}
@result = (0,0);
$complete = 0;
if ( time() - (stat($CACHE_FILE))[9] > (60*2) ){	
	RetrieveStats();
}

open(IN,"< $CACHE_FILE") or die "Could not open cached file";
foreach $line ( <IN> ){
	if ($line =~ /^Score/) {$complete=1;last;}	
	for($i=0;$i<=1;$i++){
if ($type[$i] eq "taccesses" && $line =~ /^Total Accesses: (\d+)/) {$result[$i]=($result[$i]+$1);next;}
if ($type[$i] eq "tkbytes" && $line =~ /^Total kBytes: (\d+)/) {$result[$i]=($result[$i]+$1*1000);next;}
if ($type[$i] eq "busyworkers" && $line =~ /^BusyWorkers: (\d+)/) {$result[$i]=($result[$i]+$1);next;}

if ($type[$i] eq "null") {$result[$i]="0";}
	}
}
close IN;
if (!$complete) {exit;}	
print $result[0]."\n";
print $result[1]."\n";
print $uptime."\n";
print $host."\n";

