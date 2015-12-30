# Howto: Make Your Own Cert With OpenSSL

Link: http://blog.didierstevens.com/2008/12/30/howto-make-your-own-cert-with-openssl/

----

cd C:\Server\Apache24\conf\extra\ssl\exampledomain.isc

First we generate a 4096-bit long RSA key for our root CA and store it in file ca.key:

openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 1826 -key ca.key -out ca.crt

iSC Enterprise Group (iEG)
VerifyCert
VerifyCert Internet Authority (VCIA)
verifycert.isc
SuriyaaKudoIsc@users.noreply.github.com
(DigiCert SHA2 Extended Validation Server CA)
(Google Internet Authority G2)
(DigiCert SHA2 High Assurance Server CA)

----

Next step: create our subordinate CA that will be used for the actual signing. First, generate the key:

openssl genrsa -out localhost.key 4096
openssl req -new -key localhost.key -out localhost.csr

----

Next step: process the request for the subordinate CA certificate and get it signed by the root CA.

openssl x509 -req -days 730 -in localhost.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out localhost.crt
openssl pkcs12 -export -out localhost.p12 -inkey localhost.key -in localhost.crt -chain -CAfile ca.crt

