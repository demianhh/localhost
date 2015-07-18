ipconfig
netstat -a -o
ping
arp -a
net view /all
nslookup <computer name>
netstat -ab
netstat -tn

----

cd C:\Server\Apache24\bin

httpd.exe -k install
httpd.exe -k uninstall
httpd.exe -k start
httpd.exe -k stop
httpd.exe -k shutdown
httpd.exe -k restart
httpd.exe -e debug
httpd.exe -t

----


C:\Windows\System32\drivers\etc


----


https://www3.ntu.edu.sg/home/ehchua/programming/howto/Apache_HowToConfigure.html#zz-1:


> openssl req -x509 -days 36500 -newkey rsa:2048 -nodes -keyout MyServer.key -out MyServer.crt
     -subj /C=SG/O=MyCompany/CN=localhost
 
// If error "Unable to load config info from /usr/local/ssl/openssl.cnf" encountered
> openssl req -x509 -days 36500 -newkey rsa:2048 -nodes -keyout MyServer.key -out MyServer.crt
     -subj /C=SG/O=MyCompany/CN=localhost -config ../conf/openssl.cnf

> openssl x509 -in server.crt -noout -text

> openssl s_client -connect localhost:443

