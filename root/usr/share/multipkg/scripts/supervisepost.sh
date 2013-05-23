#!/bin/sh

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

chown nobody /etc/service/%service%/log/main
ln -sfn /etc/service/%service% /service/%service%
svc -t /service/%service% /service/%service%/log

