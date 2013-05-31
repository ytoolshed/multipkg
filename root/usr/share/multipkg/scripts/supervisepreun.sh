#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$1" = "0" ]; then
	rm /service/%service%
	svc -dx /etc/service/%service% /etc/service/%service%/log
fi

