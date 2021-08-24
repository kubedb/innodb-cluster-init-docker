#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /run-script/*
cp /tmp/scripts/* /scripts
