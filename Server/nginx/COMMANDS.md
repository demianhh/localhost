# Commands for nginx

## Install & Start nginx

    cd C:\Server
    unzip nginx-1.8.0.zip
    ren nginx-1.8.0 nginx
    cd nginx
    start nginx

## Show nginx tasklist (on Windows)

    tasklist /fi "imagename eq nginx.exe"

## Basic nginx commands

    nginx -s [ stop | quit | reopen | reload ]

    nginx -s stop		fast shutdown
    nginx -s quit		graceful shutdown
    nginx -s reload 	changing configuration, starting new worker processes with a new configuration, graceful shutdown of old worker processes
    nginx -s reopen 	re-opening log files
