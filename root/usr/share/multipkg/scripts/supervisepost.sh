#!/bin/sh

chown nobody /etc/service/%service%/log/main
ln -sfn /etc/service/%service% /service/%service%
/usr/local/bin/svc -t /service/%service% /service/%service%/log

