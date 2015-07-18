
Apache Statistics - Version 1.0b


Changes

1.0b  -  26 December 2011
- Upgrade MRTG to version 2.17.3

1.0b  -  9 July 2011
- Upgrade MRTG to version 2.17.2 

1.0b  -  8 December 2010
- Upgrade MRTG to version 2.16.4
  * fix "P_DETACH" and Pod::Usage issues with perl 5.12

1.0b  - 25 February 2010
- Upgrade MRTG to version 2.16.3

1.0b  - 26 March 2008
- Notes added in this Readme.txt

1.0a  - 12 Sept 2006
- Upgrade MRTG to version 2.14.7
- Upgrade curl to version 7.15.4

1.0  - 15 Febr 2006
- First version
_______________________________________________________

Author: Steffen (info@apachelounge.com)
_______________________________________________________



1. First be sure you have full Perl installed eg. from 
   http://www.ActiveState.com 

2. You might want to make sure that the Perl binary directory
   (eg. c:/perl/bin) is listed in your Windows system path 

   C:\Perl\bin;%SystemRoot%\system32;%SystemRoot%;...

   You can manually check this by going to 
   [Control Panel]->[System]->[Environment]

3. Copy the ApacheStats directory from the zip to a place
   anywhere outside your web space.

4  To see if Perl and MRTG is properly installed you can open a
   Dos Command Shell and go into the ApacheStats/bin folder.
 
   Type:

   perl mrtg.pl 

   This should give you a friendly message about MRTG
 
   Now, you have successfully installed MRTG and Perl


5. Set in Apache.ini the Apache host and port (default localhost and 80)
  
6. Change in mrtg.ini the WorkDir setting to a directory inside
   your web space where the Webpages and Graphs should be created 
   (may not contain spaces)

7. Enable Apache module mod_status:

   LoadModule status_module modules/mod_status.so

8  Configure mod_status:

   For 2.0.x in /conf/httpd.conf or for 2.2.x in /conf/extra/httpd-info.conf
   
   ExtendedStatus On

   <Location /server-status>
   SetHandler server-status
   Order Deny,Allow
   Deny from all
   Allow from localhost
   </Location>

   For 2.2.x in /conf/httpd.conf uncomment the line:
   #Include conf/extra/httpd-info.conf
   

   see also: http://httpd.apache.org/docs/2.2/mod/mod_status.html

9. Start the stats by double clicking on StartStats.bat and a Dos
   box appears. 


The Webpage and Graphs are created in the dir defined in step 6,
every 5 minutes the ApacheStats is calling Apache.

   Notes added 26 march 2008 :

   The first time you start, you get warnings about reading 
   and updating log files. This warnings you can ignore.

   When there are high peaks in the graph, 
   which are disturbing the graph, 
   you can lower the value of the option MaxBytes[xxx]:

   When a graph is capped at a certain value or no graph line,
   you can try a higher value of the option MaxBytes[xxx]:
   Note: a number higher than MaxBytes is ignored

   You can remove/add the peak 5 minute values in a graph
   with the option in mrtg.ini WithPeak[xxx]: wmy 
   [w]eekly,[m]onthly,[y]early

## For all configuration settings for mrtg.ini,
## see http://oss.oetiker.ch/mrtg/doc/mrtg-reference.en.html


I hope you like it, and let me know how it is going.


Steffen

_______________________________________________________

Toubleshooting: Look in Stats.log for errors and for the
Apache response in the apache.cache file.

Note: to setup mrtg as a windows service, see
      http://oss.oetiker.ch/mrtg/doc/mrtg-nt-guide.en.html
_______________________________________________________


Acknowledgement:
The file apache.pl accompanying this package are created by myself.
The other files in the packge are distributed with the current MRTG and cURL releases,
see http://curl.haxx.se/ and http://oss.oetiker.ch/mrtg

Legal Jargon:
This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a paricular purpose. 






