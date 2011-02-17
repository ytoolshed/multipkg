#!/bin/sh

if [ "$1" = "0" ]; then
	rm /service/%service%
	/usr/local/bin/svc -dx /etc/service/%service% /etc/service/%service%/log
fi

